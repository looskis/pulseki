import Darwin
import Foundation

public protocol Collector: AnyObject {
    var name: String { get }
    /// Returns every metric family for this scrape, or throws. A throwing
    /// collector contributes nothing to the exposition, so partial output
    /// from a broken data source can never corrupt the response.
    func collect() throws -> [MetricFamily]
}

public struct CollectorError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Runs collectors, appends self metrics, and serialises scrapes.
public final class Registry {
    private let lock = NSLock()
    private let collectors: [Collector]
    private var failing: Set<String> = []
    private var scrapes: UInt64 = 0
    private let startTime = Date().timeIntervalSince1970
    private let buildInfo: MetricFamily
    /// Extra metric sources appended to every scrape (for example push statistics).
    public var extraProviders: [() -> [MetricFamily]] = []

    public init(collectors: [Collector]) {
        self.collectors = collectors
        var uts = utsname()
        uname(&uts)
        buildInfo = MetricFamily(
            name: "pulseki_build_info",
            help: "Build information for this pulseki binary.",
            type: .gauge,
            value: 1,
            labels: [("version", Version.string), ("os", "darwin"), ("arch", cString(uts.machine))]
        )
    }

    public var collectorNames: [String] { collectors.map(\.name) }

    public func scrape() -> String {
        Exposition.render(collectFamilies())
    }

    /// Runs every collector once and returns all families plus self metrics.
    public func collectFamilies() -> [MetricFamily] {
        lock.lock()
        defer { lock.unlock() }

        var families: [MetricFamily] = []
        families.reserveCapacity(128)

        var durations = MetricFamily(
            name: "pulseki_scrape_collector_duration_seconds",
            help: "Time spent in each collector during this scrape.", type: .gauge)
        var successes = MetricFamily(
            name: "pulseki_scrape_collector_success",
            help: "Whether the collector succeeded (1) or failed (0) during this scrape.", type: .gauge)

        for collector in collectors {
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                families += try collector.collect()
                successes.add(1, [("collector", collector.name)])
                if failing.remove(collector.name) != nil {
                    Log.info("collector \(collector.name) recovered")
                }
            } catch {
                if failing.insert(collector.name).inserted {
                    Log.error("collector \(collector.name) failed: \(error)")
                }
                successes.add(0, [("collector", collector.name)])
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            durations.add(elapsed, [("collector", collector.name)])
        }

        scrapes += 1
        var scrapeTotal = MetricFamily(
            name: "pulseki_scrapes_total", help: "Number of scrapes served since start.", type: .counter)
        scrapeTotal.add(Double(scrapes))

        families += [durations, successes, scrapeTotal, buildInfo]
        families += ProcessMetrics.collect(startTime: startTime)
        for provider in extraProviders { families += provider() }
        return families
    }
}

/// Standard process_* metrics for the exporter itself.
enum ProcessMetrics {
    static func collect(startTime: Double) -> [MetricFamily] {
        var families: [MetricFamily] = []

        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let cpu = seconds(usage.ru_utime) + seconds(usage.ru_stime)
            families.append(MetricFamily(
                name: "process_cpu_seconds_total",
                help: "Total user and system CPU time spent in seconds.", type: .counter, value: cpu))
        }

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            families.append(MetricFamily(
                name: "process_resident_memory_bytes",
                help: "Resident memory size in bytes.", type: .gauge, value: Double(info.resident_size)))
            families.append(MetricFamily(
                name: "process_virtual_memory_bytes",
                help: "Virtual memory size in bytes.", type: .gauge, value: Double(info.virtual_size)))
        }

        families.append(MetricFamily(
            name: "process_start_time_seconds",
            help: "Start time of the process since unix epoch in seconds.", type: .gauge, value: startTime))

        var limit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limit) == 0 {
            let max = limit.rlim_cur >= rlim_t(Int64.max) ? Double.infinity : Double(limit.rlim_cur)
            families.append(MetricFamily(
                name: "process_max_fds", help: "Maximum number of open file descriptors.", type: .gauge, value: max))
        }

        let fdBytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        if fdBytes > 0 {
            let open = Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride
            families.append(MetricFamily(
                name: "process_open_fds", help: "Number of open file descriptors.", type: .gauge, value: Double(open)))
        }

        return families
    }

    private static func seconds(_ tv: timeval) -> Double {
        Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }
}
