import Foundation

/// No Glass Player 的播放器快照，用于 USB/WNDR 这类“只有声音没有元数据”的音源。
struct PlayerLinkSnapshot: Equatable {
    let filePath: String
    let title: String
    let artist: String
    let album: String
    let position: Int
    let duration: Int
    let isPlaying: Bool
    let canControl: Bool
    let canNext: Bool
    let canPrevious: Bool
    let albumID: Int64
    let coverURL: URL?
}

/// 通过局域网直连 No Glass Player 的 WebHost。
///
/// Windows 端没有 WebHost，走的是命名管道 HTTP：`/health` 握手后用 `/api/playback/watch`
/// 做长轮询。macOS 这条链路的等价物是 WebHost 的 `WS /ws`（网页端用的就是它）：
/// 连上后服务端主动推 `state`（放歌时每秒一条）与 `queueChanged`，没变化就完全不发包，
/// 等同于 Windows 那条"没变化回 204"的长轮询，但省掉每次重挂的请求开销。
/// 推送静默超过 4 秒（暂停/停止后服务端只在变化时发包，或休眠唤醒后连接假死）才用 `api/state` 兜底。
@MainActor
final class PlayerLinkService {
    var onConnectionChange: ((Bool, String?) -> Void)?
    var onSnapshot: ((PlayerLinkSnapshot?) -> Void)?

    private(set) var isConnected = false
    private(set) var nodeName: String?

    /// REST 用（`api/state`、`api/player/queue`、控制指令）。
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// 推送通道单独一套：`timeoutIntervalForResource` 限制的是整条连接的总时长，
    /// 复用 REST 那套 10 秒会把 WebSocket 定期掐断，所以这里保留默认值。
    private let streamSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private var loopTask: Task<Void, Never>?
    private var baseURL: URL?
    private var latestSnapshot: PlayerLinkSnapshot?
    /// 当前推送连接：`stop()` 里要主动掐断，否则 `receive` 会一直挂在旧连接上。
    private var activeSocket: URLSessionWebSocketTask?

    // 推送驱动的当前值。队列只在换曲时拉，和原来的缓存策略一致。
    private var currentState: PlaybackStateResponse?
    private var currentQueue: QueueResponse?
    private var queueIdentity: String?
    private var lastEventAt = Date.distantPast
    private var pushCount = 0

    /// 推送静默多久走一次 REST 兜底：暂停/停止后服务端不再按秒推，必须靠它对齐。
    private static let silentTimeout: TimeInterval = 4
    private static let watchdogInterval: UInt64 = 1_000_000_000
    private static let discoveryInterval: TimeInterval = 5
    /// 同一节点连续失败多少次才放弃、回到"重新发现"（对端 IP 可能已经变了）。
    private static let maxStreamRetries = 3

