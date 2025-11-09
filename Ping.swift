import Foundation
import Darwin

enum Ping {
    /// Quiet reachability check by attempting a short TCP connect (no Network.framework).
    static func isReachable(ip: String, port: UInt16 = 3001, timeout: TimeInterval = 0.35,
                            completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var inetAddr = in_addr()
            guard ip.withCString({ inet_pton(AF_INET, $0, &inetAddr) }) == 1 else {
                completion(false); return
            }

            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = in_port_t(bigEndian: port.bigEndian)
            sa.sin_addr = inetAddr

            let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            if sock < 0 { completion(false); return }

            let flags = fcntl(sock, F_GETFL, 0)
            _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

            var one: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))

            var saddr = sockaddr()
            memcpy(&saddr, &sa, MemoryLayout<sockaddr_in>.size)
            let res = withUnsafePointer(to: &saddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if res == 0 { close(sock); completion(true); return }
            if errno != EINPROGRESS { close(sock); completion(false); return }

            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, Int32(max(1, Int(timeout * 1000))))
            if pr <= 0 { close(sock); completion(false); return }

            var err: Int32 = 0
            var len = socklen_t(MemoryLayout.size(ofValue: err))
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
            close(sock)
            completion(err == 0)
        }
    }
}

