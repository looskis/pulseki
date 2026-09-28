import XCTest
@testable import PulsekiCore

final class OTLPTests: XCTestCase {
    private func families() -> [MetricFamily] {
        var cpu = MetricFamily(name: "node_cpu_seconds_total", help: "Seconds the CPUs spent in each mode.", type: .counter)
        cpu.add(12.5, [("cpu", "0"), ("mode", "user")])
        cpu.add(3, [("cpu", "0"), ("mode", "idle")])
        let load = MetricFamily(name: "node_load1", help: "1m \"load\" average.", type: .gauge, value: 0.25)
        var skipped = MetricFamily(name: "process_max_fds", help: "inf", type: .gauge)
        skipped.add(.infinity)
        let empty = MetricFamily(name: "macos_smc_fan_speed_rpm", help: "none", type: .gauge)
        return [cpu, load, skipped, empty]
    }

    func testEncodesGaugesAndCumulativeSums() throws {
        let data = OTLP.encode(families(), resource: OTLP.Resource(job: "macos", instance: "mini", extra: [("env", "lab")]),
                               timeNanos: 1_790_000_000_000_000_000, startNanos: 1_780_000_000_000_000_000)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rm = try XCTUnwrap((root["resourceMetrics"] as? [[String: Any]])?.first)
        let attrs = try XCTUnwrap((rm["resource"] as? [String: Any])?["attributes"] as? [[String: Any]])
        var attrMap: [String: String] = [:]
        for attribute in attrs {
            attrMap[attribute["key"] as! String] = (attribute["value"] as! [String: Any])["stringValue"] as? String
        }
        XCTAssertEqual(attrMap["service.name"], "macos")
        XCTAssertEqual(attrMap["service.instance.id"], "mini")
        XCTAssertEqual(attrMap["env"], "lab")

        let sm = try XCTUnwrap((rm["scopeMetrics"] as? [[String: Any]])?.first)
        XCTAssertEqual(((sm["scope"] as? [String: Any])?["name"] as? String), "pulseki")
        let metrics = try XCTUnwrap(sm["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.map { $0["name"] as? String }, ["node_cpu_seconds_total", "node_load1"],
                       "non-finite and empty families are dropped")

        let sum = try XCTUnwrap(metrics[0]["sum"] as? [String: Any])
        XCTAssertEqual(sum["aggregationTemporality"] as? Int, 2)
        XCTAssertEqual(sum["isMonotonic"] as? Bool, true)
        let points = try XCTUnwrap(sum["dataPoints"] as? [[String: Any]])
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0]["asDouble"] as? Double, 12.5)
        XCTAssertEqual(points[0]["startTimeUnixNano"] as? String, "1780000000000000000")
        XCTAssertEqual(points[0]["timeUnixNano"] as? String, "1790000000000000000")
        let labels = try XCTUnwrap(points[0]["attributes"] as? [[String: Any]])
        XCTAssertEqual(labels.map { $0["key"] as? String }, ["cpu", "mode"])

        let gauge = try XCTUnwrap(metrics[1]["gauge"] as? [String: Any])
        let gp = try XCTUnwrap((gauge["dataPoints"] as? [[String: Any]])?.first)
        XCTAssertEqual(gp["asDouble"] as? Double, 0.25)
        XCTAssertNil(gp["startTimeUnixNano"])
        XCTAssertNil(gp["attributes"])
        XCTAssertEqual(metrics[1]["description"] as? String, "1m \"load\" average.")
    }

    func testEscape() {
        XCTAssertEqual(OTLP.escape("a\"b\\c\nd"), #"a\"b\\c\nd"#)
        XCTAssertEqual(OTLP.escape("tab\there"), #"tab\there"#)
        XCTAssertEqual(OTLP.escape("bell" + String(UnicodeScalar(7))), "bell\\u0007")
    }

    func testGzipRoundTrip() throws {
        let input = Data(String(repeating: "pulseki metrics ", count: 1000).utf8)
        let compressed = try Gzip.compress(input)
        XCTAssertLessThan(compressed.count, input.count / 10)
        XCTAssertEqual(compressed.prefix(2), Data([0x1f, 0x8b]), "gzip magic")
        // Round-trip through the system gunzip to prove the container is valid.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pulseki-\(UUID().uuidString).gz")
        try compressed.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(output, input)
    }
}
