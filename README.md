# WDeviceController for macOS

Waversa 官方网页 App 的 macOS 原生实现：菜单栏常驻，
用与网页 App 相同的 UDP 发现 + WebSocket 协议遥控 WNDR / WRemote 音频设备。

![面板](docs/panel.png)

> 个人作品，不是 Waversa Systems 官方软件，也不代表官方立场。
> 设备指令是从官方网页 App 与网络流量里反推出来的，目前只在 WSlimPro 上实测过，
> 其他机型请自行验证。

## 功能

- 菜单栏图标 + 轻量弹出面板（`NSPanel`，不抢焦点、点击外部自动收起、Esc 关闭）
- 音量 / 静音、音源切换、待机、播放 / 上一首 / 下一首
- FM 频段与预设（`preset_list` 推送）切换，已在带 FM 硬件的机型上实测通过
- 设备菜单动态渲染（Output Mode / Digital Filter / Screen Brightness 等），改动即时下发并接受设备回推校正
- UDP 9400 局域网发现 + WebSocket 控制，断线按 2/4/8/16/30 秒退避自动重连
- 全中文界面，深浅色自适应

## 下载

从 [Releases](https://github.com/codecos/WDeviceControllerMac/releases) 取最新包（Apple Silicon / macOS 13+）：

- `WDeviceController-1.0.0-arm64.dmg`：挂载后把 App 拖到旁边的「应用程序」快捷方式
- `WDeviceController-1.0.0-arm64.zip`：解压得到 App，自行拖进「应用程序」

应用为 ad-hoc 签名（无开发者证书），首次打开会被 Gatekeeper 拦下：
在「应用程序」里右键 →「打开」，或执行 `xattr -dr com.apple.quarantine /Applications/WDeviceController.app`。

**它是菜单栏应用，没有 Dock 图标，也不会弹主窗口**：双击后看起来「什么都没发生」，
实际图标在屏幕右上角菜单栏（喇叭图标，已连接时为实心），点它才展开面板。
菜单栏太挤被折叠时，可以用「打开控制面板」的右键菜单，或直接看菜单栏末尾的 `»`。

## 系统要求

- macOS 13 (Ventura) 或更高
- 构建需 Xcode 命令行工具（Swift 5.9+）
- 无第三方依赖

## 构建与运行

```bash
cd WDeviceControllerMac
./scripts/build-app.sh              # Release，产物在 build/WDeviceController.app
open build/WDeviceController.app
```

开发调试：

```bash
swift build -c debug                # 仅编译
CONFIG=debug ./scripts/build-app.sh # 组装 debug 版 .app
```

应用使用 ad-hoc 签名。首次运行时系统会询问本地网络权限，**必须允许**，否则既发现不了设备也连不上。

## 使用

1. 启动后**只在菜单栏**出现控制器图标（无 Dock 图标、无主窗口），点击展开面板
2. 面板会自动连接上次使用的设备；换网络后会用 UDP 广播重新扫描并连接发现到的第一台
3. 下拉框里的 `设备名 (IP)` 可手动输入地址；右侧按钮为刷新、重新扫描、断开
4. 音源下拉框切换 USB / WNDR / Optical / Coaxial / FM / Roon Ready 等输入
5. 「设置」进入设备菜单页，每次打开都会重新拉取 `menulist`

## 连接与协议

- 发现：UDP 9400 广播 `search`，取响应里的 `ipv4_addr`
- 控制：`ws://<ip>:9000`，子协议 `wremote-protocol, json`
- `wndr-port`（如 9200）是音频输出端口，**不是**控制端口；控制连接固定走 9000，
  旧配置连不上时自动回退
- 设备同一时间只允许一个控制端（先到先得）。网页 App 或手机 App 抢占、设备重启、Wi-Fi 抖动导致的断开，
  会自动退避重连
- 修改设置走 `settings` 报文（`id` / `handler` / `type` / `eeprom_addr` / `value`），
  以设备回推的新 `menulist` 为准；发送失败会回滚界面

## 已知限制

- **Roon Ready 兼容性不保证**：相关逻辑是很早以前写的，之后没有设备复测，
  行为可能和设备固件版本对不上；能切音源、能显示曲目信息就属于“碰巧可用”，出问题不修。
- **进度条不支持拖拽 seek**：Roon Ready 官方协议本身有 seek 方法，只是本实现没写，
  界面上的进度条只做展示，短期内也不打算实现。
- 未实现开机自启、英文界面、多设备同时保存。

### 播放栏显示条件

只有真的拿到曲目信息（`playstatus` 里有 `title` / `artist`，或 `play_length > 0`）才显示
Now Playing 卡片。Roon Ready 空闲时设备不提供这类信息，卡片与传输控制整体隐藏，
不会出现空白播放栏；切回有内容的音源会自动恢复。

## 调试开关（仅 DEBUG 构建）

```bash
WDC_SHOW_PANEL=1                   # 启动 2 秒后自动展开面板
WDC_OPEN_MENU=1                    # 启动 4 秒后打开设置页
WDC_SELFTEST=1                     # 启动 5 秒后调音量并切换播放，验证发送链路
WDC_DROP_AFTER=6                   # 启动 6 秒后主动断开，验证自动重连
WDC_MENU_TEST="Screeen Brightness" # 启动 6 秒后把该菜单项切到另一个值，5 秒后切回（会真的改设备）
WDC_SOURCE="Roon Ready"            # 启动 7 秒后切到该音源，验证播放栏显示/隐藏
```

## 目录结构

```
WDeviceControllerMac/
├── Package.swift                  # SwiftPM（macOS 13+，可执行 target）
├── Resources/
│   ├── Info.plist                 # LSUIElement、ATS、本地网络说明
│   └── AppIcon.icns
├── scripts/
│   ├── build-app.sh               # SwiftPM 编译 + 组装 .app + ad-hoc 签名
│   └── make-icon.swift            # 由托盘图标生成 .icns
├── docs/panel.png                 # 界面截图
└── Sources/WDeviceControllerMac/
    ├── AppMain.swift              # NSApplication 入口、菜单栏控制器装配
    ├── StatusItemController.swift # 状态栏图标、弹出面板定位/点击外部关闭
    ├── PanelView.swift            # 快捷控制页 / 设置页
    ├── UIComponents.swift         # 面板卡片、按钮、工具条等
    ├── MainViewModel.swift        # 音量防抖、消息分发、菜单、FM
    ├── WebSocketService.swift     # 设备 WebSocket（子协议 wremote-protocol）
    ├── DiscoveryService.swift     # UDP 9400 设备发现
    ├── PlayerLinkService.swift
    ├── Models.swift               # 设备协议 DTO
    ├── MenuModels.swift           # 菜单 UI 模型
    └── AlbumArtLoader.swift       # 封面加载与降采样
```

## 实现要点

- 设备发现除 UDP 广播外会额外探测本机网卡所在网段，便于多网卡环境
- 面板用 `NSPanel` 实现，不进入 Mission Control，也不出现在 Dock
- 菜单栏图标使用 SF Symbol 模板图，自动适配深浅色与强调色

## 许可证

本项目采用 [CC BY-NC 4.0](LICENSE)（署名—非商业性使用 4.0 国际）。

- 可以：个人使用、修改、再分发，需保留作者署名并注明许可
- 不可以：商业用途，包括付费分发、随硬件或服务捆绑销售、闭源商业产品内集成
- 上架 Mac App Store 或第三方商店通常被视为商业分发，按本许可不允许
- 二次修改后的版本请同样以 CC BY-NC 4.0 发布，并说明改动
