import Darwin
import Foundation

enum Sysctl {
    static func bytes(_ name: String) throws -> [UInt8] {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else {
            throw CollectorError("sysctl \(name): \(errnoString())")
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            throw CollectorError("sysctl \(name): \(errnoString())")
        }
        return Array(buffer[..<size])
    }

    static func string(_ name: String) throws -> String {
        let raw = try bytes(name)
        let end = raw.firstIndex(of: 0) ?? raw.count
        return String(decoding: raw[..<end], as: UTF8.self)
    }

    /// Reads a 32- or 64-bit integer sysctl.
    static func integer(_ name: String) throws -> Int64 {
        let raw = try bytes(name)
        switch raw.count {
        case 4: return Int64(raw.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        case 8: return raw.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        default: throw CollectorError("sysctl \(name): unexpected size \(raw.count)")
        }
    }

    static func value<T>(_ name: String, as type: T.Type) throws -> T {
        let raw = try bytes(name)
        guard raw.count >= MemoryLayout<T>.size else {
            throw CollectorError("sysctl \(name): got \(raw.count) bytes, need \(MemoryLayout<T>.size)")
        }
        return raw.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }

    /// Size in bytes that a MIB-addressed sysctl would return.
    static func size(mib: [Int32]) throws -> Int {
        var mib = mib
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
            throw CollectorError("sysctl \(mib): \(errnoString())")
        }
        return size
    }
}
