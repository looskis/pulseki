import Foundation

public enum CollectorFactory {
    /// Collector names, in exposition order.
    public static let names = [
        "cpu", "load", "memory", "filesystem", "diskstats", "network",
        "gpu", "thermal", "smc", "battery", "system",
    ]

    public static func make(_ config: Config) -> [Collector] {
        var collectors: [Collector] = []
        for name in names where !config.disabledCollectors.contains(name) {
            do {
                collectors.append(try build(name, config))
            } catch {
                Log.warn("collector \(name) disabled: \(error)")
            }
        }
        return collectors
    }

    private static func build(_ name: String, _ config: Config) throws -> Collector {
        switch name {
        case "cpu": return CPUCollector()
        case "load": return LoadCollector()
        case "memory": return MemoryCollector()
        case "filesystem": return try FilesystemCollector(config: config)
        case "diskstats": return DiskCollector()
        case "network": return try NetworkCollector(config: config)
        case "gpu": return GPUCollector()
        case "thermal": return ThermalCollector()
        case "smc": return try SMCCollector(config: config)
        case "battery": return BatteryCollector()
        case "system": return SystemCollector()
        default: throw CollectorError("no such collector")
        }
    }
}
