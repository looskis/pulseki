import Darwin
import Foundation

/// Memory statistics from host_statistics64, swap from vm.swapusage, and the
/// kernel's memory pressure level. Names follow node_exporter's darwin
/// meminfo collector where one exists.
final class MemoryCollector: Collector {
    let name = "memory"

    private let totalBytes: Double?
    private let pageSize: Double

    init() {
        totalBytes = (try? Sysctl.integer("hw.memsize")).map(Double.init)
        var size: vm_size_t = 0
        pageSize = host_page_size(mach_host_self(), &size) == KERN_SUCCESS ? Double(size) : 16384
    }

    func collect() throws -> [MetricFamily] {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { throw CollectorError("host_statistics64 failed: \(kr)") }

        let ps = pageSize
        func pages(_ n: UInt32) -> Double { Double(n) * ps }
        func pages(_ n: UInt64) -> Double { Double(n) * ps }

        var families: [MetricFamily] = []
        func gauge(_ name: String, _ help: String, _ value: Double) {
            families.append(MetricFamily(name: name, help: help, type: .gauge, value: value))
        }
        func counter(_ name: String, _ help: String, _ value: Double) {
            families.append(MetricFamily(name: name, help: help, type: .counter, value: value))
        }

        if let totalBytes { gauge("node_memory_total_bytes", "Total physical memory in bytes.", totalBytes) }
        gauge("node_memory_free_bytes", "Free memory in bytes.", pages(stats.free_count))
        gauge("node_memory_active_bytes", "Memory recently used, in bytes.", pages(stats.active_count))
        gauge("node_memory_inactive_bytes", "Memory not recently used and reclaimable, in bytes.", pages(stats.inactive_count))
        gauge("node_memory_wired_bytes", "Memory that cannot be paged out, in bytes.", pages(stats.wire_count))
        gauge("node_memory_compressed_bytes", "Memory held by the compressor, in bytes.", pages(stats.compressor_page_count))
        gauge("node_memory_internal_bytes", "Anonymous (internal) memory in bytes.", pages(stats.internal_page_count))
        gauge("node_memory_purgeable_bytes", "Purgeable memory in bytes.", pages(stats.purgeable_count))
        gauge("macos_memory_external_bytes", "File-backed (external) memory in bytes.", pages(stats.external_page_count))
        gauge("macos_memory_speculative_bytes", "Speculatively read-ahead memory in bytes.", pages(stats.speculative_count))
        gauge("macos_memory_app_bytes",
              "Memory used by apps as Activity Monitor reports it (internal minus purgeable), in bytes.",
              pages(stats.internal_page_count) - pages(stats.purgeable_count))
        gauge("macos_memory_uncompressed_in_compressor_bytes",
              "Uncompressed size of the data held in the compressor, in bytes.",
              pages(stats.total_uncompressed_pages_in_compressor))

        counter("node_memory_swapped_in_bytes_total", "Bytes swapped in since boot.", pages(stats.swapins))
        counter("node_memory_swapped_out_bytes_total", "Bytes swapped out since boot.", pages(stats.swapouts))
        counter("macos_memory_pageins_total", "Pages read from disk since boot.", Double(stats.pageins))
        counter("macos_memory_pageouts_total", "Pages written to disk since boot.", Double(stats.pageouts))
        counter("macos_memory_page_faults_total", "Page faults since boot.", Double(stats.faults))
        counter("macos_memory_compressions_total", "Pages compressed since boot.", Double(stats.compressions))
        counter("macos_memory_decompressions_total", "Pages decompressed since boot.", Double(stats.decompressions))

        if let swap = try? Sysctl.value("vm.swapusage", as: xsw_usage.self) {
            gauge("node_memory_swap_total_bytes", "Total swap space in bytes.", Double(swap.xsu_total))
            gauge("node_memory_swap_used_bytes", "Used swap space in bytes.", Double(swap.xsu_used))
            gauge("macos_memory_swap_free_bytes", "Free swap space in bytes.", Double(swap.xsu_avail))
        }
        if let level = try? Sysctl.integer("kern.memorystatus_vm_pressure_level") {
            gauge("macos_memory_pressure_level",
                  "Kernel memory pressure level: 1 normal, 2 warning, 4 critical.", Double(level))
        }
        return families
    }
}
