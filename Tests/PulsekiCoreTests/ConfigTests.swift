import XCTest
@testable import PulsekiCore

final class ConfigTests: XCTestCase {
    private let collectors = CollectorFactory.names

    func testDefaults() throws {
        guard case .run(let config) = try CLI.parse([], collectorNames: collectors) else { return XCTFail("expected run") }
        XCTAssertEqual(config, Config())
        XCTAssertEqual(config.listen, "0.0.0.0:9101")
        XCTAssertEqual(config.path, "/metrics")
    }

    func testFlagsWithSpaceAndEquals() throws {
        let action = try CLI.parse(
            ["--listen", "127.0.0.1:9200", "--path=/m", "--disable", "smc, battery", "--network.device-exclude=^utun", "--smc.key-include", "^(TCMb|PSTR)$"],
            collectorNames: collectors)
        guard case .run(let config) = action else { return XCTFail("expected run") }
        XCTAssertEqual(config.listen, "127.0.0.1:9200")
        XCTAssertEqual(config.path, "/m")
        XCTAssertEqual(config.disabledCollectors, ["smc", "battery"])
        XCTAssertEqual(config.networkDeviceExclude, "^utun")
        XCTAssertEqual(config.smcKeyInclude, "^(TCMb|PSTR)$")
    }

    func testInformationalFlags() throws {
        XCTAssertEqual(try CLI.parse(["--help"], collectorNames: collectors), .help)
        XCTAssertEqual(try CLI.parse(["-h"], collectorNames: collectors), .help)
        XCTAssertEqual(try CLI.parse(["--version"], collectorNames: collectors), .version)
        XCTAssertEqual(try CLI.parse(["--collectors"], collectorNames: collectors), .listCollectors)
        XCTAssertEqual(try CLI.parse(["smc-dump"], collectorNames: collectors), .smcDump)
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try CLI.parse(["--disable", "nope"], collectorNames: collectors))
        XCTAssertThrowsError(try CLI.parse(["--bogus"], collectorNames: collectors))
        XCTAssertThrowsError(try CLI.parse(["--listen"], collectorNames: collectors))
        XCTAssertThrowsError(try CLI.parse(["--listen", "nowhere"], collectorNames: collectors))
        XCTAssertThrowsError(try CLI.parse(["--path", "metrics"], collectorNames: collectors))
        XCTAssertThrowsError(try CLI.parse(["--network.device-exclude", "("], collectorNames: collectors))
        XCTAssertThrowsError(try CLI.parse(["positional"], collectorNames: collectors))
    }

    func testConfigFileAndFlagPrecedence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulseki-test-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        # comment
        listen = 127.0.0.1:9101

        disable = gpu
        filesystem.fs-types-exclude =
        """.write(to: url, atomically: true, encoding: .utf8)

        let fromFile = try CLI.parse(["--config", url.path], collectorNames: collectors)
        guard case .run(let config) = fromFile else { return XCTFail("expected run") }
        XCTAssertEqual(config.listen, "127.0.0.1:9101")
        XCTAssertEqual(config.disabledCollectors, ["gpu"])
        XCTAssertEqual(config.filesystemFSTypesExclude, "")

        let overridden = try CLI.parse(["--listen", ":9300", "--config", url.path], collectorNames: collectors)
        guard case .run(let config2) = overridden else { return XCTFail("expected run") }
        XCTAssertEqual(config2.listen, ":9300", "flags win regardless of position")
        XCTAssertEqual(config2.disabledCollectors, ["gpu"])

        XCTAssertThrowsError(try CLI.parse(["--config", url.path + ".missing"], collectorNames: collectors))
    }

    func testPushOptions() throws {
        let action = try CLI.parse(
            ["--push.url", "https://otlp-gateway-prod-us-west-0.grafana.net/otlp/v1/metrics",
             "--push.username=123456", "--push.password-file", "/nonexistent/token", "--push.interval", "30",
             "--push.job", "fleet", "--push.instance", "mini"],
            collectorNames: collectors)
        guard case .run(let config) = action else { return XCTFail("expected run") }
        XCTAssertEqual(config.pushUsername, "123456")
        XCTAssertEqual(config.pushInterval, 30)
        XCTAssertEqual(config.pushJob, "fleet")
        XCTAssertThrowsError(try CLI.pushSettings(from: config), "missing password file is an error")

        XCTAssertNil(try CLI.pushSettings(from: Config()), "push is off by default")

        var inline = Config()
        inline.pushURL = "http://127.0.0.1:4318/v1/metrics"
        inline.pushPassword = "secret"
        let settings = try XCTUnwrap(try CLI.pushSettings(from: inline))
        XCTAssertEqual(settings.password, "secret")
        XCTAssertEqual(settings.resource.job, "macos")
        XCTAssertFalse(settings.resource.instance.isEmpty)
        XCTAssertFalse(settings.resource.instance.hasSuffix(".local"))

        XCTAssertThrowsError(try CLI.parse(["--push.url", "ftp://x"], collectorNames: collectors))
        XCTAssertThrowsError(try CLI.parse(["--push.url", "not a url"], collectorNames: collectors))
        XCTAssertThrowsError(try CLI.parse(["--push.interval", "0"], collectorNames: collectors))
        XCTAssertThrowsError(try CLI.parse(["--push.password", "a", "--push.password-file", "b"], collectorNames: collectors))
    }

    func testListenAddressParsing() throws {
        XCTAssertEqual(try ListenAddress.parse("0.0.0.0:9101").description, "0.0.0.0:9101")
        XCTAssertEqual(try ListenAddress.parse(":9101").description, "0.0.0.0:9101")
        XCTAssertEqual(try ListenAddress.parse("9101").description, "0.0.0.0:9101")
        XCTAssertEqual(try ListenAddress.parse("[::1]:80").description, "[::1]:80")
        XCTAssertEqual(try ListenAddress.parse("localhost:1").host, "localhost")
        XCTAssertThrowsError(try ListenAddress.parse("host:0"))
        XCTAssertThrowsError(try ListenAddress.parse("host:port"))
        XCTAssertThrowsError(try ListenAddress.parse("[::1]"))
    }

    func testMatcher() throws {
        let m = try Matcher(Config().filesystemMountPointsExclude)
        XCTAssertTrue(m.matches("/dev"))
        XCTAssertTrue(m.matches("/System/Volumes/VM"))
        XCTAssertTrue(m.matches("/System/Volumes/Preboot/Cryptexes"))
        XCTAssertFalse(m.matches("/"))
        XCTAssertFalse(m.matches("/System/Volumes/Data"))
        XCTAssertFalse(m.matches("/Volumes/Backup"))
        XCTAssertFalse(try Matcher("").matches("anything"))
    }
}
