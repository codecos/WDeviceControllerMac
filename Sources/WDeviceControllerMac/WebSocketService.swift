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
    private var generation = 0

    private let onState: @Sendable (Bool) -> Void
    private let onMessage: @Sendable (String) -> Void

    private static let connectTimeout: TimeInterval = 10

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
            if currentGeneration == generation {
                task.cancel(with: .goingAway, reason: nil)
                socket = nil
                generation += 1
            }
            onState(false)
            return false
        }
        timeoutTask.cancel()

        guard attempt.finish(), currentGeneration == generation else {
            if currentGeneration == generation {
                task.cancel(with: .goingAway, reason: nil)
                socket = nil
                generation += 1
            }
            onState(false)
            return false
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task, generation: currentGeneration)
        }
        onState(true)
        return true
    }

    @discardableResult
    func send(_ text: String) async -> Bool {
        guard let task = socket else { return false }
        do {
            try await task.send(.string(text))
            return true
        } catch {
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
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        receiveTask = nil
        onState(false)
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
