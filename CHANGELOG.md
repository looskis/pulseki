# Changelog

All notable changes to pulseki are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-09-28

First release.

### Added

- Collectors: `cpu`, `load`, `memory`, `filesystem`, `diskstats`, `network`,
  `gpu`, `thermal`, `smc`, `battery`, `system`, using node_exporter metric
  names where the semantics match and a `macos_` prefix for Mac-only data.
- Prometheus text exposition on `/metrics`, a landing page on `/`, and
  `/-/healthy`.
- Push mode: OTLP/HTTP JSON export to Grafana Cloud or any OpenTelemetry
  endpoint on an interval, with gzip, basic auth from a token file, and
  `pulseki_push_*` health metrics.
- `key = value` config file with the same keys as the command-line flags;
  Homebrew installs a documented default at `etc/pulseki.conf`.
- `pulseki smc-dump` to list every SMC key with its type and decoded value,
  and `smc.key-include` to limit which sensors are read.
- 64-bit network counters via the IFMIB sysctl, avoiding the 4 GB wrap in
  `RTM_IFINFO2` records.
- Homebrew formula with a `brew services` definition, and
  `scripts/release.sh` to tag a release and pin the formula.
- `scripts/tailscale-targets.sh` and `docs/fleet.md` for running a fleet of
  Macs behind one Prometheus over Tailscale.

[0.1.0]: https://github.com/looskis/pulseki/releases/tag/v0.1.0
