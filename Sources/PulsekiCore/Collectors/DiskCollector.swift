import Foundation
import IOKit

/// Per-disk I/O counters from IOBlockStorageDriver's Statistics dictionary,
/// keyed by the BSD name of the whole-disk IOMedia beneath it.
final class DiskCollector: Collector {
    let name = "diskstats"

    func collect() throws -> [MetricFamily] {
        let drivers = IORegistry.services(matching: "IOBlockStorageDriver")
        defer { IORegistry.release(drivers) }

        var readBytes = MetricFamily(name: "node_disk_read_bytes_total", help: "Bytes read from the device.", type: .counter)
        var writtenBytes = MetricFamily(name: "node_disk_written_bytes_total", help: "Bytes written to the device.", type: .counter)
        var reads = MetricFamily(name: "node_disk_reads_completed_total", help: "Read operations completed.", type: .counter)
        var writes = MetricFamily(name: "node_disk_writes_completed_total", help: "Write operations completed.", type: .counter)
        var readTime = MetricFamily(name: "node_disk_read_time_seconds_total", help: "Seconds spent servicing reads.", type: .counter)
        var writeTime = MetricFamily(name: "node_disk_write_time_seconds_total", help: "Seconds spent servicing writes.", type: .counter)
        var readErrors = MetricFamily(name: "node_disk_read_errors_total", help: "Read errors.", type: .counter)
        var writeErrors = MetricFamily(name: "node_disk_write_errors_total", help: "Write errors.", type: .counter)
        var readRetries = MetricFamily(name: "node_disk_read_retries_total", help: "Read retries.", type: .counter)
        var writeRetries = MetricFamily(name: "node_disk_write_retries_total", help: "Write retries.", type: .counter)

        for driver in drivers {
            guard let device = IORegistry.string(IORegistry.searchProperty(driver, "BSD Name")) else { continue }
            let props = IORegistry.properties(of: driver)
            guard let stats = props["Statistics"] as? [String: Any] else { continue }
            let labels = [("device", device)]
            func put(_ key: String, into family: inout MetricFamily, scale: Double = 1) {
                if let v = IORegistry.number(stats[key]) { family.add(v * scale, labels) }
            }
            put("Bytes (Read)", into: &readBytes)
            put("Bytes (Write)", into: &writtenBytes)
            put("Operations (Read)", into: &reads)
            put("Operations (Write)", into: &writes)
            put("Total Time (Read)", into: &readTime, scale: 1e-9)
            put("Total Time (Write)", into: &writeTime, scale: 1e-9)
            put("Errors (Read)", into: &readErrors)
            put("Errors (Write)", into: &writeErrors)
            put("Retries (Read)", into: &readRetries)
            put("Retries (Write)", into: &writeRetries)
        }
        return [readBytes, writtenBytes, reads, writes, readTime, writeTime, readErrors, writeErrors, readRetries, writeRetries]
    }
}
