import AppKit
import Combine
import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    // MARK: - 连接与设备

    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isScanning = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var bitrate = "--"
    @Published private(set) var isDeviceStandby = false

    // MARK: - 播放器联动（No Glass Player）

    @Published private(set) var isPlayerLinked = false
    @Published private(set) var playerLinkName: String?
    @Published private(set) var isPlayerLinkPrimary = false

    // MARK: - 音量与音源

    @Published private(set) var volume: Double = 0
    @Published private(set) var volumeMin: Double = 0
    @Published private(set) var volumeMax: Double = 100
    @Published private(set) var isMuted = false
    @Published private(set) var availableSources: [String] = []
    @Published private(set) var selectedSource: String?

    // MARK: - Now Playing

    @Published private(set) var nowPlayingTitle = ""
    @Published private(set) var nowPlayingArtist = ""
    @Published private(set) var nowPlayingAlbum = ""
    @Published private(set) var albumArt: NSImage?
    @Published private(set) var isNowPlayingVisible = false
    @Published private(set) var isPlaying = false
    @Published private(set) var playPosition = 0
    @Published private(set) var playLength = 0

    // MARK: - FM

    @Published private(set) var fmPresetNumber = 1
    @Published private(set) var fmFrequency = "--.-"
    @Published private(set) var fmPresetTitle = "PRESET 1"

    // MARK: - 设置菜单

    @Published private(set) var menuGroups: [MenuGroup] = []
    @Published private(set) var isMenuVisible = false

    // MARK: - 内部状态

    private lazy var webSocket = WebSocketService(
        onState: { [weak self] connected in
            Task { @MainActor in self?.handleConnectionChange(connected) }
        },
        onMessage: { [weak self] text in
            Task { @MainActor in self?.handleMessage(text) }
        }
    )

    private let playerLink = PlayerLinkService()
    private var latestPlayerSnapshot: PlayerLinkSnapshot?

    private var initialized = false
    private var shouldAutoReconnect = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var suppressIncoming = false
    private var applyingDeviceState = false
    private var isUserAdjustingVolume = false
    private var lastSentVolume: Int?
    private var lastSentAt = Date.distantPast
    private var lastPlayToggleAt = Date.distantPast
    private var playTogglePending = false

    private var volumeDebounceTask: Task<Void, Never>?
    private var suppressTask: Task<Void, Never>?
    private var playToggleTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var pendingStatus: String?
    private var albumArtTask: Task<Void, Never>?
    private var currentAlbumArtURI: String?

    private let volumeSuppressWindow: TimeInterval = 0.8
    private let volumeDebounceDelay: TimeInterval = 0.18
    private let volumeDragDebounceDelay: TimeInterval = 0.055
    private let playSuppressWindow: TimeInterval = 0.8
    private let playConfirmTimeout: TimeInterval = 3.0

    private var availableSourceSet = Set<String>()
    private var fmChannel = 0
    private var fmFrequencyRaw = 0
    private var fmInfoTitle = ""
    private var fmPresetNames = [String](repeating: "", count: 16)

    private let defaults = UserDefaults.standard
    private static let lastHostKey = "lastDeviceHost"
    private static let lastPortKey = "lastDevicePort"
    private static let lastNameKey = "lastDeviceName"

    // MARK: - 计算属性

    var deviceState: String {
        if !isConnected { return L("未连接", "Disconnected") }
        return isDeviceStandby ? L("待机", "Standby") : L("已连接", "Connected")
    }

    var isFmVisible: Bool {
        (selectedSource ?? "").caseInsensitiveCompare("FM") == .orderedSame
    }

    var playProgress: Double {
        playLength > 0 ? Double(playPosition) * 100.0 / Double(playLength) : 0
    }

    var playPositionText: String { Self.formatSeconds(playPosition) }
    var playLengthText: String { Self.formatSeconds(playLength) }
    var playPauseSymbol: String { isPlaying ? "pause.fill" : "play.fill" }

    var volumeText: String { "\(Int(volume.rounded()))" }

    var selectedDevice: DeviceInfo? {
        devices.first { $0.id == selectedDeviceID }
    }

    private static func formatSeconds(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    init() {
        statusMessage = "Ready"
        loadSavedDevice()

        playerLink.onConnectionChange = { [weak self] connected, name in
            Task { @MainActor in self?.handlePlayerLinkConnection(connected, name: name) }
        }
        playerLink.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in self?.handlePlayerSnapshot(snapshot) }
        }

        // 换到 Retina / 外接屏后按新的 backingScaleFactor 重新取封面（对应 Windows 的 UpdateAlbumArtRenderScale）。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let uri = self.currentAlbumArtURI else { return }
                self.currentAlbumArtURI = nil
                self.applyAlbumArt(uri)
            }
        }
    }

    func start() {
        guard !initialized else { return }
        initialized = true
        playerLink.start()

        Task { [weak self] in
            guard let self else { return }
            if let device = self.selectedDevice {
                await self.connect(host: device.ip, port: device.port, name: device.hostname)
            }
            if !self.isConnected {
                await self.performScan(autoConnectFirst: true)
            }
        }
    }

    // MARK: - 扫描与连接

    func scan() {
        guard !isScanning else { return }
        Task { await performScan(autoConnectFirst: false) }
    }

    private func performScan(autoConnectFirst: Bool) async {
        guard !isScanning else { return }
        isScanning = true
        setStatusThrottled("正在扫描设备…")

        let found = await DiscoveryService.scan(timeout: 4)
        devices = mergeFoundDevices(found)
        isScanning = false

        if found.isEmpty {
            statusMessage = isConnected ? statusMessage : "未发现设备，可右键菜单栏图标手动连接"
            return
        }

        statusMessage = "发现 \(found.count) 台设备"

        if autoConnectFirst, !isConnected, let first = found.first {
            selectedDeviceID = first.id
            await connect(host: first.ip, port: first.port, name: first.hostname)
        }
    }

    private func mergeFoundDevices(_ found: [DeviceInfo]) -> [DeviceInfo] {
        var result = found
        if let selectedDevice, !result.contains(where: { $0.id == selectedDevice.id }) {
            result.insert(selectedDevice, at: 0)
        }
        return result
    }

    func selectDevice(id: String?) {
        guard let id, let device = devices.first(where: { $0.id == id }) else { return }
        guard id != selectedDeviceID || !isConnected else { return }
        selectedDeviceID = id
        Task { await connect(host: device.ip, port: device.port, name: device.hostname) }
    }

    func connectToSelectedDevice() {
        guard let device = selectedDevice else { return }
        Task { await connect(host: device.ip, port: device.port, name: device.hostname) }
    }

    func connectManually(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var host = trimmed
        var port = 9000
        if let colon = trimmed.lastIndex(of: ":"), trimmed[trimmed.index(after: colon)...].allSatisfy(\.isNumber),
           let parsed = Int(trimmed[trimmed.index(after: colon)...]) {
            host = String(trimmed[..<colon])
            port = parsed
        }

        let device = DeviceInfo(hostname: host, ip: host, port: port)
        devices = mergeFoundDevices(devices + [device].filter { candidate in
            !devices.contains(where: { $0.id == candidate.id })
        })
        selectedDeviceID = device.id
        Task { await connect(host: host, port: port, name: host) }
    }

    func connect(host: String, port: Int, name: String? = nil) async {
        guard !isConnecting else { return }
        cancelReconnect()
        let wasReconnecting = shouldAutoReconnect
        shouldAutoReconnect = false

        isConnecting = true
        isConnected = false
        resetConnectionState()
        statusMessage = "正在连接 \(host):\(port)…"

        var ok = await webSocket.connect(host: host, port: port)
        var connectedPort = port

        // WNDR 控制 WebSocket 固定跑在 9000（发现报文里的 wndr-port 是音频输出端口）。
        // 兼容旧版本存下的 9200/9201 或用户手输的端口：失败后回退 9000 再试一次。
        if !ok, port != 9000 {
            statusMessage = "正在连接 \(host):9000…"
            ok = await webSocket.connect(host: host, port: 9000)
            connectedPort = 9000
        }
        isConnecting = false

        guard ok else {
            isConnected = false
            statusMessage = "连接失败: \(host):\(port)"
            if wasReconnecting {
                shouldAutoReconnect = true
                scheduleReconnect()
            }
            return
        }

        isConnected = true
        shouldAutoReconnect = true
        reconnectAttempt = 0
        statusMessage = "已连接: \(host):\(connectedPort)"
        if connectedPort != port {
            if let index = devices.firstIndex(where: { $0.ip == host }) {
                devices[index].port = connectedPort
            }
            if let device = selectedDevice {
                saveDevice(device)
            }
        }

        let device = DeviceInfo(hostname: name ?? host, ip: host, port: connectedPort)
        if let index = devices.firstIndex(where: { $0.ip == host }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        selectedDeviceID = device.id
        saveDevice(device)

        await sendAsync(Outbound.requestPlayStatus())
        try? await Task.sleep(nanoseconds: 200_000_000)
        await sendAsync(Outbound.requestPlayStatus())
    }

    func disconnect() {
        cancelReconnect()
        shouldAutoReconnect = false
        Task {
            await webSocket.disconnect()
            isConnected = false
            statusMessage = "已断开连接"
        }
    }

    #if DEBUG
    /// 仅用于验证断线重连：模拟设备把连接踢掉。
    func debugDropConnectionForTesting() {
        Task { await webSocket.disconnect() }
    }

    /// 仅用于验证设置写入：把指定菜单项临时改成另一个值，5 秒后改回。
    func debugCycleMenuValue(action: String) {
        debugSetMenuAction(action, value: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.debugSetMenuAction(action, value: 0)
        }
    }

    private func debugSetMenuAction(_ action: String, value: Int) {
        guard let group = menuGroups.first(where: { $0.items.contains { $0.action == action } }),
              let item = group.items.first(where: { $0.action == action }) else { return }
        setMenuValue(itemID: item.id, value: value)
    }
    #endif

    private func resetConnectionState() {
        availableSources = []
        availableSourceSet = []
        selectedSource = nil
        menuGroups = []
        isMenuVisible = false
        bitrate = "--"
        isDeviceStandby = false
        volumeMin = 0
        volumeMax = 100
        clearNowPlaying()
        fmChannel = 0
        fmFrequencyRaw = 0
        fmInfoTitle = ""
        fmPresetNames = [String](repeating: "", count: 16)
        updateFmFields()
    }

    private func handleConnectionChange(_ connected: Bool) {
        if !connected && isConnecting { return }
        isConnected = connected
        if connected {
            reconnectAttempt = 0
        } else {
            statusMessage = "WebSocket 连接已断开"
            menuGroups = []
            if shouldAutoReconnect {
                scheduleReconnect()
            }
        }
    }

    /// 设备只允许一个控制连接：手机 App 抢先连接、设备重启、Wi-Fi 抖动都会把连接踢掉。
    /// 这里用 2/4/8/16/30 秒的退避自动重连，直到用户手动断开或换设备。
    private func scheduleReconnect() {
        guard shouldAutoReconnect, !isConnecting, !isConnected,
              reconnectTask == nil, let device = selectedDevice else { return }

        let delay = min(30, 2 << min(reconnectAttempt, 4))
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard self.shouldAutoReconnect, !self.isConnected, !self.isConnecting else { return }
            await self.connect(host: device.ip, port: device.port, name: device.hostname)
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - 音量

    func userSetVolume(_ value: Double) {
        let clamped = min(max(value, volumeMin), volumeMax)
        if abs(volume - clamped) > 0.001 {
            volume = clamped
        }
        scheduleVolumeSend(clamped, delay: isUserAdjustingVolume ? volumeDragDebounceDelay : volumeDebounceDelay)
    }

    func volumeEditingChanged(_ editing: Bool) {
        if editing {
            isUserAdjustingVolume = true
            volumeDebounceTask?.cancel()
        } else {
            isUserAdjustingVolume = false
            scheduleVolumeSend(volume, delay: 0.02)
        }
    }

    func toggleMute() {
        isMuted.toggle()
        Task {
            lastSentVolume = Int(volume.rounded())
            lastSentAt = Date()
            suppressIncoming = true
            await sendAsync(Outbound.volume(Int(volume.rounded()), muted: isMuted))
            scheduleSuppressRelease()
        }
    }

    private func scheduleVolumeSend(_ value: Double, delay: TimeInterval) {
        volumeDebounceTask?.cancel()
        volumeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.sendVolume(value)
        }
    }

    private func sendVolume(_ value: Double) async {
        let intValue = Int(value.rounded())
        lastSentVolume = intValue
        lastSentAt = Date()
        suppressIncoming = true
        await sendAsync(Outbound.volume(intValue, muted: isMuted))
        scheduleSuppressRelease()
    }

    private func scheduleSuppressRelease() {
        suppressTask?.cancel()
        suppressTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(0.8 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.suppressIncoming = false
        }
    }

    // MARK: - 音源

    func setSource(_ source: String) {
        guard selectedSource != source else { return }
        selectedSource = source
        Task {
            suppressIncoming = true
            await sendAsync(Outbound.selectSource(source))
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.suppressIncoming = false
        }
    }

    // MARK: - 播放控制

    func togglePlayPause() {
        let desired = !isPlaying
        isPlaying = desired

        // 联动接管时命令发给播放器：它没有设备那种回显，靠 1s 轮询刷新真实状态。
        if isPlayerLinkPrimary {
            playerLink.setPlaying(desired)
            return
        }

        lastPlayToggleAt = Date()
        playTogglePending = true
        playToggleTask?.cancel()
        playToggleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.playConfirmTimeout ?? 3.0) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.playTogglePending = false
        }

        Task {
            await sendAsync(Outbound.button(desired ? "play" : "pause"))
        }
    }

    func nextTrack() {
        if isPlayerLinkPrimary {
            playerLink.next()
            return
        }
        Task { await sendAsync(Outbound.button("next")) }
    }

    func previousTrack() {
        if isPlayerLinkPrimary {
            playerLink.previous(position: playPosition)
            return
        }
        Task { await sendAsync(Outbound.button("prev")) }
    }

    func rediscoverPlayerLink() {
        setStatusThrottled("正在重新发现 No Glass Player…")
        playerLink.rediscover()
    }

    func standby() {
        Task {
            let ok = await sendAsync(Outbound.button("standby"))
            statusMessage = ok ? "已发送待机命令" : "发送待机命令失败"
        }
    }

    func powerOn() {
        Task {
            let ok = await sendAsync(Outbound.button("poweron"))
            statusMessage = ok ? "已发送开机命令" : "发送开机命令失败"
        }
    }

    // MARK: - FM

    func fmPresetUp() { sendButton("fm_presetup") }
    func fmPresetDown() { sendButton("fm_presetdown") }
    func fmFrequencyUp() { sendButton("fm_frequp") }
    func fmFrequencyDown() { sendButton("fm_freqdn") }

    private func sendButton(_ name: String) {
        Task { await sendAsync(Outbound.button(name)) }
    }

    func updateFmPresetName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, fmChannel >= 0, fmChannel < fmPresetNames.count else { return }

        let channel = fmChannel
        Task {
            let ok = await sendAsync(Outbound.fmPresetUpdate(id: channel, name: trimmed))
            guard ok, channel < self.fmPresetNames.count else { return }
            self.fmPresetNames[channel] = trimmed
            self.fmInfoTitle = trimmed
            self.updateFmFields()
        }
    }

    private func updateFmFields() {
        fmPresetNumber = max(1, fmChannel + 1)

        fmFrequency = fmFrequencyRaw > 0
            ? String(format: "%.1f", Double(fmFrequencyRaw) / 10.0)
            : "--.-"

        if fmChannel >= 0, fmChannel < fmPresetNames.count, !fmPresetNames[fmChannel].isEmpty {
            fmPresetTitle = fmPresetNames[fmChannel]
        } else if !fmInfoTitle.isEmpty {
            fmPresetTitle = fmInfoTitle
        } else {
            fmPresetTitle = "PRESET \(fmPresetNumber)"
        }
    }

    // MARK: - 设置菜单

    func openMenu() {
        isMenuVisible = true
        // 每次打开都拉一次，设备可能在别处（旋钮/遥控器/手机）被改过。
        Task { await sendAsync(Outbound.requestMenuList()) }
    }

    func closeMenu() {
        isMenuVisible = false
    }

    func setMenuValue(itemID: Int, value: Int) {
        guard let groupIndex = menuGroups.firstIndex(where: { group in
            group.items.contains { $0.id == itemID }
        }), let itemIndex = menuGroups[groupIndex].items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        var item = menuGroups[groupIndex].items[itemIndex]
        guard item.selectedValue != value else { return }
        let previous = item.selectedValue
        item.selectedValue = value
        menuGroups[groupIndex].items[itemIndex] = item

        Task {
            let ok = await sendAsync(Outbound.settings(
                id: item.id,
                handler: item.handler ?? 0,
                type: item.type ?? "",
                eepromAddr: item.eepromAddr ?? 0,
                value: value
            ))

            guard ok else {
                // 发送失败时回滚，避免界面显示一个设备并未接受的值。
                if let groupIndex = menuGroups.firstIndex(where: { $0.items.contains { $0.id == itemID } }),
                   let itemIndex = menuGroups[groupIndex].items.firstIndex(where: { $0.id == itemID }) {
                    menuGroups[groupIndex].items[itemIndex].selectedValue = previous
                }
                statusMessage = "设置发送失败"
                return
            }
            statusMessage = "正在应用设置…"
        }
    }

    // MARK: - 状态消息

    func setStatusThrottled(_ text: String) {
        pendingStatus = text
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            if let pending = self.pendingStatus {
                self.statusMessage = pending
                self.pendingStatus = nil
            }
        }
    }

    // MARK: - 发送与持久化

    @discardableResult
    private func sendAsync(_ text: String?) async -> Bool {
        guard let text else { return false }
        return await webSocket.send(text)
    }

    private func send(_ text: String?) {
        Task { _ = await sendAsync(text) }
    }

    private func loadSavedDevice() {
        let host = defaults.string(forKey: Self.lastHostKey) ?? ""
        guard !host.isEmpty else { return }
        let port = defaults.integer(forKey: Self.lastPortKey)
        var name = defaults.string(forKey: Self.lastNameKey) ?? host
        if name.isEmpty { name = host }
        let device = DeviceInfo(hostname: name, ip: host, port: port > 0 ? port : 9000)
        devices = [device]
        selectedDeviceID = device.id
    }

    private func saveDevice(_ device: DeviceInfo) {
        defaults.set(device.ip, forKey: Self.lastHostKey)
        defaults.set(device.port, forKey: Self.lastPortKey)
        defaults.set(device.hostname, forKey: Self.lastNameKey)
    }

    // MARK: - 封面

    /// 与 Windows 版 GetAlbumArtDecodeEdge() 一致：按显示尺寸 × 屏幕缩放 × 冗余系数解码，
    /// 高 DPI 下不会因为按 1x 尺寸解码而发糊，1x 下也不会白白解码大图。
    private static let albumArtDisplaySize: CGFloat = 168
    private static let albumArtDecodeMargin: CGFloat = 2.0

    private var albumArtDecodeEdge: Int {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let edge = Int((Self.albumArtDisplaySize * scale * Self.albumArtDecodeMargin).rounded(.up))
        return min(max(edge, Int(Self.albumArtDisplaySize)), 720)
    }

    /// No Glass Player 的封面接口支持 `w` 参数，按解码尺寸取图，避免拿整张大图再缩小。
    private static func coverURI(_ uri: String, width: Int) -> String {
        guard var components = URLComponents(string: uri),
              components.path.hasSuffix("/cover") else {
            return uri
        }

        var items = components.queryItems ?? []
        items.removeAll { $0.name == "w" }
        items.append(URLQueryItem(name: "w", value: String(width)))
        components.queryItems = items
        return components.url?.absoluteString ?? uri
    }

    private func applyAlbumArt(_ uri: String?) {
        if currentAlbumArtURI == uri { return }
        currentAlbumArtURI = uri
        albumArtTask?.cancel()

        guard let uri, !uri.isEmpty else {
            albumArt = nil
            return
        }

        let edge = albumArtDecodeEdge
        let requestURI = Self.coverURI(uri, width: edge)

        albumArtTask = Task { [weak self] in
            let image = await AlbumArtLoader.load(urlString: requestURI, maxPixel: edge)
            guard !Task.isCancelled, let self else { return }
            guard self.currentAlbumArtURI == uri else { return }
            self.albumArt = image
        }
    }

    private func clearNowPlaying() {
        isNowPlayingVisible = false
        nowPlayingTitle = ""
        nowPlayingArtist = ""
        nowPlayingAlbum = ""
        isPlaying = false
        playPosition = 0
        playLength = 0
        applyAlbumArt(nil)
    }

    // MARK: - 播放器联动

    /// 设备音源为 USB / WNDR 时，设备端没有曲目元数据，改由 No Glass Player 提供。
    private func shouldUsePlayerLink(source: String?) -> Bool {
        guard isPlayerLinked else { return false }
        let value = (source ?? selectedSource ?? "").lowercased()
        guard !value.isEmpty else { return false }
        return value.contains("usb") || value.contains("wndr")
    }

    private func handlePlayerLinkConnection(_ connected: Bool, name: String?) {
        isPlayerLinked = connected
        playerLinkName = connected ? (name ?? "No Glass Player") : nil

        // 播放器握手可能晚于最后一次音源变化到达，这里按当前音源重算一次接管标志。
        let primary = shouldUsePlayerLink(source: selectedSource)
        if primary != isPlayerLinkPrimary {
            isPlayerLinkPrimary = primary
            if primary {
                applyPlayerNowPlaying()
            } else {
                clearNowPlaying()
            }
        }

        if connected {
            setStatusThrottled("已联动 \(playerLinkName ?? "No Glass Player")")
        } else if isConnected {
            setStatusThrottled("播放器联动已断开")
        }
    }

    private func handlePlayerSnapshot(_ snapshot: PlayerLinkSnapshot?) {
        latestPlayerSnapshot = snapshot
        if isPlayerLinkPrimary {
            applyPlayerNowPlaying()
        }
    }

    private func applyPlayerNowPlaying() {
        guard let snapshot = latestPlayerSnapshot,
              !snapshot.title.isEmpty else {
            clearNowPlaying()
            return
        }

        if nowPlayingTitle != snapshot.title { nowPlayingTitle = snapshot.title }
        if nowPlayingArtist != snapshot.artist { nowPlayingArtist = snapshot.artist }
        if nowPlayingAlbum != snapshot.album { nowPlayingAlbum = snapshot.album }
        if !isNowPlayingVisible { isNowPlayingVisible = true }
        if isPlaying != snapshot.isPlaying { isPlaying = snapshot.isPlaying }
        if playPosition != snapshot.position { playPosition = snapshot.position }
        if playLength != snapshot.duration { playLength = snapshot.duration }
        applyAlbumArt(snapshot.coverURL?.absoluteString)
    }
}

