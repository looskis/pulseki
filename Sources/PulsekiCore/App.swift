import Darwin
import Foundation

public enum App {
    private static var signalSources: [DispatchSourceSignal] = []

    public static func main(_ arguments: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)

        let action: CLIAction
        do {
            action = try CLI.parse(Array(arguments.dropFirst()), collectorNames: CollectorFactory.names)
        } catch {
            FileHandle.standardError.write(Data("pulseki: \(error)\nRun 'pulseki --help' for usage.\n".utf8))
            return 2
        }

        switch action {
        case .help:
            print(CLI.usage)
            return 0
        case .version:
            print("pulseki \(Version.string)")
            return 0
        case .listCollectors:
            for name in CollectorFactory.names { print(name) }
            return 0
        case .smcDump:
            return SMCDump.run()
        case .run(let config):
            return serve(config)
        }
    }

    private static func serve(_ config: Config) -> Int32 {
        let address: ListenAddress
        do {
            address = try ListenAddress.parse(config.listen)
        } catch {
            Log.error("\(error)")
            return 2
        }

        let registry = Registry(collectors: CollectorFactory.make(config))
        var pusher: Pusher?
        do {
            if let settings = try CLI.pushSettings(from: config) {
                let p = Pusher(settings: settings, registry: registry)
                registry.extraProviders.append { p.metrics() }
                pusher = p
            }
        } catch {
            Log.error("\(error)")
            return 2
        }
        let metricsPath = config.path
        let landing = """
        <!doctype html><html><head><title>pulseki</title></head>
        <body><h1>pulseki \(Version.string)</h1><p><a href="\(metricsPath)">Metrics</a></p></body></html>

        """

        let server = HTTPServer(address: address) { request in
            switch (request.method, request.path) {
            case ("GET", metricsPath), ("HEAD", metricsPath):
                return HTTPResponse(contentType: Exposition.contentType, body: registry.scrape())
            case ("GET", "/"), ("HEAD", "/"):
                return HTTPResponse(contentType: "text/html; charset=utf-8", body: landing)
            case ("GET", "/-/healthy"), ("HEAD", "/-/healthy"):
                return HTTPResponse(body: "OK\n")
            case ("GET", _), ("HEAD", _):
                return HTTPResponse(status: 404, body: "not found\n")
            default:
                return HTTPResponse(status: 405, body: "method not allowed\n")
            }
        }

        do {
            try server.start()
        } catch {
            Log.error("\(error)")
            return 1
        }
        Log.info("pulseki \(Version.string) listening on http://\(address)\(metricsPath) collectors=\(registry.collectorNames.joined(separator: ","))")
        pusher?.start()

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Log.info("received \(sig == SIGTERM ? "SIGTERM" : "SIGINT"), shutting down")
                pusher?.stop()
                server.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        dispatchMain()
    }
}
