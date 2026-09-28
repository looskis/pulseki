import Darwin
import Foundation

public struct ListenAddress: CustomStringConvertible {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Accepts "host:port", ":port", "[v6]:port" or a bare port.
    public static func parse(_ text: String) throws -> ListenAddress {
        let s = text.trimmingCharacters(in: .whitespaces)
        var host = ""
        var portText = s
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { throw ConfigError("invalid listen address '\(text)'") }
            host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":") else { throw ConfigError("invalid listen address '\(text)'") }
            portText = String(rest.dropFirst())
        } else if let colon = s.lastIndex(of: ":") {
            host = String(s[..<colon])
            portText = String(s[s.index(after: colon)...])
        }
        guard let port = UInt16(portText), port > 0 else {
            throw ConfigError("invalid port in listen address '\(text)'")
        }
        if host.isEmpty { host = "0.0.0.0" }
        return ListenAddress(host: host, port: port)
    }

    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let query: String?
}

public struct HTTPResponse {
    public var status: Int
    public var contentType: String
    public var body: String

    public init(status: Int = 200, contentType: String = "text/plain; charset=utf-8", body: String) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 431: return "Request Header Fields Too Large"
        default: return "Internal Server Error"
        }
    }
}

/// Minimal HTTP/1.0-style server on POSIX sockets: one accept thread, one
/// GCD task per connection, `Connection: close` on every response. That is
/// exactly the traffic pattern a Prometheus scrape produces, and it keeps
/// the exporter free of Network.framework and third-party dependencies.
public final class HTTPServer {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    private let address: ListenAddress
    private let handler: Handler
    private let queue = DispatchQueue(label: "pulseki.http", qos: .utility, attributes: .concurrent)
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var stopping = false
    private var thread: Thread?

    private static let maxHeaderBytes = 16 * 1024
    private static let ioTimeoutSeconds = 5

    public init(address: ListenAddress, handler: @escaping Handler) {
        self.address = address
        self.handler = handler
    }

    public func start() throws {
        let fd = try HTTPServer.bind(address)
        stateLock.lock()
        listenFD = fd
        stateLock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "pulseki-accept"
        thread.start()
        self.thread = thread
    }

    public func stop() {
        stateLock.lock()
        stopping = true
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    private var isStopping: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopping
    }

    // MARK: - Socket setup

    private static func bind(_ address: ListenAddress) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_PASSIVE | AI_NUMERICSERV
        var results: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(address.host, String(address.port), &hints, &results)
        guard rc == 0, let first = results else {
            throw ConfigError("cannot resolve '\(address)': \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(results) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { throw ConfigError("socket: \(errnoString())") }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        if first.pointee.ai_family == AF_INET6 {
            // Bind dual-stack when asked for an IPv6 wildcard.
            var zero: Int32 = 0
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
        }

        guard Darwin.bind(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
            let message = errnoString()
            close(fd)
            throw ConfigError("bind \(address): \(message)")
        }
        guard listen(fd, 128) == 0 else {
            let message = errnoString()
            close(fd)
            throw ConfigError("listen \(address): \(message)")
        }
        return fd
    }

    private func acceptLoop(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                if isStopping || errno == EBADF { return }
                Log.error("accept failed: \(errnoString())")
                usleep(50_000)
                continue
            }
            configure(fd)
            queue.async { [weak self] in
                self?.handle(fd)
            }
        }
    }

    private func configure(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: HTTPServer.ioTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - Connection handling

    private func handle(_ fd: Int32) {
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: HTTPServer.maxHeaderBytes)
        var total = 0
        var headerEnd: Int?
        while headerEnd == nil, total < buffer.count {
            let n = buffer.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress! + total, raw.count - total, 0)
            }
            if n <= 0 {
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    write(fd, HTTPResponse(status: 408, body: "request timeout\n"), head: false)
                }
                return
            }
            total += n
            headerEnd = HTTPServer.findHeaderEnd(buffer, total)
        }
        guard headerEnd != nil else {
            write(fd, HTTPResponse(status: 431, body: "request headers too large\n"), head: false)
            return
        }

        guard let request = HTTPServer.parseRequestLine(buffer, total) else {
            write(fd, HTTPResponse(status: 400, body: "bad request\n"), head: false)
            return
        }
        let response = handler(request)
        write(fd, response, head: request.method == "HEAD")
    }

    private static func findHeaderEnd(_ buffer: [UInt8], _ length: Int) -> Int? {
        var i = 0
        while i < length {
            if buffer[i] == 0x0A {
                if i >= 1, buffer[i - 1] == 0x0A { return i }
                if i >= 3, buffer[i - 1] == 0x0D, buffer[i - 2] == 0x0A, buffer[i - 3] == 0x0D { return i }
            }
            i += 1
        }
        return nil
    }

    private static func parseRequestLine(_ buffer: [UInt8], _ length: Int) -> HTTPRequest? {
        guard let lineEnd = buffer[0..<length].firstIndex(of: 0x0A) else { return nil }
        var line = String(decoding: buffer[0..<lineEnd], as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        let target = parts[1]
        guard target.hasPrefix("/") else { return nil }
        if let q = target.firstIndex(of: "?") {
            return HTTPRequest(method: String(parts[0]), path: String(target[..<q]), query: String(target[target.index(after: q)...]))
        }
        return HTTPRequest(method: String(parts[0]), path: String(target), query: nil)
    }

    private func write(_ fd: Int32, _ response: HTTPResponse, head: Bool) {
        let body = Array(response.body.utf8)
        var header = "HTTP/1.1 \(response.status) \(HTTPResponse.reason(response.status))\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var bytes = Array(header.utf8)
        if !head { bytes += body }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
            }
            if n <= 0 { return }
            offset += n
        }
    }
}
