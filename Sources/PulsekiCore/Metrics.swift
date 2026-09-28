import Foundation

public enum MetricType: String {
    case counter, gauge, untyped
}

public struct Sample {
    public var labels: [(name: String, value: String)]
    public var value: Double

    public init(_ value: Double, labels: [(String, String)] = []) {
        self.value = value
        self.labels = labels.map { (name: $0.0, value: $0.1) }
    }
}

public struct MetricFamily {
    public let name: String
    public let help: String
    public let type: MetricType
    public var samples: [Sample]

    public init(name: String, help: String, type: MetricType, samples: [Sample] = []) {
        self.name = name
        self.help = help
        self.type = type
        self.samples = samples
    }

    public init(name: String, help: String, type: MetricType, value: Double, labels: [(String, String)] = []) {
        self.init(name: name, help: help, type: type, samples: [Sample(value, labels: labels)])
    }

    public mutating func add(_ value: Double, _ labels: [(String, String)] = []) {
        samples.append(Sample(value, labels: labels))
    }
}

/// Prometheus text exposition format 0.0.4.
public enum Exposition {
    public static let contentType = "text/plain; version=0.0.4; charset=utf-8"

    public static func render(_ families: [MetricFamily]) -> String {
        var out = ""
        render(families, into: &out)
        return out
    }

    public static func render(_ families: [MetricFamily], into out: inout String) {
        for family in families where !family.samples.isEmpty {
            out += "# HELP \(family.name) \(escapeHelp(family.help))\n"
            out += "# TYPE \(family.name) \(family.type.rawValue)\n"
            for sample in family.samples {
                out += family.name
                if !sample.labels.isEmpty {
                    out += "{"
                    for (i, label) in sample.labels.enumerated() {
                        if i > 0 { out += "," }
                        out += label.name
                        out += "=\""
                        out += escapeLabelValue(label.value)
                        out += "\""
                    }
                    out += "}"
                }
                out += " "
                out += formatValue(sample.value)
                out += "\n"
            }
        }
    }

    public static func formatValue(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "+Inf" : "-Inf" }
        // Integral values print without a fractional part or exponent so that
        // byte counters stay readable.
        if value == value.rounded(.towardZero), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(value)
    }

    public static func escapeLabelValue(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    public static func escapeHelp(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
