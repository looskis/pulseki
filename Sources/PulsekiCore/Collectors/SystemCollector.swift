import Darwin
import Foundation

final class SystemCollector: Collector {
    let name = "system"

    private let staticFamilies: [MetricFamily]

    init() {
        var families: [MetricFamily] = []

        var uts = utsname()
        uname(&uts)
        families.append(MetricFamily(
            name: "node_uname_info", help: "Labeled system information as provided by the uname system call.",
            type: .gauge, value: 1,
            labels: [
                ("domainname", "(none)"), ("machine", cString(uts.machine)), ("nodename", cString(uts.nodename)),
                ("release", cString(uts.release)), ("sysname", cString(uts.sysname)), ("version", cString(uts.version)),
            ]))

        let productVersion = (try? Sysctl.string("kern.osproductversion")) ?? "unknown"
        let build = (try? Sysctl.string("kern.osversion")) ?? "unknown"
        families.append(MetricFamily(
            name: "macos_version_info", help: "macOS product version and build.", type: .gauge, value: 1,
            labels: [("version", productVersion), ("build", build)]))

        let model = (try? Sysctl.string("hw.model")) ?? "unknown"
        let chip = (try? Sysctl.string("machdep.cpu.brand_string")) ?? "unknown"
        families.append(MetricFamily(
            name: "macos_hardware_info", help: "Mac model identifier and CPU brand.", type: .gauge, value: 1,
            labels: [("model", model), ("chip", chip)]))

        if let boot = try? Sysctl.value("kern.boottime", as: timeval.self) {
            families.append(MetricFamily(
                name: "node_boot_time_seconds", help: "Unix time of last boot.", type: .gauge,
                value: Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6))
        }
        staticFamilies = families
    }

    func collect() throws -> [MetricFamily] {
        var families = staticFamilies
        families.append(MetricFamily(
            name: "node_time_seconds", help: "System time in seconds since epoch.", type: .gauge,
            value: Date().timeIntervalSince1970))
        if let size = try? Sysctl.size(mib: [CTL_KERN, KERN_PROC, KERN_PROC_ALL]) {
            families.append(MetricFamily(
                name: "macos_processes", help: "Number of processes.", type: .gauge,
                value: Double(size / MemoryLayout<kinfo_proc>.stride)))
        }
        return families
    }
}
