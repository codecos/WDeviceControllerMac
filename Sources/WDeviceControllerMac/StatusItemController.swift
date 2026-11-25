import AppKit
import Combine
import ServiceManagement
import SwiftUI

final class FlyoutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusItemController: NSObject {
    private let viewModel: MainViewModel
    private let statusItem: NSStatusItem
    private let panel: FlyoutPanel
    private let hostingView: NSHostingView<PanelView>
    private let contextMenu = NSMenu()
    private let launchAtLoginItem = NSMenuItem(title: L("开机启动", "Launch at Login"), action: nil, keyEquivalent: "")

    private var cancellables = Set<AnyCancellable>()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var isShown = false
    private var lastPanelSize = NSSize.zero

    private let panelWidth: CGFloat = 520

    init(viewModel: MainViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let hosting = NSHostingView(rootView: PanelView(viewModel: viewModel, onEscape: {}))
        self.hostingView = hosting

        self.panel = FlyoutPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        configureStatusItem()
        configurePanel()
        configureMenu()
        bindViewModel()
    }

    // MARK: - 配置

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusButtonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.toolTip = "WDeviceController"
        updateStatusIcon()
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: 480)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        panel.contentView = hostingView

        hostingView.rootView = PanelView(viewModel: viewModel, onEscape: { [weak self] in
            self?.handleEscape()
        })

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    private func configureMenu() {
        contextMenu.autoenablesItems = false

        let openItem = NSMenuItem(title: L("打开面板", "Open Panel"), action: #selector(menuOpenPanel), keyEquivalent: "")
        openItem.target = self
        contextMenu.addItem(openItem)

        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(menuToggleLaunchAtLogin)
        launchAtLoginItem.state = Self.isLaunchAtLoginEnabled ? .on : .off
        contextMenu.addItem(launchAtLoginItem)

        contextMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("退出", "Quit"), action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        contextMenu.addItem(quitItem)
    }

    // MARK: - 开机启动

    private static var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func menuToggleLaunchAtLogin() {
        let enabled = launchAtLoginItem.state != .on
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            presentLaunchAtLoginFailure(error)
        }
        launchAtLoginItem.state = Self.isLaunchAtLoginEnabled ? .on : .off
    }

    private func presentLaunchAtLoginFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("无法修改开机启动设置", "Couldn't change Launch at Login")
        alert.informativeText = """
        \(error.localizedDescription)

        \(L("请先把 WDeviceController 拖到「应用程序」文件夹再试一次；如果仍然失败，可在「系统设置 › 通用 › 登录项」里手动添加。", "Move WDeviceController into the Applications folder and try again. If it still fails, add it manually in System Settings › General › Login Items."))
        """
        alert.addButton(withTitle: L("好", "OK"))
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func bindViewModel() {
        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateStatusIcon()
                    if self.isShown {
                        self.refreshLayout()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon() {
        let connected = viewModel.isConnected
        // 与 App 图标同一套滑杆语义；菜单栏只能用模板字形，粗细 + 透明度承担连接状态。
        guard let image = statusIcon(connected: connected) else { return }
        statusItem.button?.image = image
        statusItem.button?.toolTip = connected
            ? L("WDeviceController · 已连接", "WDeviceController · Connected")
            : L("WDeviceController · 未连接", "WDeviceController · Disconnected")
    }

    /// 模板图只认 alpha，未连接时把透明度压进图里，系统着色深浅都不会把它提亮。
    private func statusIcon(connected: Bool) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 15,
            weight: connected ? .semibold : .regular
        )
        guard let symbol = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: "WDeviceController"
        )?.withSymbolConfiguration(configuration) else {
            return nil
        }

        let size = NSSize(width: 18, height: 16)
        symbol.size = size
        if connected {
            symbol.isTemplate = true
            return symbol
        }

        let dimmed = NSImage(size: size)
        dimmed.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 0.45)
        dimmed.unlockFocus()
        dimmed.isTemplate = true
        return dimmed
    }

    // MARK: - 显示/隐藏

    @objc private func statusButtonClicked() {
        guard let event = NSApp.currentEvent else {
            toggle()
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            toggle()
        }
    }

    private func toggle() {
        if isShown {
            hide()
        } else {
            show()
        }
    }

    func show() {
        refreshLayout()
        // 闲置久了连接可能已经假死，展开面板时先探一次活。
        viewModel.panelDidShow()

        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchorInWindow = button.convert(button.bounds, to: nil)
        let anchor = buttonWindow.convertToScreen(anchorInWindow)

        let size = panel.frame.size
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = anchor.midX - size.width / 2
        var y = anchor.minY - size.height - 6

        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        if y < visible.minY + 8 {
            y = anchor.maxY + 6
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        // 不把焦点默认给第一个 Picker，否则会一直显示蓝色聚焦环；点击控件时再自然获得焦点。
        panel.makeFirstResponder(nil)
        isShown = true
        installClickMonitors()
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel.orderOut(nil)
        removeClickMonitors()
    }

    private func handleEscape() {
        if viewModel.isMenuVisible {
            viewModel.closeMenu()
            refreshLayout()
        } else {
            hide()
        }
    }

    // MARK: - 尺寸

    private func refreshLayout() {
        hostingView.layoutSubtreeIfNeeded()
        var size = hostingView.fittingSize

        let screen = panel.screen ?? NSScreen.main
        // 不再固定高度的上限：菜单项全部展开显示，最多到屏幕可用高度。
        let available = (screen?.visibleFrame.height ?? 900) - 80
        let heightLimit = max(240, available)

        size.width = panelWidth
        size.height = min(max(size.height, 140), heightLimit)

        guard size != lastPanelSize else { return }
        lastPanelSize = size

        let top = panel.frame.maxY
        panel.setContentSize(size)
        hostingView.frame = NSRect(origin: .zero, size: size)

        if isShown {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - size.height))
        }
    }

    // MARK: - 点击外部关闭

    private func installClickMonitors() {
        removeClickMonitors()

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.isShown else { return event }
            if event.window === self.panel { return event }
            if self.isStatusBarWindow(event.window) { return event }
            self.hide()
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeClickMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func isStatusBarWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return NSStringFromClass(type(of: window)).contains("StatusBar")
    }

    @objc private func applicationDidResignActive() {
        hide()
    }

    // MARK: - 右键菜单

    private func showContextMenu() {
        hide()
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenPanel() {
        show()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}
