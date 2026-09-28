import CSystem
import Foundation

public struct SMCError: Error, CustomStringConvertible {
    public let code: Int32
    public let operation: String

    public var description: String {
        if code >= 0x10000 {
            return "\(operation): SMC result \(code - 0x10000)"
        }
        if code == Int32(bitPattern: 0xE00002C0) {
            return "\(operation): AppleSMC service not found"
        }
        return "\(operation): IOKit error 0x\(String(UInt32(bitPattern: code), radix: 16))"
    }
}

/// Unprivileged client for the AppleSMC user client. One instance owns one
/// connection; it is not thread-safe.
public final class SMCClient {
    public struct KeyInfo {
        public let key: String
        public let code: UInt32
        public let type: String
        public let size: Int
        public let attributes: UInt8
    }

    private var connection: UInt32 = 0

    public init() throws {
        let rc = psk_smc_open(&connection)
        if rc != 0 { throw SMCError(code: rc, operation: "open") }
    }

    deinit {
        psk_smc_close(connection)
    }

    public func keyCount() throws -> Int {
        var count: UInt32 = 0
        let rc = psk_smc_key_count(connection, &count)
        if rc != 0 { throw SMCError(code: rc, operation: "read #KEY") }
        return Int(count)
    }

    public func key(at index: Int) throws -> UInt32 {
        var code: UInt32 = 0
        let rc = psk_smc_key_at_index(connection, UInt32(index), &code)
        if rc != 0 { throw SMCError(code: rc, operation: "key at index \(index)") }
        return code
    }

    public func info(forKey code: UInt32) throws -> KeyInfo {
        var raw = psk_smc_key_info_t()
        let rc = psk_smc_key_info(connection, code, &raw)
        if rc != 0 { throw SMCError(code: rc, operation: "info for \(SMCClient.string(fourcc: code))") }
        return KeyInfo(
            key: SMCClient.string(fourcc: code), code: code,
            type: SMCClient.string(fourcc: raw.type), size: Int(raw.size), attributes: raw.attributes)
    }

    public func info(forKey key: String) throws -> KeyInfo {
        try info(forKey: SMCClient.fourcc(key))
    }

    public func readRaw(_ info: KeyInfo) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        let rc = psk_smc_read_key(connection, info.code, UInt32(info.size), &bytes)
        if rc != 0 { throw SMCError(code: rc, operation: "read \(info.key)") }
        return Array(bytes[..<min(info.size, 32)])
    }

    /// Decodes the key's value to a Double, or nil when the type is not numeric.
    public func readDouble(_ info: KeyInfo) throws -> Double? {
        SMCClient.decode(type: info.type, bytes: try readRaw(info))
    }

    /// Enumerates every key the SMC exposes. Slow-ish (two round trips per
    /// key), so call once at startup.
    public func allKeys() throws -> [KeyInfo] {
        let count = try keyCount()
        var keys: [KeyInfo] = []
        keys.reserveCapacity(count)
        for index in 0..<count {
            guard let code = try? key(at: index), let info = try? info(forKey: code) else { continue }
            keys.append(info)
        }
        return keys
    }

    // MARK: - Decoding

    /// Integers are big-endian on the wire; IEEE floats are native (little-endian).
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        func be(_ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<min(n, bytes.count) { v = (v << 8) | UInt64(bytes[i]) }
            return v
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ": return bytes.count >= 1 ? Double(bytes[0]) : nil
        case "ui16": return bytes.count >= 2 ? Double(be(2)) : nil
        case "ui32": return bytes.count >= 4 ? Double(be(4)) : nil
        case "ui64": return bytes.count >= 8 ? Double(be(8)) : nil
        case "si8 ": return bytes.count >= 1 ? Double(Int8(bitPattern: bytes[0])) : nil
        case "si16": return bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(be(2)))) : nil
        case "si32": return bytes.count >= 4 ? Double(Int32(bitPattern: UInt32(be(4)))) : nil
        case "si64": return bytes.count >= 8 ? Double(Int64(bitPattern: be(8))) : nil
        case "sp78": return bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(be(2)))) / 256 : nil
        case "sp96": return bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(be(2)))) / 64 : nil
        case "fpe2": return bytes.count >= 2 ? Double(be(2)) / 4 : nil
        case "fp88": return bytes.count >= 2 ? Double(be(2)) / 256 : nil
        case "ioft": return bytes.count >= 8 ? Double(be(8)) / 65536 : nil
        case "flag": return bytes.count >= 1 ? (bytes[0] != 0 ? 1 : 0) : nil
        default: return nil
        }
    }

    static func fourcc(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for byte in s.utf8.prefix(4) { v = (v << 8) | UInt32(byte) }
        return v
    }

    static func string(fourcc: UInt32) -> String {
        let bytes = [UInt8(fourcc >> 24), UInt8((fourcc >> 16) & 0xFF), UInt8((fourcc >> 8) & 0xFF), UInt8(fourcc & 0xFF)]
        return String(bytes.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "?" })
    }
}

/// `pulseki smc-dump`: prints every key, for finding sensor names.
public enum SMCDump {
    public static func run() -> Int32 {
        let client: SMCClient
        do {
            client = try SMCClient()
        } catch {
            Log.error("cannot open SMC: \(error)")
            return 1
        }
        let keys: [SMCClient.KeyInfo]
        do {
            keys = try client.allKeys().sorted { $0.key < $1.key }
        } catch {
            Log.error("cannot enumerate SMC keys: \(error)")
            return 1
        }
        print("KEY  TYPE SIZE VALUE            HEX")
        for info in keys {
            guard let raw = try? client.readRaw(info) else {
                print("\(info.key) \(info.type) \(pad(info.size, 4)) <unreadable>")
                continue
            }
            let hex = raw.map { String(format: "%02x", $0) }.joined()
            let value = SMCClient.decode(type: info.type, bytes: raw).map { Exposition.formatValue(round($0 * 1000) / 1000) } ?? "-"
            print("\(info.key) \(info.type) \(pad(info.size, 4)) \(value.padding(toLength: 16, withPad: " ", startingAt: 0)) \(hex)")
        }
        return 0
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        String(n).padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
