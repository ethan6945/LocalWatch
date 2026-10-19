import SwiftUI
import AppKit
import ServiceManagement

func tr(_ chinese: String, _ english: String) -> String {
    UserDefaults.standard.string(forKey: "language") == "en" ? english : chinese
}

@MainActor final class Store: ObservableObject {
    @Published var sites: [Site] = []
    @Published var results: [UUID: Probe] = [:]
    @Published var dormant: [Site] = []
    @Published var busy = false
    @Published var lastCheck: Date?
    @Published var autoDiscover = UserDefaults.standard.object(forKey: "discover") as? Bool ?? true
    @Published var hideWhenIdle = UserDefaults.standard.bool(forKey: "hideWhenIdle")
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var english = UserDefaults.standard.string(forKey: "language") == "en"
    @Published var message = ""
    func toggleLanguage() {
        english.toggle()
        UserDefaults.standard.set(english ? "en" : "zh", forKey: "language")
        message = ""
        onChange?()
    }
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
    func add(name: String, address: String, id: UUID? = nil) -> Bool {
        guard let url = LocalURL.parse(address) else { message = tr("请输入本机地址，例如 http://127.0.0.1:8796", "Enter a local URL, e.g. http://127.0.0.1:8796"); return false }
        let address = url.absoluteString
        if sites.contains(where: { $0.address == address && $0.id != id }) { message = tr("这个地址已在列表中", "This address is already in the list"); return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, let index = sites.firstIndex(where: { $0.id == id }) {
            sites[index].name = name.isEmpty ? tr("本机项目 · \(url.port ?? 80)", "Local project · \(url.port ?? 80)") : name
            sites[index].address = address
            results.removeValue(forKey: id)
        } else {
            sites.append(Site(name: name.isEmpty ? tr("本机项目 · \(url.port ?? 80)", "Local project · \(url.port ?? 80)") : name, address: address))
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
                let name = result.title ?? tr("本机项目 · \(port)", "Local project · \(port)")
                let site = Site(name: name, address: address, automatic: true)
                sites.append(site); results[site.id] = result
            }
        }
        save()
    }
    func idleVisibilityChanged() {
        UserDefaults.standard.set(hideWhenIdle, forKey: "hideWhenIdle")
        onChange?()
    }
    func discoveryChanged() { UserDefaults.standard.set(autoDiscover, forKey: "discover") }
    func loginChanged(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { message = tr("请在系统设置 → 通用 → 登录项中允许 LocalWatch", "Allow LocalWatch in System Settings → General → Login Items"); SMAppService.openSystemSettingsLoginItems() }
        } catch { message = tr("登录启动设置失败：\(error.localizedDescription)", "Login launch failed: \(error.localizedDescription)"); launchAtLogin = SMAppService.mainApp.status == .enabled }
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
                Text(store.lastCheck == nil ? tr("尚未检查", "Not checked") : tr("\(store.online) 个在线", "\(store.online) online")).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                if store.failures > 0 {
                    Text(tr("· \(store.failures) 个待检查", "· \(store.failures) need checking")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.busy { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 16, height: 16) }
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 23, height: 23)
                }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(store.busy).help(tr("立即检查", "Refresh now"))
            }
            if store.sites.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(store.busy ? tr("正在检查本机网站…", "Checking local websites…") : tr("没有运行中的网站", "No websites running")).font(.system(size: 14, weight: .medium))
                    Text(tr("启动项目后打开本面板即可看到\n也可以手动添加本机地址", "Start a project, then open this panel.\nYou can also add a local URL manually.")).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 14)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.sites) { site in
                            SiteRow(store: store, site: site, result: store.results[site.id], edit: {
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
                    settingsToggle(tr("自动发现本机网站", "Discover local websites"), isOn: $store.autoDiscover).onChange(of: store.autoDiscover) { store.discoveryChanged() }
                    settingsToggle(tr("登录时启动", "Launch at login"), isOn: Binding(get: { store.launchAtLogin }, set: { store.loginChanged($0) }))
                    settingsToggle(tr("无在线网站时隐藏菜单栏图标", "Hide icon when no sites are online"), isOn: $store.hideWhenIdle)
                        .onChange(of: store.hideWhenIdle) { store.idleVisibilityChanged() }
                    Text(tr("无在线网站时每 30 秒检查，恢复后自动显示\n有在线网站时仅展开或手动刷新才检查", "No sites online: check every 30 seconds.\nSites online: check on open or refresh."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.mini)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
            }
            if !store.message.isEmpty { Text(store.message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button {
                    editedID = nil; name = ""; address = "http://127.0.0.1:"; editing.toggle(); store.message = ""
                } label: { Label(tr("添加网站", "Add website"), systemImage: "plus").font(.system(size: 12, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 3) }
                    .buttonStyle(.glass)
                Spacer()
                Button { store.toggleLanguage() } label: {
                    Text(store.english ? "中" : "EN")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(store.english ? "Switch to Chinese" : "切换到英文")
                .accessibilityLabel(store.english ? "Switch to Chinese" : "切换到英文")
                Button { settings.toggle() } label: { Image(systemName: "slider.horizontal.3").frame(width: 26, height: 26) }.buttonStyle(.plain).foregroundStyle(.secondary).help(tr("设置", "Settings"))
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tr("退出 LocalWatch", "Quit LocalWatch"))
                .accessibilityLabel(tr("退出 LocalWatch", "Quit LocalWatch"))
            }
        }
        .padding(14).frame(width: 350).fixedSize(horizontal: false, vertical: true)
        .background { RoundedRectangle(cornerRadius: 20).fill(.clear).glassEffect(.regular, in: .rect(cornerRadius: 20)) }
        .environment(\.locale, Locale(identifier: store.english ? "en_US" : "zh_CN"))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
    }
    func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden().fixedSize()
                .accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editedID == nil ? tr("添加本机网站", "Add local website") : tr("编辑网站", "Edit website")).font(.system(size: 12, weight: .semibold))
            TextField(tr("项目名称", "Project name"), text: $name)
            TextField("http://127.0.0.1:8796", text: $address).onSubmit { commit() }
            HStack {
                Text(tr("支持 localhost、127.x.x.x 和 ::1", "Supports localhost, 127.x.x.x and ::1")).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(tr("取消", "Cancel")) { editing = false; store.message = "" }.buttonStyle(.plain)
                Button(tr("保存", "Save"), action: commit).buttonStyle(.glassProminent).tint(.teal)
            }.font(.system(size: 11))
        }.textFieldStyle(.roundedBorder).padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
    func commit() { if store.add(name: name, address: address, id: editedID) { editing = false } }
}
struct SiteRow: View {
    @ObservedObject var store: Store
    var site: Site
    var result: Probe?
    var edit: () -> Void
    var remove: () -> Void
    var color: Color { guard let result else { return .secondary }; return result.healthy ? .green : (result.online ? .orange : .red) }
    var status: String { guard let result else { return tr("未检查", "Not checked") }; return result.healthy ? tr("在线", "Online") : (result.online ? "HTTP \(result.code!)" : tr("离线", "Offline")) }
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
                Button(tr("在浏览器中打开", "Open in browser")) { if let url = LocalURL.parse(site.address) { NSWorkspace.shared.open(url) } }
                Button(tr("复制地址", "Copy URL")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(site.address, forType: .string) }
                Button(tr("编辑名称与地址", "Edit name and URL"), action: edit)
                Divider()
                Button(tr("移除监控", "Remove website"), action: remove)
            } label: { Image(systemName: "ellipsis").frame(width: 15, height: 25) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }.padding(12).frame(height: 58).background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(.primary.opacity(0.045), lineWidth: 1))
            .contentShape(Rectangle()).onTapGesture { if let url = LocalURL.parse(site.address) { NSWorkspace.shared.open(url) } }
            .help(result?.code.map { tr("HTTP \($0) · 点击打开网站", "HTTP \($0) · Click to open") } ?? tr("未收到 HTTP 响应", "No HTTP response"))
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
    var idleTimer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: tr("退出 LocalWatch", "Quit LocalWatch"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appItem)
        let editMenu = NSMenu(title: tr("编辑", "Edit")); let editItem = NSMenuItem(); editItem.submenu = editMenu
        for (title, action, key) in [(tr("剪切", "Cut"), "cut:", "x"), (tr("复制", "Copy"), "copy:", "c"), (tr("粘贴", "Paste"), "paste:", "v"), (tr("全选", "Select All"), "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        store = Store()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self; item.button?.action = #selector(toggle)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass material already draws its edge. A second window shadow can
        // expose the rectangular backing surface around transparent corners.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: Dashboard(store: store, onSizeChange: { [weak self] size in
            DispatchQueue.main.async { self?.resize(size) }
        }))
        // Clip the AppKit backing surface as well as the SwiftUI glass shape.
        if let content = panel.contentView {
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor
            content.layer?.cornerRadius = 20
            content.layer?.cornerCurve = .continuous
            content.layer?.masksToBounds = true
            content.layer?.borderWidth = 0
        }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.panel.orderOut(nil); self?.update() }
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, let window = event.window, window != self.panel, window != self.item.button?.window, window.level == .normal { self.panel.orderOut(nil); self.update() }
            return event
        }
        store.onChange = { [weak self] in self?.update() }
        update()
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.toggle() } }
    }
    func update() {
        if let menu = NSApp.mainMenu {
            menu.items.first?.submenu?.items.first?.title = tr("退出 LocalWatch", "Quit LocalWatch")
            if menu.items.count > 1, let edit = menu.items[1].submenu {
                edit.title = tr("编辑", "Edit")
                menu.items[1].title = edit.title
                for (index, title) in [tr("剪切", "Cut"), tr("复制", "Copy"), tr("粘贴", "Paste"), tr("全选", "Select All")].enumerated() {
                    edit.items[index].title = title
                }
            }
        }
        // Poll only after a completed check found no online sites. Once a site
        // responds, return to checks triggered by opening the panel or refresh.
        let shouldPoll = store.lastCheck != nil && store.online == 0
        if shouldPoll && idleTimer == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.store.online == 0 else { return }
                    await self.store.refresh()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            idleTimer = timer
        } else if !shouldPoll {
            idleTimer?.invalidate()
            idleTimer = nil
        }
        item.isVisible = !store.hideWhenIdle || store.lastCheck == nil || store.online > 0 || panel.isVisible
        item.button?.image = NSImage(systemSymbolName: store.failures > 0 ? "network.badge.shield.half.filled" : "network", accessibilityDescription: tr("本机网站监控", "Local website monitor")) ?? NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        item.button?.imagePosition = .imageLeading
        item.button?.title = store.lastCheck == nil ? " —" : " \(store.online)"
        item.button?.toolTip = store.lastCheck == nil ? tr("点击检查本机网站", "Click to check local websites") : tr("上次检查：\(store.online) 个网站在线 · 点击刷新", "Last check: \(store.online) sites online · Click to refresh")
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
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }
    func showPanel() {
        item.isVisible = true
        anchorPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        Task { await store.refresh() }
    }
    @objc func toggle() {
        if panel.isVisible { panel.orderOut(nil); update() }
        else {
            showPanel()
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
