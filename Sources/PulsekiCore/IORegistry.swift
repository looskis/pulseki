import Foundation
import IOKit

enum IORegistry {
    /// Every service matching an IOKit class name. Caller releases each entry.
    static func services(matching className: String) -> [io_object_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS,
              iterator != 0 else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [io_object_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            result.append(service)
        }
        return result
    }

    static func release(_ services: [io_object_t]) {
        for service in services { IOObjectRelease(service) }
    }

    static func properties(of entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() else { return [:] }
        return (dict as NSDictionary) as? [String: Any] ?? [:]
    }

    /// Searches the entry and its descendants in the IOService plane.
    static func searchProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        let value = IORegistryEntrySearchCFProperty(
            entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively))
        return value
    }

    static func parent(of entry: io_registry_entry_t) -> io_registry_entry_t? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else {
            return nil
        }
        return parent
    }

    static func className(of entry: io_object_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buffer) == KERN_SUCCESS else { return "unknown" }
        return String(cString: buffer)
    }

    /// Coerces an IOKit property (CFNumber, CFBoolean) to a Double.
    static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let b = value as? Bool, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            return b ? 1 : 0
        }
        if let n = value as? NSNumber {
            let d = n.doubleValue
            // Negative values occasionally arrive as wrapped unsigned 64-bit numbers.
            if d > 9.2e18 { return Double(Int64(bitPattern: n.uint64Value)) }
            return d
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue != 0 }
        return nil
    }

    /// Coerces a CFString or NUL-terminated CFData property to a String.
    static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        if let d = value as? Data {
            let end = d.firstIndex(of: 0) ?? d.endIndex
            let s = String(decoding: d[d.startIndex..<end], as: UTF8.self)
            return s.isEmpty ? nil : s
        }
        return nil
    }
}
