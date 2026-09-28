import Foundation

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct Config: Equatable {
    public var listen = "0.0.0.0:9101"
    public var path = "/metrics"
    public var disabledCollectors: Set<String> = []
    public var filesystemMountPointsExclude = "^/(dev|System/Volumes/(VM|Preboot|Update|xarts|iSCPreboot|Hardware))($|/)"
    public var filesystemFSTypesExclude = "^(autofs|devfs|nullfs|lifs|synthfs)$"
    public var networkDeviceExclude = "^(gif|stf|anpi|ap|llw|awdl|pktap|XHC)[0-9]*$"
    public var smcKeyInclude = ""
    public var pushURL = ""
    public var pushUsername = ""
    public var pushPassword = ""
    public var pushPasswordFile = ""
    public var pushInterval = 15.0
    public var pushTimeout = 10.0
    public var pushJob = "macos"
    public var pushInstance = ""

    public init() {}

    /// Option keys as they appear in the config file and (with `--`) on the command line.
    public static let keys = [
        "listen", "path", "disable",
        "filesystem.mount-points-exclude", "filesystem.fs-types-exclude", "network.device-exclude",
        "smc.key-include",
        "push.url", "push.username", "push.password", "push.password-file",
        "push.interval", "push.timeout", "push.job", "push.instance",
    ]
}

public enum CLIAction: Equatable {
    case run(Config)
    case listCollectors
    case version
    case help
    case smcDump
}

public enum CLI {
    public static let usage = """
    pulseki \(Version.string) - Prometheus exporter for macOS system metrics

    USAGE:
      pulseki [OPTIONS]
      pulseki smc-dump

    OPTIONS:
      --listen ADDR                          Address to listen on (default: 0.0.0.0:9101)
      --path PATH                            URL path that serves metrics (default: /metrics)
      --config FILE                          Read "key = value" options from FILE; keys are the
                                             option names below without the leading "--"
      --disable NAMES                        Comma-separated list of collectors to disable
      --filesystem.mount-points-exclude RE   Regex of mount points to skip
      --filesystem.fs-types-exclude RE       Regex of filesystem types to skip
      --network.device-exclude RE            Regex of network interfaces to skip
      --smc.key-include RE                   Regex of SMC temperature and power keys to expose
                                             (default: all plausible keys)
      --push.url URL                         OTLP/HTTP metrics endpoint to push to, e.g. Grafana
                                             Cloud's https://otlp-gateway-<region>.grafana.net/otlp/v1/metrics
      --push.username USER                   Basic-auth user (Grafana Cloud: the numeric instance ID)
      --push.password-file FILE              File containing the basic-auth password or API token
      --push.password SECRET                 The password itself; prefer the file or config file,
                                             since command-line arguments are visible to every user
      --push.interval SECONDS                Seconds between pushes (default: 15)
      --push.timeout SECONDS                 HTTP timeout per push (default: 10)
      --push.job NAME                        Value of the job label / service.name (default: macos)
      --push.instance NAME                   Value of the instance label (default: this Mac's hostname)
      --collectors                           List collector names and exit
      --version                              Print the version and exit
      -h, --help                             Print this help and exit

    COMMANDS:
      smc-dump                               Print every SMC key with its type and decoded value

    Command-line options override the config file. Regex options accept ICU
    syntax; an empty string disables the filter.
    """

    public static func parse(_ arguments: [String], collectorNames: [String]) throws -> CLIAction {
        var config = Config()

        if arguments.first == "smc-dump" {
            guard arguments.count == 1 else { throw ConfigError("smc-dump takes no arguments") }
            return .smcDump
        }

        // Config file first, so that flags override it regardless of order.
        var pairs: [(key: String, value: String?)] = []
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            guard arg.hasPrefix("-") else { throw ConfigError("unexpected argument '\(arg)'") }
            var key = String(arg.drop(while: { $0 == "-" }))
            var value: String?
            if let eq = key.firstIndex(of: "=") {
                value = String(key[key.index(after: eq)...])
                key = String(key[..<eq])
            }
            pairs.append((key, value))
            if value == nil, Config.keys.contains(key) || key == "config" {
                guard index < arguments.count else { throw ConfigError("--\(key) requires a value") }
                pairs[pairs.count - 1].value = arguments[index]
                index += 1
            }
        }

        for pair in pairs where pair.key == "config" {
            try loadFile(pair.value ?? "", into: &config, collectorNames: collectorNames)
        }

