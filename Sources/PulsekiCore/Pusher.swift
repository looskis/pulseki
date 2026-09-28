import Foundation

/// Pushes the registry's metrics to an OTLP/HTTP endpoint on a fixed
/// interval, for receivers that cannot scrape (Grafana Cloud, or any
/// OpenTelemetry collector). Runs alongside the /metrics listener.
public final class Pusher {
    public struct Settings {
        public var url: URL
        public var username: String
        public var password: String
        public var interval: TimeInterval
        public var timeout: TimeInterval
        public var resource: OTLP.Resource
    }

    private let settings: Settings
    private let registry: Registry
    private let queue = DispatchQueue(label: "pulseki.push", qos: .utility)
    private let session: URLSession
    private var timer: DispatchSourceTimer?
    private let startNanos = UInt64(Date().timeIntervalSince1970 * 1e9)

    // Self metrics, guarded by `lock`.
    private let lock = NSLock()
    private var successes = 0.0
    private var failures = 0.0
    private var bytesSent = 0.0
    private var lastSuccess = 0.0
    private var lastDuration = 0.0
    private var consecutiveFailures = 0

    public init(settings: Settings, registry: Registry) {
        self.settings = settings
        self.registry = registry
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = settings.timeout
        configuration.timeoutIntervalForResource = settings.timeout
        configuration.httpAdditionalHeaders = ["User-Agent": "pulseki/\(Version.string)"]
        session = URLSession(configuration: configuration)
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: settings.interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.pushOnce() }
        timer.resume()
        self.timer = timer
        Log.info("push: every \(Int(settings.interval))s to \(settings.url.absoluteString) as job=\(settings.resource.job) instance=\(settings.resource.instance)")
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One export. Public so tests and `--push-once` style tooling can drive it.
    @discardableResult
    public func pushOnce() -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        let families = registry.collectFamilies()
        let body = OTLP.encode(families, resource: settings.resource,
                               timeNanos: UInt64(Date().timeIntervalSince1970 * 1e9), startNanos: startNanos)
        let result = send(body)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9

        lock.lock()
        lastDuration = elapsed
        switch result {
        case .success(let bytes):
            successes += 1
            bytesSent += Double(bytes)
            lastSuccess = Date().timeIntervalSince1970
            if consecutiveFailures > 0 { Log.info("push: recovered after \(consecutiveFailures) failures") }
            consecutiveFailures = 0
        case .failure(let message):
            failures += 1
            consecutiveFailures += 1
            // Log the first failure, then every 20th, so a dead endpoint doesn't flood the log.
            if consecutiveFailures == 1 || consecutiveFailures % 20 == 0 {
                Log.error("push: \(message) (failure \(consecutiveFailures))")
            }
        }
        lock.unlock()
        if case .success = result { return true }
        return false
    }

    private enum SendResult {
        case success(bytes: Int)
        case failure(String)
    }

    private func send(_ body: Data) -> SendResult {
        var request = URLRequest(url: settings.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.username.isEmpty || !settings.password.isEmpty {
            let credentials = Data("\(settings.username):\(settings.password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try Gzip.compress(body)
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        } catch {
            request.httpBody = body
        }
        let sent = request.httpBody?.count ?? 0

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: SendResult = .failure("no response")
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure("\(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure("non-HTTP response")
                return
            }
            if (200..<300).contains(http.statusCode) {
                outcome = .success(bytes: sent)
            } else {
                let snippet = data.map { String(decoding: $0.prefix(300), as: UTF8.self) } ?? ""
                outcome = .failure("HTTP \(http.statusCode) \(snippet.replacingOccurrences(of: "\n", with: " "))")
            }
        }
        task.resume()
        if semaphore.wait(timeout: .now() + settings.timeout + 5) == .timedOut {
            task.cancel()
            return .failure("timed out after \(Int(settings.timeout))s")
        }
        return outcome
    }

    public func metrics() -> [MetricFamily] {
        lock.lock()
        defer { lock.unlock() }
        var pushes = MetricFamily(name: "pulseki_pushes_total", help: "OTLP pushes attempted, by result.", type: .counter)
        pushes.add(successes, [("result", "success")])
        pushes.add(failures, [("result", "failure")])
        return [
            pushes,
            MetricFamily(name: "pulseki_push_bytes_total", help: "Compressed bytes sent in successful pushes.", type: .counter, value: bytesSent),
            MetricFamily(name: "pulseki_push_last_success_timestamp_seconds", help: "Unix time of the last successful push, 0 if none.", type: .gauge, value: lastSuccess),
            MetricFamily(name: "pulseki_push_last_duration_seconds", help: "Wall time of the last push including collection.", type: .gauge, value: lastDuration),
            MetricFamily(name: "pulseki_push_consecutive_failures", help: "Failed pushes since the last success.", type: .gauge, value: Double(consecutiveFailures)),
        ]
    }
}
