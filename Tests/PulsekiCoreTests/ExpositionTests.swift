import XCTest
@testable import PulsekiCore

final class ExpositionTests: XCTestCase {
    func testFormatValueIntegers() {
        XCTAssertEqual(Exposition.formatValue(0), "0")
        XCTAssertEqual(Exposition.formatValue(1), "1")
        XCTAssertEqual(Exposition.formatValue(-3), "-3")
        XCTAssertEqual(Exposition.formatValue(7_119_838_023_680), "7119838023680")
        XCTAssertEqual(Exposition.formatValue(1e15), "1000000000000000")
    }

    func testFormatValueFractionsAndSpecials() {
        XCTAssertEqual(Exposition.formatValue(1.5), "1.5")
        XCTAssertEqual(Exposition.formatValue(0.1), "0.1")
        XCTAssertEqual(Exposition.formatValue(1e20), "1e+20")
        XCTAssertEqual(Exposition.formatValue(.nan), "NaN")
        XCTAssertEqual(Exposition.formatValue(.infinity), "+Inf")
        XCTAssertEqual(Exposition.formatValue(-.infinity), "-Inf")
    }

    func testLabelEscaping() {
        XCTAssertEqual(Exposition.escapeLabelValue(#"a"b"#), #"a\"b"#)
        XCTAssertEqual(Exposition.escapeLabelValue(#"C:\path"#), #"C:\\path"#)
        XCTAssertEqual(Exposition.escapeLabelValue("line\nbreak"), #"line\nbreak"#)
        XCTAssertEqual(Exposition.escapeLabelValue("Macintosh HD — Données"), "Macintosh HD — Données")
    }

    func testHelpEscaping() {
        XCTAssertEqual(Exposition.escapeHelp(#"keep "quotes" \ escape"#), #"keep "quotes" \\ escape"#)
        XCTAssertEqual(Exposition.escapeHelp("two\nlines"), #"two\nlines"#)
    }

    func testRenderFamily() {
        var family = MetricFamily(name: "node_cpu_seconds_total", help: "Seconds the CPUs spent in each mode.", type: .counter)
        family.add(12.5, [("cpu", "0"), ("mode", "user")])
        family.add(3, [("cpu", "0"), ("mode", "idle")])
        let plain = MetricFamily(name: "node_load1", help: "1m load average.", type: .gauge, value: 0.25)
        let expected = """
        # HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
        # TYPE node_cpu_seconds_total counter
        node_cpu_seconds_total{cpu="0",mode="user"} 12.5
        node_cpu_seconds_total{cpu="0",mode="idle"} 3
        # HELP node_load1 1m load average.
        # TYPE node_load1 gauge
        node_load1 0.25

        """
        XCTAssertEqual(Exposition.render([family, plain]), expected)
    }

    func testEmptyFamilyIsOmitted() {
        let empty = MetricFamily(name: "macos_smc_fan_speed_rpm", help: "Current fan speed.", type: .gauge)
        XCTAssertEqual(Exposition.render([empty]), "")
    }

    func testFailingCollectorLeavesNoPartialOutput() {
        final class Broken: Collector {
            let name = "broken"
            func collect() throws -> [MetricFamily] { throw CollectorError("boom") }
        }
        final class Fine: Collector {
            let name = "fine"
            func collect() throws -> [MetricFamily] { [MetricFamily(name: "fine_metric", help: "ok", type: .gauge, value: 1)] }
        }
        let text = Registry(collectors: [Broken(), Fine()]).scrape()
        XCTAssertTrue(text.contains("fine_metric 1\n"))
        XCTAssertTrue(text.contains(#"pulseki_scrape_collector_success{collector="broken"} 0"#))
        XCTAssertTrue(text.contains(#"pulseki_scrape_collector_success{collector="fine"} 1"#))
        XCTAssertTrue(text.contains("process_resident_memory_bytes "))
        XCTAssertFalse(text.contains("broken_"))
    }
}

final class SMCDecodeTests: XCTestCase {
    func testDecodeTypes() {
        XCTAssertEqual(SMCClient.decode(type: "flt ", bytes: [0x00, 0x00, 0x48, 0x42]), 50.0)
        XCTAssertEqual(SMCClient.decode(type: "ui8 ", bytes: [7]), 7)
        XCTAssertEqual(SMCClient.decode(type: "ui16", bytes: [0x01, 0x02]), 258)
        XCTAssertEqual(SMCClient.decode(type: "ui32", bytes: [0, 0, 0x05, 0x5F]), 1375)
        XCTAssertEqual(SMCClient.decode(type: "si16", bytes: [0xFF, 0xFE]), -2)
        XCTAssertEqual(SMCClient.decode(type: "sp78", bytes: [0x2A, 0x80]), 42.5)
        XCTAssertEqual(SMCClient.decode(type: "fpe2", bytes: [0x0F, 0xA0]), 1000)
        XCTAssertEqual(SMCClient.decode(type: "flag", bytes: [1]), 1)
        XCTAssertNil(SMCClient.decode(type: "hex_", bytes: [1, 2]))
        XCTAssertNil(SMCClient.decode(type: "flt ", bytes: [1, 2]))
    }

    func testFourCC() {
        XCTAssertEqual(SMCClient.fourcc("#KEY"), 0x234B4559)
        XCTAssertEqual(SMCClient.string(fourcc: 0x234B4559), "#KEY")
        XCTAssertEqual(SMCClient.string(fourcc: SMCClient.fourcc("flt ")), "flt ")
    }
}