        for pair in pairs {
            switch pair.key {
            case "config": continue
            case "h", "help": return .help
            case "version": return .version
            case "collectors": return .listCollectors
            default:
                guard let value = pair.value else { throw ConfigError("unknown option '--\(pair.key)'") }
                try apply(key: pair.key, value: value, to: &config, collectorNames: collectorNames)
            }
        }

        try validate(config)
        return .run(config)
    }

    static func loadFile(_ path: String, into config: inout Config, collectorNames: [String]) throws {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ConfigError("cannot read config file '\(path)'")
        }
        let text = String(decoding: data, as: UTF8.self)
        for (lineNumber, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                throw ConfigError("\(path):\(lineNumber + 1): expected 'key = value'")
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            do {
                try apply(key: key, value: value, to: &config, collectorNames: collectorNames)
            } catch let error as ConfigError {
                throw ConfigError("\(path):\(lineNumber + 1): \(error.description)")
            }
        }
    }

    static func apply(key: String, value: String, to config: inout Config, collectorNames: [String]) throws {
        switch key {
        case "listen":
            config.listen = value
        case "path":
            guard value.hasPrefix("/") else { throw ConfigError("path must start with '/'") }
            config.path = value
        case "disable":
            let names = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for name in names where !collectorNames.contains(name) {
                throw ConfigError("unknown collector '\(name)' (available: \(collectorNames.joined(separator: ", ")))")
            }
            config.disabledCollectors = Set(names)
        case "filesystem.mount-points-exclude":
            try checkRegex(value, key)
            config.filesystemMountPointsExclude = value
        case "filesystem.fs-types-exclude":
            try checkRegex(value, key)
            config.filesystemFSTypesExclude = value
        case "network.device-exclude":
            try checkRegex(value, key)
            config.networkDeviceExclude = value
        case "smc.key-include":
            try checkRegex(value, key)
            config.smcKeyInclude = value
        case "push.url":
            if !value.isEmpty {
                guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", url.host != nil else {
                    throw ConfigError("push.url must be an http(s) URL")
                }
            }
            config.pushURL = value
        case "push.username": config.pushUsername = value
        case "push.password": config.pushPassword = value
        case "push.password-file": config.pushPasswordFile = value
        case "push.interval":
            guard let seconds = Double(value), seconds >= 1 else { throw ConfigError("push.interval must be at least 1 second") }
            config.pushInterval = seconds
        case "push.timeout":
            guard let seconds = Double(value), seconds >= 1 else { throw ConfigError("push.timeout must be at least 1 second") }
            config.pushTimeout = seconds
        case "push.job":
            guard !value.isEmpty else { throw ConfigError("push.job must not be empty") }
            config.pushJob = value
        case "push.instance": config.pushInstance = value
        default:
            throw ConfigError("unknown option '\(key)'")
        }
    }

    private static func checkRegex(_ pattern: String, _ key: String) throws {
        guard !pattern.isEmpty else { return }
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            throw ConfigError("invalid regex for \(key): '\(pattern)'")
        }
    }

    private static func validate(_ config: Config) throws {
        _ = try ListenAddress.parse(config.listen)
        if !config.pushPassword.isEmpty, !config.pushPasswordFile.isEmpty {
            throw ConfigError("set push.password or push.password-file, not both")
        }
    }

    /// Resolves push settings, reading the password file if configured.
    /// Returns nil when pushing is not enabled.
    public static func pushSettings(from config: Config) throws -> Pusher.Settings? {
        guard !config.pushURL.isEmpty, let url = URL(string: config.pushURL) else { return nil }
        var password = config.pushPassword
        if !config.pushPasswordFile.isEmpty {
            guard let data = FileManager.default.contents(atPath: config.pushPasswordFile) else {
                throw ConfigError("cannot read push.password-file '\(config.pushPasswordFile)'")
            }
            password = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var instance = config.pushInstance
        if instance.isEmpty {
            var uts = utsname()
            uname(&uts)
            instance = cString(uts.nodename)
            if instance.hasSuffix(".local") { instance.removeLast(".local".count) }
        }
        return Pusher.Settings(
            url: url, username: config.pushUsername, password: password,
            interval: config.pushInterval, timeout: config.pushTimeout,
            resource: OTLP.Resource(job: config.pushJob, instance: instance))
    }
}

/// Compiled optional regex; an empty pattern matches nothing.
struct Matcher {
    private let regex: NSRegularExpression?

    init(_ pattern: String) throws {
        regex = pattern.isEmpty ? nil : try NSRegularExpression(pattern: pattern)
    }

    func matches(_ s: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
