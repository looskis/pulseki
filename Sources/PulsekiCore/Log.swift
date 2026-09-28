import Foundation

public enum Log {
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func info(_ message: String) { write("info", message) }
    public static func warn(_ message: String) { write("warn", message) }
    public static func error(_ message: String) { write("error", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) level=\(level) msg=\(quote(message))\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func quote(_ s: String) -> String {
        if s.contains(" ") || s.contains("\"") {
            return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return s
    }
}

/// strerror(errno) as a Swift string.
func errnoString(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
}

/// Reads a fixed-size C char array (imported as a tuple) as a string,
/// stopping at the first NUL or the end of the array.
func cString<T>(_ tuple: T) -> String {
    var copy = tuple
    return withUnsafeBytes(of: &copy) { raw in
        let end = raw.firstIndex(of: 0) ?? raw.count
        return String(decoding: raw[..<end], as: UTF8.self)
    }
}
