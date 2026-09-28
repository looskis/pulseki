import Darwin
import Foundation

/// node_cpu_seconds_total from host_processor_info, plus the Apple silicon
/// performance-level topology (P and E core counts), which is static.
final class CPUCollector: Collector {
    let name = "cpu"

    private let ticksPerSecond = Double(sysconf(_SC_CLK_TCK))
    private let topology: [MetricFamily]

    init() {
        topology = CPUCollector.readTopology()
    }

    func collect() throws -> [MetricFamily] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else {
            throw CollectorError("host_processor_info failed: \(kr)")
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var seconds = MetricFamily(
            name: "node_cpu_seconds_total", help: "Seconds the CPUs spent in each mode.", type: .counter)
        let modes: [(Int32, String)] = [
            (CPU_STATE_USER, "user"), (CPU_STATE_SYSTEM, "system"), (CPU_STATE_IDLE, "idle"), (CPU_STATE_NICE, "nice"),
        ]
        let stride = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            let cpuLabel = String(cpu)
            for (state, mode) in modes {
                let ticks = UInt32(bitPattern: info[cpu * stride + Int(state)])
                seconds.add(Double(ticks) / ticksPerSecond, [("cpu", cpuLabel), ("mode", mode)])
            }
        }
        return [seconds] + topology
    }

    private static func readTopology() -> [MetricFamily] {
        var logical = MetricFamily(
            name: "macos_cpu_logical_cpus", help: "Number of logical CPUs.", type: .gauge)
        var physical = MetricFamily(
            name: "macos_cpu_physical_cpus", help: "Number of physical CPU cores.", type: .gauge)
        if let v = try? Sysctl.integer("hw.logicalcpu") { logical.add(Double(v)) }
        if let v = try? Sysctl.integer("hw.physicalcpu") { physical.add(Double(v)) }

        var levelLogical = MetricFamily(
            name: "macos_cpu_perflevel_logical_cpus",
            help: "Logical CPUs in each performance level (Apple silicon: Performance and Efficiency).", type: .gauge)
        var levelPhysical = MetricFamily(
            name: "macos_cpu_perflevel_physical_cpus",
            help: "Physical CPU cores in each performance level.", type: .gauge)
        var levelL2 = MetricFamily(
            name: "macos_cpu_perflevel_l2_cache_bytes",
            help: "L2 cache size per cluster in each performance level.", type: .gauge)

        let levels = (try? Sysctl.integer("hw.nperflevels")) ?? 0
        for level in 0..<levels {
            let prefix = "hw.perflevel\(level)."
            let levelName = (try? Sysctl.string(prefix + "name")) ?? "level\(level)"
            let labels = [("level", String(level)), ("name", levelName)]
            if let v = try? Sysctl.integer(prefix + "logicalcpu") { levelLogical.add(Double(v), labels) }
            if let v = try? Sysctl.integer(prefix + "physicalcpu") { levelPhysical.add(Double(v), labels) }
            if let v = try? Sysctl.integer(prefix + "l2cachesize") { levelL2.add(Double(v), labels) }
        }
        return [logical, physical, levelLogical, levelPhysical, levelL2]
    }
}