    // MARK: - 生命周期

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        // URLSession 的 `receive` 不会因为 Task 取消而返回，必须显式掐掉连接。
        activeSocket?.cancel(with: .goingAway, reason: nil)
        activeSocket = nil
        markDisconnected()
    }

    func rediscover() {
        stop()
        start()
    }

    // MARK: - 主循环

    private func run() async {
        var backoff: TimeInterval = 1

        while !Task.isCancelled {
            let nodes: [DiscoveredPlayerNode]
            if let fixed = Self.configuredBaseURL {
                nodes = [DiscoveredPlayerNode(urlString: fixed, name: "No Glass Player", nodeID: fixed)]
            } else {
                nodes = await PlayerDiscovery.discover(timeout: 0.9)
            }

            guard !nodes.isEmpty else {
                markDisconnected()
                try? await Task.sleep(nanoseconds: UInt64(Self.discoveryInterval * 1_000_000_000))
                continue
            }

            var attached = false
            for node in nodes {
                do {
                    try await attachAndStream(node)
                    attached = true
                    backoff = 1
                    break
                } catch {
                    // 同一网段可能有多个节点（或旧版本不兼容），逐个尝试。
                    continue
                }
            }

            // 已被 stop()/新的 rediscover 取代的这一轮不要再动状态，否则会把新连接的界面抹掉。
            guard !Task.isCancelled else { break }
            if !attached { markDisconnected() }

            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 8)
        }
    }

    private func attachAndStream(_ node: DiscoveredPlayerNode) async throws {
        guard let base = URL(string: node.urlString), base.scheme != nil else {
            throw PlayerLinkError.badURL
        }

        let health: HealthResponse = try await get(base, "api/health")
        guard health.ok else {
            throw PlayerLinkError.notReady(health.errorMessage ?? health.errorCode ?? L("WebHost 未就绪", "WebHost not ready"))
        }
        guard health.authRequired != true else {
            throw PlayerLinkError.notReady(L("该节点需要鉴权", "This node requires authentication"))
        }
        guard Self.webSocketURL(base) != nil else {
            throw PlayerLinkError.badURL
        }
        // 握手期间已经被 stop() 取代：不要再覆盖新一轮连接的状态。
        try Task.checkCancellation()

        baseURL = base
        nodeName = health.nodeName ?? node.displayName
        currentState = nil
        currentQueue = nil
        queueIdentity = nil
        lastEventAt = .distantPast
        latestSnapshot = nil

        setConnected(true, name: nodeName)
        onSnapshot?(nil)

        // 先取一份 REST 快照：推送要等连接建立才有，界面不必空等这一拍。
        try await refreshFromREST(base)

        try await stream(base)
    }

    // MARK: - 推送通道

    /// 维持一条 `/ws` 连接，把服务端的 `state` / `queueChanged` 落到快照上。
    /// 断线先在同一个节点上重连几次，仍不成功才抛给上层重新发现。
    private func stream(_ base: URL) async throws {
        guard let url = Self.webSocketURL(base) else { throw PlayerLinkError.badURL }

        var failures = 0

        while !Task.isCancelled {
            let task = streamSession.webSocketTask(with: url)
            task.resume()
            activeSocket = task

            let before = pushCount

            // 静默兜底与接收循环并行：服务端暂停后不再按秒推，得有人去 REST 对齐。
            let watchdog = Task { [weak self] in
                await self?.watchSilence(base, task: task)
            }

            do {
                try await receiveLoop(task)
            } catch {
                // 对端关闭、网络中断、取消都走这里，统一按断线处理。
            }

            watchdog.cancel()
            task.cancel(with: .goingAway, reason: nil)
            if activeSocket === task { activeSocket = nil }

            guard !Task.isCancelled else { return }

            // 断线前还在收推送，说明连接本身是好的（对端重启之类），失败计数从 0 重来。
            if pushCount != before { failures = 0 }
            failures += 1
            guard failures <= Self.maxStreamRetries else { throw PlayerLinkError.disconnected }

            try? await Task.sleep(nanoseconds: UInt64(1 << (failures - 1)) * 250_000_000)
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw PlayerLinkError.disconnected
            }

            switch message {
            case .string(let text): handlePush(Data(text.utf8))
            case .data(let data): handlePush(data)
            @unknown default: break
            }
        }
    }

    /// 解析一条推送。协议与网页端一致：`{type, ...}`，`state` / `queueChanged` 的载荷
    /// 就是 REST 那两份 JSON 的同一份，所以解码结构可以直接复用。
    private func handlePush(_ data: Data) {
        struct TypeOnly: Decodable { let type: String? }
        guard let header = try? JSONDecoder().decode(TypeOnly.self, from: data),
              let type = header.type else { return }

        lastEventAt = Date()
        pushCount &+= 1

        switch type {
        case "state":
            guard let push = try? JSONDecoder().decode(StatePush.self, from: data) else { return }
            currentState = push.state
            publish()
            refreshQueueIfNeeded()

        case "queueChanged":
            guard let push = try? JSONDecoder().decode(QueuePush.self, from: data) else { return }
            currentQueue = push.queue
            queueIdentity = Self.identity(currentState)
            publish()

        case "queueDisconnected":
            currentQueue = nil
            queueIdentity = nil
            publish()
            refreshQueueIfNeeded()

        case "hostExited", "hostLifecycle":
            // 宿主退出/重启时位置与队列的权威值都作废：先按停止收起，再拉一次真实状态。
            let push = try? JSONDecoder().decode(LifecyclePush.self, from: data)
            if type == "hostExited" || push?.state == "down" {
                currentState?.status = "stopped"
                currentState?.positionMs = 0
                publish()
            }
            if push?.state == "up", push?.restarted == true {
                refreshFromRESTInBackground()
            }

        default:
            break
        }
    }

    /// 换曲才拉队列：位置每秒都在变，队列只在会话/专辑/曲目变化时才有意义。
    private func refreshQueueIfNeeded() {
        guard let base = baseURL else { return }
        let identity = Self.identity(currentState)
        guard identity != queueIdentity else { return }
        Task { [weak self] in
            await self?.loadQueue(base, identity: identity)
        }
    }

    private func loadQueue(_ base: URL, identity: String) async {
        guard let queue: QueueResponse = try? await get(base, "api/player/queue") else { return }
        // 拉取期间已经换曲：这份队列过期了，丢掉等下一次。
        guard Self.identity(currentState) == identity else { return }
        currentQueue = queue
        queueIdentity = identity
        publish()
    }

    /// 推送静默的兜底：暂停/停止后服务端只在变化时发包，休眠唤醒后连接也可能假死。
    /// 静默超过 4 秒用一次 `api/state` 对齐；REST 也取不到就掐断连接让接收循环去重连。
    private func watchSilence(_ base: URL, task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.watchdogInterval)
            guard !Task.isCancelled else { return }
            guard Date().timeIntervalSince(lastEventAt) >= Self.silentTimeout else { continue }

            guard let state: PlaybackStateResponse = try? await get(base, "api/state") else {
                task.cancel(with: .goingAway, reason: nil)
                return
            }

            currentState = state
            lastEventAt = Date()
            publish()
            refreshQueueIfNeeded()
        }
    }

    /// 一次性 REST 快照（刚连上、宿主重启后）。
    private func refreshFromREST(_ base: URL) async throws {
        let state: PlaybackStateResponse = try await get(base, "api/state")
        currentState = state
        lastEventAt = Date()
        if let queue: QueueResponse = try? await get(base, "api/player/queue") {
            currentQueue = queue
            queueIdentity = Self.identity(state)
        }
        publish()
    }

    private func refreshFromRESTInBackground() {
        guard let base = baseURL else { return }
        Task { [weak self] in
            try? await self?.refreshFromREST(base)
        }
    }

    private func publish() {
        guard let state = currentState, let base = baseURL else { return }
        let snapshot = makeSnapshot(state: state, queue: currentQueue, base: base)
        guard snapshot != latestSnapshot else { return }
        latestSnapshot = snapshot
        onSnapshot?(snapshot)
    }

    private func makeSnapshot(state: PlaybackStateResponse, queue: QueueResponse?, base: URL) -> PlayerLinkSnapshot? {
        let filePath = state.filePath ?? ""
        let currentItem = queue?.items?.first(where: { $0.isCurrent == true })
            ?? queue?.items?.first(where: { ($0.filePath ?? "") == filePath })

        let hasTrack = !filePath.isEmpty || currentItem != nil
        guard hasTrack else { return nil }

        let fallbackTitle = (filePath as NSString).lastPathComponent
        let title = Self.nonEmpty(currentItem?.title) ?? Self.nonEmpty(fallbackTitle) ?? ""
        guard !title.isEmpty else { return nil }

        let albumID = state.albumId ?? -1
        var coverURL: URL?
        if albumID > 0 {
            // `w` 由 MainViewModel 按屏幕缩放补上（168pt × scale × 2），这里不写死像素宽度。
            coverURL = URL(string: "\(Self.trimmedBase(base.absoluteString))/api/albums/\(albumID)/cover?sharpen=1")
        }

        return PlayerLinkSnapshot(
            filePath: filePath,
            title: title,
            artist: currentItem?.artistName ?? "",
            album: currentItem?.albumName ?? "",
            position: Int(((state.positionMs ?? 0) / 1000).rounded(.down)),
            duration: Int(((state.durationMs ?? 0) / 1000).rounded()),
            isPlaying: (state.status ?? "").caseInsensitiveCompare("playing") == .orderedSame,
            canControl: state.canControl ?? false,
            canNext: queue?.canNext ?? true,
            canPrevious: queue?.canPrevious ?? true,
            albumID: albumID,
            coverURL: coverURL
        )
    }

    // MARK: - 播放控制

    func setPlaying(_ playing: Bool) {
        post(playing ? "api/player/resume" : "api/player/pause")
    }

    func next() {
        guard latestSnapshot?.canNext ?? true else { return }
        post("api/player/next")
    }

    /// 与播放器自身的“上一首”约定一致：播放超过 3 秒先回到本曲开头。
    func previous(position: Int) {
        if position > 3 {
            seek(toMilliseconds: 0)
            return
        }
        guard latestSnapshot?.canPrevious ?? true else { return }
        post("api/player/previous")
    }

    func seek(toMilliseconds milliseconds: Int) {
        post("api/player/seek", body: ["positionMs": milliseconds])
    }

    private func post(_ path: String, body: [String: Int]? = nil) {
        guard let baseURL else { return }
        Task {
            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.timeoutInterval = 6
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            _ = try? await session.data(for: request)
        }
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ base: URL, _ path: String) async throws -> T {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlayerLinkError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PlayerLinkError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PlayerLinkError.badPayload
        }
    }

    // MARK: - 状态

    private func setConnected(_ connected: Bool, name: String?) {
        isConnected = connected
        nodeName = name
        onConnectionChange?(connected, name)
    }

    private func markDisconnected() {
        baseURL = nil
        currentState = nil
        currentQueue = nil
        queueIdentity = nil
        lastEventAt = .distantPast
        latestSnapshot = nil
        if isConnected || nodeName != nil {
            setConnected(false, name: nil)
        }
        onSnapshot?(nil)
    }

    /// 队列是否还有意义的判定键：换会话、换专辑、换曲都会变，位置变化不算。
    private static func identity(_ state: PlaybackStateResponse?) -> String {
        guard let state else { return "" }
        return "\(state.playbackSessionId ?? 0)|\(state.albumId ?? -1)|\(state.filePath ?? "")"
    }

    /// 把 WebHost 的 `http(s)://host:port[/]` 换成 `ws(s)://host:port/ws`。
    private static func webSocketURL(_ base: URL) -> URL? {
        // 先按路径拼好再换协议：`URLComponents.path` 直接写相对形式会拼出非法 URL。
        guard var components = URLComponents(
            url: base.appendingPathComponent("ws"),
            resolvingAgainstBaseURL: false
        ) else { return nil }

        switch components.scheme?.lowercased() {
        case "https", "wss": components.scheme = "wss"
        default: components.scheme = "ws"
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimmedBase(_ value: String) -> String {
        value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    /// 调试/固定地址入口：UserDefaults `ngpBaseURL` 或环境变量 `NGP_BASE_URL`。
    private static var configuredBaseURL: String? {
        if let value = ProcessInfo.processInfo.environment["NGP_BASE_URL"], !value.isEmpty {
            return value
        }
        if let value = UserDefaults.standard.string(forKey: "ngpBaseURL"), !value.isEmpty {
            return value
        }
        return nil
    }
}

// MARK: - 契约

private struct HealthResponse: Decodable {
    let ok: Bool
    let nodeId: String?
    let nodeName: String?
    let apiVersion: String?
    let coreHostReady: Bool?
    let authRequired: Bool?
    let errorCode: String?
    let errorMessage: String?
}

private struct PlaybackStateResponse: Decodable {
    // status / positionMs 会被 `hostExited` 推送就地改成停止态，其余字段只读。
    var status: String?
    var positionMs: Double?
    let filePath: String?
    let durationMs: Double?
    let playbackSessionId: Int64?
    let albumId: Int64?
    let canControl: Bool?
}

private struct QueueItemResponse: Decodable {
    let title: String?
    let artistName: String?
    let albumName: String?
    let filePath: String?
    let isCurrent: Bool?
}

private struct QueueResponse: Decodable {
    let items: [QueueItemResponse]?
    let canNext: Bool?
    let canPrevious: Bool?
}

// MARK: - 推送载荷（`/ws` 的 `{type, ...}` 消息）

private struct StatePush: Decodable {
    let state: PlaybackStateResponse
}

private struct QueuePush: Decodable {
    let queue: QueueResponse
}

private struct LifecyclePush: Decodable {
    /// `hostLifecycle` 用 "up"/"down"；`hostExited` 没有这个字段，靠 type 区分。
    let state: String?
    let restarted: Bool?
}

private enum PlayerLinkError: LocalizedError {
    case badURL
    case badResponse
    case badPayload
    case http(Int)
    case notReady(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .badURL: return L("播放器地址无效", "Invalid player URL")
        case .badResponse: return L("播放器响应异常", "Unexpected player response")
        case .badPayload: return L("播放器数据格式不兼容", "Unsupported player data format")
        case .http(let code): return LF("播放器返回 HTTP %ld", "Player returned HTTP %ld", code)
        case .notReady(let reason): return reason
        case .disconnected: return L("播放器连接已断开", "Player connection lost")
        }
    }
}

// MARK: - 局域网发现

struct DiscoveredPlayerNode {
    let urlString: String
    let name: String
    let nodeID: String
    var displayName: String { name }
}

private struct DiscoveryPacket: Decodable {
    let url: String?
    let name: String?
    let nodeId: String?
    let nodeName: String?
}

private enum PlayerDiscovery {
    static let port: UInt16 = 5218
    static let probeToken = "NGP_WEB_DISCOVER_V1"

    static func discover(timeout: TimeInterval = 0.9) async -> [DiscoveredPlayerNode] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(timeout: timeout))
            }
        }
    }

    private static func run(timeout: TimeInterval) -> [DiscoveredPlayerNode] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var broadcastOn: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcastOn, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: 0, tv_usec: 150_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr.s_addr = INADDR_BROADCAST

        let payload = Array(probeToken.utf8)
        let sent = payload.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(fd, raw.baseAddress, payload.count, 0, address,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == payload.count else { return [] }

        var results: [String: DiscoveredPlayerNode] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let decoder = JSONDecoder()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        recvfrom(fd, raw.baseAddress, raw.count, 0, address, &fromLength)
                    }
                }
            }

            if received <= 0 {
                usleep(10_000)
                continue
            }

            let data = Data(buffer[0..<received])
            guard let packet = try? decoder.decode(DiscoveryPacket.self, from: data),
                  let url = packet.url, !url.isEmpty else {
                continue
            }

            let key = packet.nodeId ?? url
            results[key] = DiscoveredPlayerNode(
                urlString: url,
                name: packet.nodeName ?? packet.name ?? url,
                nodeID: key
            )
        }

        return Array(results.values)
    }
}
