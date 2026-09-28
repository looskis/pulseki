import Foundation

final class ThermalCollector: Collector {
    let name = "thermal"

    func collect() throws -> [MetricFamily] {
        let state = ProcessInfo.processInfo.thermalState.rawValue
        return [MetricFamily(
            name: "macos_thermal_state",
            help: "System thermal state: 0 nominal, 1 fair, 2 serious, 3 critical.",
            type: .gauge, value: Double(state))]
    }
}
