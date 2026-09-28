import Foundation

/// Temperatures, fans and power rails from the SMC. The key list is
/// enumerated once, on the first successful scrape, so that later scrapes
/// only read the keys that matter. Each SMC read is a kernel round trip of
/// roughly 150 µs, so `smc.key-include` exists to trim the list.
final class SMCCollector: Collector {
    let name = "smc"

    private struct Fan {
        let index: Int
        let actual: SMCClient.KeyInfo?
        let minimum: SMCClient.KeyInfo?
        let maximum: SMCClient.KeyInfo?
        let target: SMCClient.KeyInfo?
    }

    private let include: Matcher
    private let includeAll: Bool
    private var client: SMCClient?
    private var temperatureKeys: [SMCClient.KeyInfo] = []
    private var powerKeys: [SMCClient.KeyInfo] = []
    private var fans: [Fan] = []

    init(config: Config) throws {
        include = try Matcher(config.smcKeyInclude)
        includeAll = config.smcKeyInclude.isEmpty
    }

    func collect() throws -> [MetricFamily] {
        let client = try ensureClient()

        var temperature = MetricFamily(
            name: "macos_smc_temperature_celsius",
            help: "SMC temperature sensor reading. Use 'pulseki smc-dump' to identify sensors.", type: .gauge)
        for key in temperatureKeys {
            guard let v = try? client.readDouble(key), v > -40, v < 150, v != 0 else { continue }
            temperature.add(round3(v), [("sensor", key.key)])
        }

        var power = MetricFamily(
            name: "macos_smc_power_watts",
            help: "SMC power rail reading in watts (PSTR is total system power on Apple silicon).", type: .gauge)
        for key in powerKeys {
            guard let v = try? client.readDouble(key), v.isFinite, v >= 0, v < 10_000 else { continue }
            power.add(round3(v), [("key", key.key)])
        }

        var fanCount = MetricFamily(name: "macos_smc_fans", help: "Number of fans reported by the SMC.", type: .gauge)
        fanCount.add(Double(fans.count))
        var fanSpeed = MetricFamily(name: "macos_smc_fan_speed_rpm", help: "Current fan speed.", type: .gauge)
        var fanMin = MetricFamily(name: "macos_smc_fan_min_rpm", help: "Minimum fan speed.", type: .gauge)
        var fanMax = MetricFamily(name: "macos_smc_fan_max_rpm", help: "Maximum fan speed.", type: .gauge)
        var fanTarget = MetricFamily(name: "macos_smc_fan_target_rpm", help: "Target fan speed.", type: .gauge)
        for fan in fans {
            let labels = [("fan", String(fan.index))]
            func put(_ key: SMCClient.KeyInfo?, into family: inout MetricFamily) {
                guard let key, let v = try? client.readDouble(key), v.isFinite, v >= 0 else { return }
                family.add(round3(v), labels)
            }
            put(fan.actual, into: &fanSpeed)
            put(fan.minimum, into: &fanMin)
            put(fan.maximum, into: &fanMax)
            put(fan.target, into: &fanTarget)
        }

        return [temperature, power, fanCount, fanSpeed, fanMin, fanMax, fanTarget]
    }

    /// SMC floats are single precision; printing them as doubles adds noise digits.
    private func round3(_ v: Double) -> Double {
        (v * 1000).rounded() / 1000
    }

    private func ensureClient() throws -> SMCClient {
        if let client { return client }
        let client = try SMCClient()
        try probe(client)
        self.client = client
        return client
    }

    private func probe(_ client: SMCClient) throws {
        let keys = try client.allKeys()
        var byName: [String: SMCClient.KeyInfo] = [:]
        for key in keys { byName[key.key] = key }

        let isFloat: (SMCClient.KeyInfo) -> Bool = { ($0.type == "flt " && $0.size == 4) || $0.type == "sp78" }
        let wanted: (SMCClient.KeyInfo) -> Bool = { self.includeAll || self.include.matches($0.key) }

        temperatureKeys = keys.filter { key in
            guard key.key.hasPrefix("T"), isFloat(key), wanted(key) else { return false }
            guard let v = try? client.readDouble(key) else { return false }
            return v > -40 && v < 150 && v != 0
        }
        powerKeys = keys.filter { $0.key.hasPrefix("P") && isFloat($0) && wanted($0) }

        var count = 0
        if let fnum = byName["FNum"], let v = try? client.readDouble(fnum) { count = Int(v) }
        fans = (0..<min(count, 10)).map { i in
            Fan(index: i,
                actual: byName["F\(i)Ac"], minimum: byName["F\(i)Mn"],
                maximum: byName["F\(i)Mx"], target: byName["F\(i)Tg"])
        }
        Log.info("smc: \(keys.count) keys, \(temperatureKeys.count) temperature sensors, \(powerKeys.count) power keys, \(fans.count) fans")
    }
}
