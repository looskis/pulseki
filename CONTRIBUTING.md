# Contributing to pulseki

## Building

```bash
swift build
swift test
.build/debug/pulseki --listen 127.0.0.1:9101
```

macOS 13 or later with the Xcode Command Line Tools is all that is needed.

## Ground rules

- **No third-party dependencies.** The point of pulseki is a tiny binary that
  builds from source in a Homebrew tap with nothing but the system toolchain.
  Foundation, IOKit, Darwin and the system zlib are fine.
- **node_exporter names first.** If node_exporter has a metric with the same
  meaning, use its name and unit so existing dashboards work. Anything
  Mac-specific gets the `macos_` prefix. Follow the Prometheus naming rules:
  base units (bytes, seconds, celsius, ratio), `_total` on counters.
- **Collectors must be isolated.** Return every family or throw; never render
  partial output. Read static data (topology, model, key lists) once in `init`
  and only touch what changes on each scrape.
- **Measure.** A change to a collector's data source should come with the
  cross-check you used (`vm_stat`, `netstat -ib`, `ioreg`, `df`, and so on)
  in the pull request description.

## Adding a collector

1. Create `Sources/PulsekiCore/Collectors/FooCollector.swift` implementing
   `Collector`. Give it a short lowercase `name`; that is what `--disable`
   and the `collector` label use.
2. Register it in `CollectorFactory.names` and `CollectorFactory.build`. The
   order of `names` is the exposition order.
3. If it needs a C helper, add it to `Sources/CSystem` and declare it in
   `include/csystem.h`.
4. Add the metrics to the table in `README.md` and a line to `CHANGELOG.md`.
5. Run the binary and validate the output: the Python client's
   `prometheus_client.parser` or `promtool check metrics` both work.

## Tests

`swift test` covers the exposition format, SMC decoding, configuration
parsing, the OTLP encoder and gzip. Collectors depend on hardware and are
exercised by running the binary; CI does that on a macOS runner.

## Releasing

Maintainers: bump `Sources/PulsekiCore/Version.swift`, update `CHANGELOG.md`,
commit, then run `scripts/release.sh <version>` and copy the updated formula
into `looskis/homebrew-tap`.
