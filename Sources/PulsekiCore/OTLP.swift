import Foundation
import zlib

/// Encodes metric families as an OTLP/HTTP JSON ExportMetricsServiceRequest.
/// Gauges map to OTLP gauges; counters map to cumulative monotonic sums.
/// Metric names are sent unchanged and without units, so a Prometheus-
/// compatible receiver (Grafana Cloud, Mimir, the OTel collector's Prometheus
/// exporter) keeps the exact `node_*` / `macos_*` names served on /metrics.
public enum OTLP {
    public struct Resource {
        public var job: String
        public var instance: String
        public var extra: [(String, String)]

        public init(job: String, instance: String, extra: [(String, String)] = []) {
            self.job = job
            self.instance = instance
            self.extra = extra
        }
    }

    public static func encode(_ families: [MetricFamily], resource: Resource,
                              timeNanos: UInt64, startNanos: UInt64) -> Data {
        var out = ""
        out.reserveCapacity(256 * 1024)
        out += #"{"resourceMetrics":[{"resource":{"attributes":["#
        var attributes = [("service.name", resource.job), ("service.instance.id", resource.instance),
                          ("host.name", resource.instance), ("os.type", "darwin")]
        attributes += resource.extra
        appendAttributes(attributes, into: &out)
        out += #"]},"scopeMetrics":[{"scope":{"name":"pulseki","version":"\#(Version.string)"},"metrics":["#

        var firstMetric = true
        for family in families where !family.samples.isEmpty {
            let points = family.samples.filter { $0.value.isFinite }
            if points.isEmpty { continue }
            if !firstMetric { out += "," }
            firstMetric = false
            out += #"{"name":""#
            out += escape(family.name)
            out += #"","description":""#
            out += escape(family.help)
            out += "\","
            let isSum = family.type == .counter
            out += isSum ? #""sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":["# : #""gauge":{"dataPoints":["#
            for (i, sample) in points.enumerated() {
                if i > 0 { out += "," }
                out += "{"
                if isSum { out += #""startTimeUnixNano":"\#(startNanos)","# }
                out += #""timeUnixNano":"\#(timeNanos)","asDouble":\#(Exposition.formatValue(sample.value))"#
                if !sample.labels.isEmpty {
                    out += #","attributes":["#
                    appendAttributes(sample.labels.map { ($0.name, $0.value) }, into: &out)
                    out += "]"
                }
                out += "}"
            }
            out += "]}}"
        }
        out += "]}]}]}"
        return Data(out.utf8)
    }

    private static func appendAttributes(_ attributes: [(String, String)], into out: inout String) {
        for (i, attribute) in attributes.enumerated() {
            if i > 0 { out += "," }
            out += #"{"key":""#
            out += escape(attribute.0)
            out += #"","value":{"stringValue":""#
            out += escape(attribute.1)
            out += #""}}"#
        }
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

public enum Gzip {
    public struct Error: Swift.Error, CustomStringConvertible {
        public let description: String
    }

    public static func compress(_ input: Data) throws -> Data {
        var stream = z_stream()
        var rc = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                               ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw Error(description: "deflateInit2 failed: \(rc)") }
        defer { deflateEnd(&stream) }

        var output = Data(count: Int(deflateBound(&stream, uLong(input.count))))
        let produced: Int = try input.withUnsafeBytes { (inRaw: UnsafeRawBufferPointer) in
            try output.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(mutating: inRaw.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = outRaw.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outRaw.count)
                rc = deflate(&stream, Z_FINISH)
                guard rc == Z_STREAM_END else { throw Error(description: "deflate failed: \(rc)") }
                return Int(stream.total_out)
            }
        }
        output.count = produced
        return output
    }
}
