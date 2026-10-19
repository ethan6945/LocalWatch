import SwiftUI
import AppKit
import ServiceManagement

@MainActor final class Store: ObservableObject {
    @Published var sites: [Site] = []
    @Published var results: [UUID: Probe] = [:]
    @Published var dormant: [Site] = []
    @Published var busy = false
    @Published var lastCheck: Date?
    @Published var autoDiscover = UserDefaults.standard.object(forKey: "discover") as? Bool ?? true
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var message = ""
    var onChange: (() -> Void)?
    private var ignored = Set(UserDefaults.standard.stringArray(forKey: "ignored") ?? [])
    var online: Int { sites.filter { results[$0.id]?.online == true }.count }
    var failures: Int { sites.filter { results[$0.id]?.healthy == false }.count }
    init() {
        if let data = UserDefaults.standard.data(forKey: "sites"), let saved = try? JSONDecoder().decode([Site].self, from: data) { sites = saved }
        if let data = UserDefaults.standard.data(forKey: "dormant"), let saved = try? JSONDecoder().decode([Site].self, from: data) { dormant = saved }
    }
    func save() {
        if let data = try? JSONEncoder().encode(sites) { UserDefaults.standard.set(data, forKey: "sites") }
        if let data = try? JSONEncoder().encode(dormant) { UserDefaults.standard.set(data, forKey: "dormant") }
        UserDefaults.standard.set(Array(ignored), forKey: "ignored")
        onChange?()
    }
    func forgetDormant() { dormant = []; save() }
    func add(name: String, address: String, id: UUID? = nil) -> Bool {
        guard let url = LocalURL.parse(address) else { message = "请输入本机地址，例如 http://127.0.0.1:8796"; return false }
        let address = url.absoluteString
        if sites.contains(where: { $0.address == address && $0.id != id }) { message = "这个地址已在列表中"; return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, let index = sites.firstIndex(where: { $0.id == id }) {
            sites[index].name = name.isEmpty ? "本机项目 · \(url.port ?? 80)" : name
            sites[index].address = address
            results.removeValue(forKey: id)
        } else {
            sites.append(Site(name: name.isEmpty ? "本机项目 · \(url.port ?? 80)" : name, address: address))
        }
        ignored.remove(address); dormant.removeAll { $0.address == address }; message = ""; save()
        return true
    }
    func remove(_ site: Site) {
        ignored.insert(site.address)
        sites.removeAll { $0.id == site.id }
        dormant.removeAll { $0.id == site.id }
        results.removeValue(forKey: site.id)
        save()
    }
    func refresh() async {
        guard !busy else { return }; busy = true
        defer { busy = false; onChange?() }
        let requested = sites + dormant
        if !requested.isEmpty {
            var probes = await probe(requested)
            // 失败的项目再确认一次，避免一次偶发超时就让它消失。
            let missed = probes.filter { !$0.1.online }.map { $0.0 }
            if !missed.isEmpty {
                let second = Dictionary(uniqueKeysWithValues: await probe(missed).map { ($0.0.id, $0.1) })
                probes = probes.map { site, first in
                    guard !first.online, let again = second[site.id], again.online else { return (site, first) }
                    return (site, again)
                }
            }
            let byID = Dictionary(uniqueKeysWithValues: probes.map { ($0.0.id, $0.1) })
            let checked = Set(requested.map { $0.id })
            var shown: [Site] = []
            var hidden: [Site] = []
            for site in requested {
                // 检查期间被改名或移除的项目按当前状态处理。
                guard let current = sites.first(where: { $0.id == site.id }) ?? dormant.first(where: { $0.id == site.id }),
                      current.address == site.address, let result = byID[site.id] else { continue }
                if result.online { shown.append(current); results[site.id] = result }
                else { hidden.append(current); results.removeValue(forKey: site.id) }
            }
            // 检查期间新增的项目保留下来，下一次检查再探测。
            shown += sites.filter { !checked.contains($0.id) }
            hidden += dormant.filter { !checked.contains($0.id) }
            sites = shown
            dormant = hidden
        }
        if autoDiscover { await discover() }
        lastCheck = Date()
    }
    private func probe(_ list: [Site]) async -> [(Site, Probe)] {
        await withTaskGroup(of: (Site, Probe).self) { group in
            for site in list { group.addTask { (site, await Network.probe(site.address)) } }
            var collected: [(Site, Probe)] = []
            for await item in group { collected.append(item) }
            return collected
        }
    }
    private func discover() async {
        let ports = await Task.detached(priority: .utility) { Network.listeningPorts() }.value
        let existing = Set(sites.compactMap { URL(string: $0.address)?.port })
        let candidates = ports.filter { !existing.contains($0) && !ignored.contains("http://127.0.0.1:\($0)/") }
        // Keep discovery bounded even when a developer has many listeners.
        for batchStart in stride(from: 0, to: candidates.count, by: 12) {
            let batch = Array(candidates[batchStart..<min(batchStart + 12, candidates.count)])
            let found = await withTaskGroup(of: (Int, Probe).self) { group in
                for port in batch { group.addTask { (port, await Network.probe("http://127.0.0.1:\(port)/")) } }
                var found: [(Int, Probe)] = []; for await item in group { found.append(item) }; return found
            }
            for (port, result) in found.sorted(by: { $0.0 < $1.0 }) where result.online {
                let address = "http://127.0.0.1:\(port)/"
                guard !ignored.contains(address), !sites.contains(where: { URL(string: $0.address)?.port == port }) else { continue }
                let name = result.title ?? "本机项目 · \(port)"
                let site = Site(name: name, address: address, automatic: true)
                sites.append(site); results[site.id] = result
            }
        }
        save()
    }
    func discoveryChanged() { UserDefaults.standard.set(autoDiscover, forKey: "discover") }
    func loginChanged(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { message = "请在系统设置 → 通用 → 登录项中允许 LocalWatch"; SMAppService.openSystemSettingsLoginItems() }
        } catch { message = "登录启动设置失败：\(error.localizedDescription)"; launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
}

struct Dashboard: View {
    @ObservedObject var store: Store
    @State private var editing = false
    @State private var editedID: UUID?
    @State private var name = ""
    @State private var address = "http://127.0.0.1:"
    @State private var settings = false
    var onSizeChange: (CGSize) -> Void = { _ in }
    var listHeightLimit: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(66, screenHeight - 150 - (editing ? 170 : 0) - (settings ? 170 : 0))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(store.failures > 0 ? Color.orange : (store.online > 0 ? Color.green : Color.secondary)).frame(width: 7, height: 7)
                Text(store.lastCheck == nil ? "尚未检查" : "\(store.online) 个在线").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                if store.failures > 0 {
                    Text("· \(store.failures) 个待检查").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.busy { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 16, height: 16) }
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 23, height: 23)
                }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(store.busy).help("立即检查")
            }
            if store.sites.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(store.busy ? "正在检查本机网站…" : "没有运行中的网站").font(.system(size: 14, weight: .medium))
                    Text("启动项目后打开本面板即可看到\n也可以手动添加本机地址").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 14)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.sites) { site in
                            SiteRow(site: site, result: store.results[site.id], edit: {
                                editedID = site.id; name = site.name; address = site.address; editing = true; store.message = ""
                            }, remove: { store.remove(site) })
                        }
                    }
                }.scrollIndicators(.hidden)
                    .frame(height: min(CGFloat(store.sites.count) * 66 - 8, listHeightLimit))
            }
            if editing { editor }
            if settings {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("自动发现本机网站", isOn: $store.autoDiscover).onChange(of: store.autoDiscover) { store.discoveryChanged() }
                    Toggle("登录时启动", isOn: Binding(get: { store.launchAtLogin }, set: { store.loginChanged($0) }))
                    Text("仅展开时检查 · 无后台轮询\n离线项目自动移出列表，重新运行后自动回来").font(.system(size: 11)).foregroundStyle(.secondary)
                    if !store.dormant.isEmpty {
                        HStack(spacing: 8) {
                            Text("已记住 \(store.dormant.count) 个离线项目").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button("清除") { store.forgetDormant() }.buttonStyle(.plain).font(.system(size: 11))
                        }
                    }
                    Button("退出 LocalWatch") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
                }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.mini).padding(14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
            }
            if !store.message.isEmpty { Text(store.message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button {
                    editedID = nil; name = ""; address = "http://127.0.0.1:"; editing.toggle(); store.message = ""
                } label: { Label("添加网站", systemImage: "plus").font(.system(size: 12, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 3) }
                    .buttonStyle(.glass)
                Spacer()
                if let time = store.lastCheck { Text(time, style: .time).font(.system(size: 10)).foregroundStyle(.tertiary).help("上次检查时间") }
                Button { settings.toggle() } label: { Image(systemName: "slider.horizontal.3").frame(width: 26, height: 26) }.buttonStyle(.plain).foregroundStyle(.secondary).help("设置")
            }
        }
        .padding(14).frame(width: 350).fixedSize(horizontal: false, vertical: true)
        .background { RoundedRectangle(cornerRadius: 20).fill(.clear).glassEffect(.regular, in: .rect(cornerRadius: 20)) }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
    }
    var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editedID == nil ? "添加本机网站" : "编辑网站").font(.system(size: 12, weight: .semibold))
            TextField("项目名称", text: $name)
            TextField("http://127.0.0.1:8796", text: $address).onSubmit { commit() }
            HStack {
                Text("支持 localhost、127.x.x.x 和 ::1").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { editing = false; store.message = "" }.buttonStyle(.plain)
                Button("保存", action: commit).buttonStyle(.glassProminent).tint(.teal)
            }.font(.system(size: 11))
        }.textFieldStyle(.roundedBorder).padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
    func commit() { if store.add(name: name, address: address, id: editedID) { editing = false } }
}
struct SiteRow: View {
    var site: Site
    var result: Probe?
    var edit: () -> Void
    var remove: () -> Void
    var color: Color { guard let result else { return .secondary }; return result.healthy ? .green : (result.online ? .orange : .red) }
    var status: String { guard let result else { return "未检查" }; return result.healthy ? "在线" : (result.online ? "HTTP \(result.code!)" : "离线") }
    var body: some View {
        HStack(spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12).fill(.teal.opacity(0.09)).frame(width: 34, height: 34)
                Text(String(site.name.prefix(1)).uppercased()).font(.system(size: 18, weight: .medium, design: .rounded)).frame(width: 34, height: 34).foregroundStyle(.teal)
                Circle().fill(color).frame(width: 8, height: 8).overlay(Circle().stroke(.background, lineWidth: 2)).offset(x: 1, y: 1)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(site.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(site.name)
                Text(site.address.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 3)
            VStack(alignment: .trailing, spacing: 5) {
                Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
                Text(result?.online == true ? "\(result!.milliseconds) ms" : "—").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Menu {
                Button("在浏览器中打开") { if let url = LocalURL.parse(site.address) { NSWorkspace.shared.open(url) } }
                Button("复制地址") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(site.address, forType: .string) }
                Button("编辑名称与地址", action: edit)
                Divider()
                Button("移除监控", action: remove)
            } label: { Image(systemName: "ellipsis").frame(width: 15, height: 25) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }.padding(12).frame(height: 58).background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(.primary.opacity(0.045), lineWidth: 1))
            .contentShape(Rectangle()).onTapGesture { if let url = LocalURL.parse(site.address) { NSWorkspace.shared.open(url) } }
            .help(result?.code.map { "HTTP \($0) · 点击打开网站" } ?? "未收到 HTTP 响应")
    }
}
@MainActor final class AnchoredPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let panel = AnchoredPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 150), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var outsideClick: Any?
    var localClick: Any?
    var desiredSize = CGSize(width: 350, height: 150)
    var store: Store!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出 LocalWatch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appItem)
        let editMenu = NSMenu(title: "编辑"); let editItem = NSMenuItem(); editItem.submenu = editMenu
        for (title, action, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        store = Store()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self; item.button?.action = #selector(toggle)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: Dashboard(store: store, onSizeChange: { [weak self] size in
            DispatchQueue.main.async { self?.resize(size) }
        }))
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.panel.orderOut(nil) }
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, let window = event.window, window != self.panel, window != self.item.button?.window, window.level == .normal { self.panel.orderOut(nil) }
            return event
        }
        store.onChange = { [weak self] in self?.update() }
        update()
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.toggle() } }
    }
    func update() {
        item.button?.image = NSImage(systemSymbolName: store.failures > 0 ? "network.badge.shield.half.filled" : "network", accessibilityDescription: "本机网站监控") ?? NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        item.button?.imagePosition = .imageLeading
        item.button?.title = store.lastCheck == nil ? " —" : " \(store.online)"
        item.button?.toolTip = store.lastCheck == nil ? "点击检查本机网站" : "上次检查：\(store.online) 个网站在线 · 点击刷新"
    }
    func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        desiredSize = size
        anchorPanel()
    }
    func anchorPanel() {
        guard let button = item.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = min(anchor.minY, visible.maxY) - 5
        let height = min(ceil(desiredSize.height), top - visible.minY - 8)
        let x = min(max(anchor.maxX - desiredSize.width, visible.minX + 8), visible.maxX - desiredSize.width - 8)
        panel.setFrame(NSRect(x: x, y: top - height, width: desiredSize.width, height: height), display: true)
    }
    @objc func toggle() {
        if panel.isVisible { panel.orderOut(nil) }
        else {
            anchorPanel()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            Task { await store.refresh() }
        }
    }
}
@main struct LocalWatchApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
