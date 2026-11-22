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

/// 通过局域网 HTTP 直连 No Glass Player 的 WebHost。
///
/// Windows 端的 PlayerLink 走的是命名管道上的 HTTP；macOS 没有对应管道，
/// 这里改为直接访问 WebHost 的 HTTP 接口（与 NoGlassPlayerSwift 的做法一致）：
/// 先用 `NGP_WEB_DISCOVER_V1` 广播发现节点，再轮询 `api/state` + `api/player/queue`。
@MainActor
final class PlayerLinkService {
    var onConnectionChange: ((Bool, String?) -> Void)?
    var onSnapshot: ((PlayerLinkSnapshot?) -> Void)?

    private(set) var isConnected = false
    private(set) var nodeName: String?

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private var loopTask: Task<Void, Never>?
    private var baseURL: URL?
    private var latestSnapshot: PlayerLinkSnapshot?

    private static let pollInterval: UInt64 = 1_000_000_000
    private static let discoveryInterval: TimeInterval = 5

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
                    try await attachAndPoll(node)
                    attached = true
                    backoff = 1
                    break
                } catch {
                    // 同一网段可能有多个节点（或旧版本不兼容），逐个尝试。
                    continue
                }
            }

            if !attached { markDisconnected() }

            guard !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 8)
        }
    }

    private func attachAndPoll(_ node: DiscoveredPlayerNode) async throws {
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

        baseURL = base
        setConnected(true, name: health.nodeName ?? node.displayName)
        latestSnapshot = nil
        onSnapshot?(nil)

        var queue: QueueResponse?
        var queueKey: String?

        while !Task.isCancelled {
            let state: PlaybackStateResponse
            do {
                state = try await get(base, "api/state")
            } catch {
                // 单次抖动先重试一次，仍失败才判定掉线，避免播放器瞬间忙时闪烁。
                try await Task.sleep(nanoseconds: 400_000_000)
                state = try await get(base, "api/state")
            }

            let identity = "\(state.playbackSessionId ?? 0)|\(state.albumId ?? -1)|\(state.filePath ?? "")"
            if identity != queueKey {
                queue = try? await get(base, "api/player/queue")
                queueKey = identity
            }

            let snapshot = makeSnapshot(state: state, queue: queue, base: base)
            if snapshot != latestSnapshot {
                latestSnapshot = snapshot
                onSnapshot?(snapshot)
            }

            try await Task.sleep(nanoseconds: Self.pollInterval)
        }
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
        latestSnapshot = nil
        if isConnected || nodeName != nil {
            setConnected(false, name: nil)
        }
        onSnapshot?(nil)
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
    let status: String?
    let filePath: String?
    let positionMs: Double?
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

private enum PlayerLinkError: LocalizedError {
    case badURL
    case badResponse
    case badPayload
    case http(Int)
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return L("播放器地址无效", "Invalid player URL")
        case .badResponse: return L("播放器响应异常", "Unexpected player response")
        case .badPayload: return L("播放器数据格式不兼容", "Unsupported player data format")
        case .http(let code): return LF("播放器返回 HTTP %ld", "Player returned HTTP %ld", code)
        case .notReady(let reason): return reason
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
