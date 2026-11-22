import AppKit
import Combine
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
    private let playerStatusItem = NSMenuItem(title: "播放器：未连接", action: nil, keyEquivalent: "")

    private var cancellables = Set<AnyCancellable>()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var isShown = false
    private var lastPanelSize = NSSize.zero

    private let panelWidth: CGFloat = 520
    private let maxPanelHeight: CGFloat = 760

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

        let openItem = NSMenuItem(title: "打开控制面板", action: #selector(menuOpenPanel), keyEquivalent: "")
        openItem.target = self
        contextMenu.addItem(openItem)

        let scanItem = NSMenuItem(title: "扫描设备", action: #selector(menuScan), keyEquivalent: "")
        scanItem.target = self
        contextMenu.addItem(scanItem)

        let connectItem = NSMenuItem(title: "连接到…", action: #selector(menuPromptConnect), keyEquivalent: "")
        connectItem.target = self
        contextMenu.addItem(connectItem)

        contextMenu.addItem(.separator())

        playerStatusItem.isEnabled = false
        contextMenu.addItem(playerStatusItem)

        let rediscoverItem = NSMenuItem(title: "重新发现 No Glass Player", action: #selector(menuRediscoverPlayer), keyEquivalent: "")
        rediscoverItem.target = self
        contextMenu.addItem(rediscoverItem)

        contextMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 WDeviceController", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        contextMenu.addItem(quitItem)
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
        let symbol = viewModel.isConnected ? "hifispeaker.fill" : "hifispeaker"
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WDeviceController") else {
            return
        }
        image.size = NSSize(width: 18, height: 16)
        image.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = viewModel.isConnected
            ? "WDeviceController · 已连接"
            : "WDeviceController · 未连接"
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
        let available = (screen?.visibleFrame.height ?? 900) - 80
        let heightLimit = min(maxPanelHeight, max(240, available))

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
        if viewModel.isPlayerLinked {
            let name = viewModel.playerLinkName ?? "No Glass Player"
            playerStatusItem.title = viewModel.isPlayerLinkPrimary
                ? "播放器：\(name)（联动中）"
                : "播放器：\(name)（已连接）"
        } else {
            playerStatusItem.title = "播放器：未发现"
        }
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenPanel() {
        show()
    }

    @objc private func menuScan() {
        viewModel.scan()
    }

    @objc private func menuRediscoverPlayer() {
        viewModel.rediscoverPlayerLink()
    }

    @objc private func menuPromptConnect() {
        let alert = NSAlert()
        alert.messageText = "连接到设备"
        alert.informativeText = "输入设备的 IP 地址，或 IP:端口（默认端口 9000）。"
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "192.168.1.100:9000"
        field.stringValue = viewModel.selectedDevice?.ip ?? ""
        alert.accessoryView = field
        alert.window.level = .floating

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            viewModel.connectManually(field.stringValue)
        }
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}
