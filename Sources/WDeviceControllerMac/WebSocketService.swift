import Foundation

/// 与设备通讯的 WebSocket 客户端。
///
/// 与原 WinUI 版本一致：
/// - 连接超时 10s
/// - 子协议 wremote-protocol / json
/// - 收到的所有文本消息按顺序回调
/// - 发送由 actor 串行化，避免并发写同一 socket
actor WebSocketService {
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var generation = 0
    private var lastInboundAt = Date.distantPast
    /// 本次连接里观察到的最长入站间隔，用来自适应判定“多久没消息才算死”。
    private var maxInboundGap: TimeInterval = 0

    private let onState: @Sendable (Bool) -> Void
    private let onMessage: @Sendable (String) -> Void

    private static let connectTimeout: TimeInterval = 10
    /// 看门狗轮询间隔。
    private static let heartbeatTick: TimeInterval = 5
    /// 静默超过这个时长才发探针；设备本来就在推送时不发，避免多余报文。
    private static let probeSilence: TimeInterval = 10
    /// 假死判定下限。设备即使不认 play_status_req，也很难 90 秒连一条 serverinfo 推送都没有。
    private static let minInboundTimeout: TimeInterval = 90
    private static let maxInboundTimeout: TimeInterval = 300

    init(onState: @escaping @Sendable (Bool) -> Void,
         onMessage: @escaping @Sendable (String) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.onState = onState
        self.onMessage = onMessage
    }

    var isConnected: Bool { socket != nil }

    @discardableResult
    func connect(host: String, port: Int) async -> Bool {
        await close(notify: false)

        guard let url = URL(string: "ws://\(host):\(port)") else {
            onState(false)
            return false
        }

        generation += 1
        let currentGeneration = generation

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.connectTimeout
        request.setValue("wremote-protocol, json", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()

        // URLSessionWebSocketTask 没有“握手完成”回调。这里发一帧真实请求来确认连接：
        // 握手失败时 send 会抛错；同时用可取消的计时器兜底，避免死等。
        let attempt = ConnectionAttempt()
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
            guard !Task.isCancelled, attempt.finish() else { return }
            task.cancel(with: .goingAway, reason: nil)
        }

        do {
            try await task.send(.string(Outbound.requestPlayStatus() ?? "{}"))
        } catch {
            timeoutTask.cancel()
            // 已经被新的 connect()/close() 取代时不要再发状态，否则会把新连接标成断线。
            if currentGeneration == generation {
                task.cancel(with: .goingAway, reason: nil)
                socket = nil
                generation += 1
                onState(false)
            }
            return false
        }
        timeoutTask.cancel()

        guard attempt.finish(), currentGeneration == generation else {
            if currentGeneration == generation {
                task.cancel(with: .goingAway, reason: nil)
                socket = nil
                generation += 1
                onState(false)
            }
            return false
        }

        lastInboundAt = Date()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task, generation: currentGeneration)
        }
        startHeartbeat(task, generation: currentGeneration)
        onState(true)
        return true
    }

    @discardableResult
    func send(_ text: String) async -> Bool {
        guard let task = socket else { return false }
        let currentGeneration = generation
        do {
            try await task.send(.string(text))
            return true
        } catch {
            // 发送失败说明链路已经不可用，但 URLSession 的 receive() 常常不会主动报错，
            // 这里必须立刻按断线处理，否则界面会一直显示“已连接”而所有操作都发不出去。
            if currentGeneration == generation {
                handleUnexpectedDisconnect(currentGeneration)
            }
            return false
        }
    }

    func disconnect() async {
        await close(notify: true)
    }

    private func close(notify: Bool) async {
        generation += 1
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let task = socket
        socket = nil

        if let task {
            task.cancel(with: .normalClosure, reason: nil)
        }

        if notify {
            onState(false)
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, generation loopGeneration: Int) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard loopGeneration == generation else { return }
                let now = Date()
                maxInboundGap = max(maxInboundGap, now.timeIntervalSince(lastInboundAt))
                lastInboundAt = now

                switch message {
                case .string(let text):
                    onMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        onMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                guard loopGeneration == generation else { return }
                handleUnexpectedDisconnect(loopGeneration)
                return
            }
        }
    }

    private func handleUnexpectedDisconnect(_ loopGeneration: Int) {
        guard loopGeneration == generation else { return }
        generation += 1
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        receiveTask = nil
        onState(false)
    }

    // MARK: - 保活

    /// 设备端不会主动关掉空闲的控制连接，但 Mac 休眠、Wi-Fi 切换、路由器清 NAT 时 TCP 会悄悄失效，
    /// 而 URLSessionWebSocketTask 的 receive() 不会及时报错——连接就“假死”了：
    /// 界面仍显示已连接，音量/音源/设置报文却全部石沉大海。
    ///
    /// 判定完全基于“入站静默”：设备会周期性推送 serverinfo / wplayerv2 / playstatus，任何一条都算活着。
    /// 只有静默时才补一个 play_status_req 探针（设备回不回都不影响结论，回包同样只是刷新入站时间），
    /// 所以正常播放时不会产生额外报文，也不会因为探针回包去改 UI。
    private func startHeartbeat(_ task: URLSessionWebSocketTask, generation loopGeneration: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatTick * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                let shouldStop = await self.heartbeatWatchdog(task, generation: loopGeneration)
                if shouldStop { return }
            }
        }
    }

    /// 静默多久算假死：按本次连接观察到的最大间隔自适应，避免设备推送本来就稀疏时误判。
    private var inboundTimeout: TimeInterval {
        min(Self.maxInboundTimeout, max(Self.minInboundTimeout, maxInboundGap * 3))
    }

    /// 返回 true 表示这条连接已经结束，看门狗应退出。
    private func heartbeatWatchdog(_ task: URLSessionWebSocketTask, generation loopGeneration: Int) async -> Bool {
        guard loopGeneration == generation else { return true }

        let silence = Date().timeIntervalSince(lastInboundAt)
        if silence >= inboundTimeout {
            handleUnexpectedDisconnect(loopGeneration)
            return true
        }

        guard silence >= Self.probeSilence else { return false }

        // 只是“叫一声”，不 await：假死时 send 可能长时间挂住，等它会把看门狗本身也卡死。
        let probe = Outbound.requestPlayStatus() ?? "{}"
        Task { try? await task.send(.string(probe)) }
        return false
    }
}

/// 用于“连接成功”和“超时取消”之间的互斥，避免超时任务误杀刚建立的连接。
private final class ConnectionAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}
