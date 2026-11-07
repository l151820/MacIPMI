import Darwin
import Foundation

/// Minimal connected UDP socket. All socket I/O happens on a private serial
/// queue, which also serializes request/response exchanges.
final class UDPTransport: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "IPMIKit.udp")

    init(host: String, port: UInt16) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let ai = res else {
            throw IPMIError.network("Host „\(host)“ nicht auflösbar: \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(res) }

        let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard s >= 0 else { throw IPMIError.network("socket(): \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(s)
            throw IPMIError.network("connect(): \(msg)")
        }
        fd = s
    }

    deinit { Darwin.close(fd) }

    private func transmit(_ bytes: [UInt8]) throws {
        let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        if n < 0 { throw IPMIError.network("send(): \(String(cString: strerror(errno)))") }
    }

    private func receive(timeout: TimeInterval) throws -> [UInt8]? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, Int32(max(1, timeout * 1000)))
        if r == 0 { return nil }
        if r < 0 {
            if errno == EINTR { return nil }
            throw IPMIError.network("poll(): \(String(cString: strerror(errno)))")
        }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buf, buf.count, 0)
        if n < 0 {
            if errno == ECONNREFUSED {
                throw IPMIError.network("Port nicht erreichbar (ICMP port unreachable) – IPMI over LAN aktiviert?")
            }
            throw IPMIError.network("recv(): \(String(cString: strerror(errno)))")
        }
        return Array(buf.prefix(n))
    }

    /// Sends `packet` and waits for a reply accepted by `accept`, retransmitting on timeout.
    func exchange(
        _ packet: [UInt8],
        timeout: TimeInterval,
        retries: Int,
        accept: @escaping @Sendable ([UInt8]) -> Bool
    ) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            queue.async {
                do {
                    for _ in 0...max(0, retries) {
                        try self.transmit(packet)
                        let deadline = Date().addingTimeInterval(timeout)
                        while true {
                            let remaining = deadline.timeIntervalSinceNow
                            if remaining <= 0 { break }
                            if let reply = try self.receive(timeout: remaining), accept(reply) {
                                cont.resume(returning: reply)
                                return
                            }
                        }
                    }
                    cont.resume(throwing: IPMIError.timeout)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
