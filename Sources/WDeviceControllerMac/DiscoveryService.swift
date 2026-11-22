import Foundation

/// 设备发现：复刻原版 Wndr.Discover。
/// 向局域网各网段的 9400 端口广播 search 报文，设备以 notify/discovery 回应。
enum DiscoveryService {
    private static let discoveryPort: UInt16 = 9400
    private static let defaultDevicePort = 9000

    private static let searchPayload = Data(
        "{\"command\":\"search\",\"target\":\"all\",\"protocol\":\"wremote-bcast:v0.1\",\"version\":\"0.2\",\"ipv4_addr\":\"\",\"mac_addr\":\"\"}".utf8
    )

    static func scan(timeout: TimeInterval = 4) async -> [DeviceInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: scanSync(timeout: timeout))
            }
        }
    }

    private static func scanSync(timeout: TimeInterval) -> [DeviceInfo] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enable, socklen_t(MemoryLayout<Int32>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return [] }

        for broadcast in lanBroadcastAddresses() {
            send(payload: searchPayload, fd: fd, address: broadcast, port: discoveryPort)
        }

        var found: [String: DeviceInfo] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(max(0.5, timeout))

        while Date() < deadline {
            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            if remainingMs <= 0 { break }

            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, min(remainingMs, 300))
            guard ready > 0 else { continue }

            var remote = sockaddr_in()
            var remoteLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &remote) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &remoteLength)
                }
            }
            guard received > 0 else { continue }

            let data = Data(buffer.prefix(Int(received)))
            guard let device = parseResponse(data, remote: remote) else { continue }
            found[device.id] = device
        }

        return found.values.sorted {
            if $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedSame {
                return $0.ip < $1.ip
            }
            return $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending
        }
    }

    private static func send(payload: Data, fd: Int32, address: in_addr_t, port: UInt16) {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr.s_addr = address

        _ = payload.withUnsafeBytes { rawBuffer in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, rawBuffer.baseAddress, rawBuffer.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func parseResponse(_ data: Data, remote: sockaddr_in) -> DeviceInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }

        let command = (root["command"] as? String)?.lowercased() ?? ""
        guard command == "notify" || command == "discovery" else { return nil }

        var host = root["ipv4_addr"] as? String ?? ""
        if host.isEmpty {
            host = ipString(remote.sin_addr)
        }
        guard !host.isEmpty else { return nil }

        // 注意：响应里的 wndr-port（例如 9200）是 WNDR 音频输出端口，不是控制端口。
        // 原版 Windows 的 DnsScanner 也无视它，固定用 9000 连接 WebSocket；
        // 实测 WSlimPro 只开放 80/9000，用 wndr-port 会连接失败。
        var port = defaultDevicePort
        if let number = root["port"] as? NSNumber {
            port = number.intValue
        } else if let text = root["port"] as? String, let parsed = Int(text) {
            port = parsed
        }
        if port <= 0 { port = defaultDevicePort }

        var name = root["model"] as? String ?? ""
        if name.isEmpty { name = root["name"] as? String ?? "" }
        if name.isEmpty { name = "WNDR" }

        return DeviceInfo(hostname: name, ip: host, port: port)
    }

    private static func ipString(_ address: in_addr) -> String {
        var addr = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buffer)
    }

    /// 枚举所有已启用的 IPv4 网卡并计算定向广播地址；没有可用网卡时退回 255.255.255.255。
    private static func lanBroadcastAddresses() -> [in_addr_t] {
        var result: [in_addr_t] = []
        var seen = Set<in_addr_t>()

        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return [in_addr_t(0xFFFF_FFFF)]
        }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }

            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard let mask = entry.pointee.ifa_netmask,
                  mask.pointee.sa_family == UInt8(AF_INET) else { continue }

            let ipBytes = withUnsafePointer(to: addr.pointee) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            }
            let maskBytes = withUnsafePointer(to: mask.pointee) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            }

            let ip = ipBytes.s_addr
            let netmask = maskBytes.s_addr
            // 跳过 169.254/16 链路本地地址
            if ipString(ipBytes).hasPrefix("169.254.") { continue }

            let broadcast = ip | ~netmask
            if seen.insert(broadcast).inserted {
                result.append(broadcast)
            }
        }

        if result.isEmpty {
            result.append(in_addr_t(0xFFFF_FFFF))
        }
        return result
    }
}