// MARK: - 入站消息处理

extension MainViewModel {
    func handleMessage(_ text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else {
            setStatusThrottled("收到空消息")
            return
        }

        let decoder = JSONDecoder()
        if let header = try? decoder.decode(MessageHeader.self, from: data) {
            if header.cmd_id == 32779 {
                applyPresetList(data, decoder: decoder)
                return
            }

            switch (header.cmd ?? "").lowercased() {
            case "playstatus":
                if let message = try? decoder.decode(PlayStatusMessage.self, from: data),
                   let payload = message.payload {
                    applyPlayStatus(payload)
                    return
                }
            case "menulist":
                if let message = try? decoder.decode(MenuListMessage.self, from: data),
                   let sections = message.payload {
                    applyMenuList(sections)
                    return
                }
            case "serverinfo", "wplayer", "":
                // 设备会周期性推送 serverinfo / wplayerv2，与面板状态无关，
                // 不要占用底部的音源/音量状态栏。
                return
            default:
                return
            }
        }
    }

    private func applyPlayStatus(_ payload: PlayStatusPayload) {
        applyingDeviceState = true
        defer { applyingDeviceState = false }

        updateSources(commaList: payload.source_list, deviceSource: payload.source)
        updateFmState(payload)

        if let minimum = payload.volume_min {
            volumeMin = Double(minimum)
        }
        if let maximum = payload.volume_max {
            volumeMax = Double(maximum)
        }

        bitrate = (payload.speed_str ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "--"
            : (payload.speed_str ?? "--")

        var shouldApplyVolume = !isUserAdjustingVolume
        if shouldApplyVolume, let lastSentVolume,
           Date().timeIntervalSince(lastSentAt) < volumeSuppressWindow,
           let incomingVolume = payload.volume,
           incomingVolume != lastSentVolume {
            shouldApplyVolume = false
        }
        if shouldApplyVolume, let incomingVolume = payload.volume {
            volume = min(max(Double(incomingVolume), volumeMin), volumeMax)
        }

        if let mute = payload.mute {
            isMuted = mute != 0
        }

        if let deviceStatus = payload.device_status {
            isDeviceStandby = deviceStatus.caseInsensitiveCompare("standby") == .orderedSame
        }

        let details = payload.playstatus
        let source = payload.source ?? ""
        let hasPlayInfo = !(details?.title ?? "").isEmpty
            || !(details?.artist ?? "").isEmpty
            || (details?.play_length ?? 0) > 0
        let isRoon = source.range(of: "roon", options: .caseInsensitive) != nil

        // USB / WNDR 只收到音频流、playstatus 里没有曲目信息：播放器在线时由它接管
        // Now Playing 和传输控制（Roon 仍走设备原有逻辑）。
        let shouldTakeOver = shouldUsePlayerLink(source: source) && !isRoon
        if shouldTakeOver != isPlayerLinkPrimary {
            isPlayerLinkPrimary = shouldTakeOver
        }

        // Roon Ready 空闲时 playstatus 里没有曲目信息，此时不能只凭音源名就显示播放栏，
        // 否则会留一块空白卡片和无效的传输控制。
        if isPlayerLinkPrimary {
            applyPlayerNowPlaying()
        } else if hasPlayInfo {
            nowPlayingTitle = details?.title ?? ""
            nowPlayingArtist = details?.artist ?? ""
            nowPlayingAlbum = details?.album ?? ""
            applyAlbumArt(details?.albumart_uri)
            isNowPlayingVisible = true

            let incomingPlaying = (details?.status ?? "").caseInsensitiveCompare("playing") == .orderedSame
            if playTogglePending {
                // 本地切换尚未确认，忽略设备旧状态，避免图标来回跳。
            } else if Date().timeIntervalSince(lastPlayToggleAt) > playSuppressWindow {
                isPlaying = incomingPlaying
            } else if incomingPlaying == isPlaying {
                lastPlayToggleAt = .distantPast
            }

            playPosition = details?.play_pos ?? 0
            playLength = details?.play_length ?? 0
        } else {
            clearNowPlaying()
        }

        let muteText = isMuted ? " · 静音" : ""
        let linkText = isPlayerLinkPrimary ? " · 联动播放器" : ""
        setStatusThrottled("音源 \(source.isEmpty ? "--" : source) · 音量 \(Int(volume.rounded()))\(muteText)\(linkText)")
    }

    private func updateSources(commaList: String?, deviceSource: String?) {
        guard let commaList else { return }

        let sources = commaList
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sources != availableSources {
            availableSources = sources
            availableSourceSet = Set(sources)
        }

        if let deviceSource, !deviceSource.isEmpty, availableSourceSet.contains(deviceSource) {
            selectedSource = deviceSource
        } else if (selectedSource ?? "").isEmpty, let first = availableSources.first {
            selectedSource = first
        }
    }

    private func updateFmState(_ payload: PlayStatusPayload) {
        let channel = payload.playstatus?.fm_channel ?? 0
        let frequency = payload.playstatus?.fm_freq ?? 0
        let infoTitle = payload.si_info_title ?? ""

        var changed = false
        if fmChannel != channel {
            fmChannel = channel
            changed = true
        }
        if fmFrequencyRaw != frequency {
            fmFrequencyRaw = frequency
            changed = true
        }
        if fmInfoTitle != infoTitle {
            fmInfoTitle = infoTitle
            changed = true
        }
        if changed {
            updateFmFields()
        }
    }

    private func applyPresetList(_ data: Data, decoder: JSONDecoder) {
        guard let message = try? decoder.decode(PresetListMessage.self, from: data),
              let presets = message.payload?.preset_list else { return }

        var names = [String](repeating: "", count: 16)
        for (index, name) in presets.enumerated() where index < names.count {
            names[index] = name
        }
        fmPresetNames = names
        updateFmFields()
    }

    private func applyMenuList(_ sections: [MenuSection]) {
        let visibleSections = sections.filter { !($0.content ?? []).isEmpty }

        if !updateMenuGroupsInPlace(visibleSections) {
            menuGroups = visibleSections.map(MenuGroup.init(section:))
        }

        if isMenuVisible && menuGroups.isEmpty {
            isMenuVisible = false
        }
    }

    private func updateMenuGroupsInPlace(_ sections: [MenuSection]) -> Bool {
        guard sections.count == menuGroups.count, !menuGroups.isEmpty else { return false }

        for (groupIndex, section) in sections.enumerated() {
            guard section.head == menuGroups[groupIndex].head else { return false }
            let items = (section.content ?? []).filter { !($0.hidden ?? false) }
            let current = menuGroups[groupIndex].items
            guard items.count == current.count else { return false }
            for (itemIndex, item) in items.enumerated() where item.id != current[itemIndex].id {
                return false
            }
        }

        for (groupIndex, section) in sections.enumerated() {
            let items = (section.content ?? []).filter { !($0.hidden ?? false) }
            var group = menuGroups[groupIndex]
            for (itemIndex, item) in items.enumerated() {
                group.items[itemIndex].selectedValue = item.value ?? 0
            }
            menuGroups[groupIndex] = group
        }
        return true
    }
}
