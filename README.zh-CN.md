# LocalWatch

<img src="docs/images/localwatch-icon.png" width="128" alt="LocalWatch app icon">

[English](README.md) | **简体中文**

macOS 菜单栏本地网站管理工具。集中查看和打开正在运行的 localhost 网站，适合同时开发多个 Web 项目、运行本地仪表板及 HTTP API 的用户。

## 界面截图

![网站主面板](docs/images/localwatch-dashboard.png)

![设置界面](docs/images/localwatch-settings.png)

## 功能

- 点击菜单栏图标查看网站、HTTP 状态和响应时间，点击卡片在默认浏览器打开。
- 自动发现当前用户的本机 HTTP 服务，支持手动添加、编辑、复制和移除地址。
- 检查后无在线网站时每 30 秒刷新；发现至少一个在线网站后停止轮询，只在展开面板或手动刷新时检查。展示上次检查结果，启动时尚未检查不会轮询。
- 离线网站自动隐藏并记住，恢复后在下一次检查时重新显示。
- 原生 SwiftUI / Liquid Glass 界面，面板高度随网站数量调整。
- 面板底部提供 EN / 中 按钮，一键切换中文与英文并记住选择。
- 支持登录时启动，退出应用不影响网站服务。
- 可选“无在线网站时隐藏菜单栏图标”（默认关闭）；开启后在检查发现无在线网站时隐藏图标，每 30 秒刷新，发现在线网站后恢复图标并停止轮询。面板展开时保留入口，隐藏后也可再次打开应用调出面板并刷新。
- 无账号、无遥测上传，配置保存在当前用户的 macOS 偏好设置中。

## 安装

需要 **Apple Silicon Mac、macOS 26 或更新版本**。当前发布包仅提供 arm64 架构。

从 [Releases](https://github.com/ethan6945/LocalWatch/releases) 下载 ZIP，解压后把 LocalWatch.app 放进 Applications 文件夹，双击启动。应用只出现在菜单栏，无 Dock 图标。

发布包使用 ad-hoc 签名，未经 Apple Developer ID 签名和公证，其他 Mac 可能被 Gatekeeper 拦截。确认来源后可按系统提示在“系统设置 → 隐私与安全性”允许打开，或自行编译源码。

## 使用与状态含义

展开面板即可发现服务，右下角设置可调整自动发现、登录启动和无在线网站时隐藏图标。底部提供语言切换与退出图标。

绿色表示 HTTP 200–399，橙色表示 HTTP 400–599。橙色仍计入在线数量；连接失败、超时或 TLS 错误重试一次后归为离线。HTTP 可访问性不代表业务功能全部正常。

手动地址支持 HTTP / HTTPS，仅限 localhost、127.x.x.x、::1，例如 `http://localhost:3000/`、`http://[::1]:8080/`。检查不跟随重定向。自动发现使用 IPv4 HTTP；HTTPS-only 或 IPv6-only 服务请手动添加。主动移除的地址不会自动重新加入。

## 从源码构建

安装 Apple Command Line Tools（`xcode-select --install`），运行：

```sh
./build.command
open LocalWatch.app
```

无需 Xcode 工程或第三方依赖。脚本生成应用并进行本地签名；遇到 SwiftUI 宏插件不可用时，会尝试已安装的兼容 SDK。需要兼容的 Swift 工具链及 macOS SDK。

当前版本为 **v1.1.0**，见 [更新记录](CHANGELOG.md)。

## 支持

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-ffdd00?style=for-the-badge&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/ethan6945)
