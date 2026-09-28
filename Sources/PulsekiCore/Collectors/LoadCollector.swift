import Darwin
import Foundation

final class LoadCollector: Collector {
    let name = "load"

    func collect() throws -> [MetricFamily] {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else {
            throw CollectorError("getloadavg failed")
        }
        return [
            MetricFamily(name: "node_load1", help: "1m load average.", type: .gauge, value: loads[0]),
            MetricFamily(name: "node_load5", help: "5m load average.", type: .gauge, value: loads[1]),
            MetricFamily(name: "node_load15", help: "15m load average.", type: .gauge, value: loads[2]),
        ]
    }
}
