import Foundation
import IOKit

/// Battery state from AppleSmartBattery. Desktops expose the service with
/// BatteryInstalled = false, so only presence and external power are emitted there.
final class BatteryCollector: Collector {
    let name = "battery"

    func collect() throws -> [MetricFamily] {
        let services = IORegistry.services(matching: "AppleSmartBattery")
        defer { IORegistry.release(services) }

        var families: [MetricFamily] = []
        func gauge(_ name: String, _ help: String, _ value: Double?) {
            guard let value else { return }
            families.append(MetricFamily(name: name, help: help, type: .gauge, value: value))
        }

        guard let battery = services.first else {
            gauge("macos_battery_present", "Whether a battery is installed.", 0)
            return families
        }
        let props = IORegistry.properties(of: battery)
        let installed = IORegistry.bool(props["BatteryInstalled"]) ?? false
        gauge("macos_battery_present", "Whether a battery is installed.", installed ? 1 : 0)
        gauge("macos_battery_external_connected", "Whether external power is connected.",
              IORegistry.bool(props["ExternalConnected"]).map { $0 ? 1 : 0 })
        guard installed else { return families }

        let number = { (key: String) -> Double? in IORegistry.number(props[key]) }
        let flag = { (key: String) -> Double? in IORegistry.bool(props[key]).map { $0 ? 1 : 0 } }

        // Apple silicon reports CurrentCapacity/MaxCapacity as percentages and
        // the mAh figures under AppleRaw*; Intel reports mAh directly.
        let rawCurrent = number("AppleRawCurrentCapacity") ?? number("CurrentCapacity")
        let rawMax = number("AppleRawMaxCapacity") ?? number("MaxCapacity")
        let design = number("DesignCapacity")

        if let current = number("CurrentCapacity"), let max = number("MaxCapacity"), max > 0 {
            gauge("macos_battery_charge_ratio", "Battery charge as a fraction of current full capacity.", current / max)
        }
        gauge("macos_battery_current_capacity_mah", "Current charge in mAh.", rawCurrent)
        gauge("macos_battery_max_capacity_mah", "Current full-charge capacity in mAh.", rawMax)
        gauge("macos_battery_design_capacity_mah", "Design capacity in mAh.", design)
        if let rawMax, let design, design > 0 {
            gauge("macos_battery_health_ratio", "Full-charge capacity as a fraction of design capacity.", rawMax / design)
        }
        gauge("macos_battery_cycle_count", "Charge cycles.", number("CycleCount"))
        gauge("macos_battery_charging", "Whether the battery is charging.", flag("IsCharging"))
        gauge("macos_battery_fully_charged", "Whether the battery is fully charged.", flag("FullyCharged"))
        gauge("macos_battery_temperature_celsius", "Battery temperature.", number("Temperature").map { $0 / 100 })
        gauge("macos_battery_voltage_volts", "Battery voltage.", number("Voltage").map { $0 / 1000 })
        gauge("macos_battery_current_amperes", "Battery current; negative while discharging.",
              (number("InstantAmperage") ?? number("Amperage")).map { $0 / 1000 })

        func minutes(_ key: String) -> Double? {
            guard let m = number(key), m >= 0, m < 65535 else { return nil }
            return m * 60
        }
        gauge("macos_battery_time_remaining_seconds", "Estimated time until empty or full, whichever applies.", minutes("TimeRemaining"))
        gauge("macos_battery_time_to_empty_seconds", "Estimated time until empty.", minutes("AvgTimeToEmpty"))
        gauge("macos_battery_time_to_full_seconds", "Estimated time until full.", minutes("AvgTimeToFull"))
        return families
    }
}
