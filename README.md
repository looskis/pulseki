# pulseki

A Prometheus exporter for macOS. One small native binary with no runtime
dependencies that exposes CPU, GPU, memory, storage, disk I/O, network,
thermal, SMC sensor, battery and system metrics at `http://host:9101/metrics`,
and can also push them to Grafana Cloud or any OpenTelemetry endpoint.

- **Installs with Homebrew**, runs at login or boot with `brew services`.
- **node_exporter compatible names** wherever the semantics match, so the
  community "Node Exporter Full" Grafana dashboard largely works out of the box.
  Mac-only data (GPU, sensors, memory pressure, battery, performance cores)
  lives under a `macos_` prefix.
- **Pull and push.** Serves `/metrics` for Prometheus, and optionally pushes
  the same metrics over OTLP/HTTP for stores that cannot reach the Mac.
- **Small.** Under 500 KB on disk, 12 to 17 MB resident, well under 0.1% of a
  core at a 15 s interval.

Documentation: [Configuration](#configuration) ·
[Getting data out](#getting-data-out) · [Metrics reference](#metrics-reference) ·
[Running a fleet over Tailscale](docs/fleet.md) · [Troubleshooting](#troubleshooting) ·
[Design](#design) · [Changelog](CHANGELOG.md)

## Quick start

```bash
brew install looskis/tap/pulseki
brew services start pulseki
curl -s localhost:9101/metrics | head
```

`brew services start` registers a LaunchAgent that starts pulseki at login.
For an always-on machine, `sudo brew services start pulseki` registers a
LaunchDaemon that starts at boot before anyone logs in. Nothing in pulseki
needs root; `sudo` only changes when launchd starts it.

Point Prometheus at it:

```yaml
scrape_configs:
  - job_name: macos
    scrape_interval: 15s
    static_configs:
      - targets: ["my-mac.local:9101"]
```

Then import Grafana dashboard 1860 ("Node Exporter Full") for CPU, load,
memory, filesystem, disk and network panels, and build your own panels for the
`macos_*` series.

## Configuration

The Homebrew service reads `$(brew --prefix)/etc/pulseki.conf`. Keys are the
command-line options without the leading `--`, one `key = value` per line,
`#` for comments. Homebrew preserves your edits across upgrades. The
[shipped file](config/pulseki.conf) documents every key.

```
listen = 0.0.0.0:9101
path = /metrics
# disable = smc,battery
# smc.key-include = ^(TCMb|TCMz|TH0x|PSTR|PDTR)$
```

Command-line flags override the file:

```
pulseki [--listen ADDR] [--path PATH] [--config FILE] [--disable a,b]
        [--filesystem.mount-points-exclude RE] [--filesystem.fs-types-exclude RE]
        [--network.device-exclude RE] [--smc.key-include RE]
        [--push.url URL] [--push.username USER] [--push.password-file FILE]
        [--push.interval SECONDS] [--push.job NAME] [--push.instance NAME]
        [--collectors] [--version] [--help]
pulseki smc-dump
```

| Option | Default | Meaning |
|---|---|---|
| `listen` | `0.0.0.0:9101` | Address to serve on. `:9101`, `127.0.0.1:9101` and `[::]:9101` all work. |
| `path` | `/metrics` | URL path for the exposition. `/` serves a landing page, `/-/healthy` returns `OK`. |
| `disable` | none | Comma-separated collectors to turn off. `pulseki --collectors` lists them. |
| `filesystem.mount-points-exclude` | APFS system volumes | ICU regex of mount points to skip. |
| `filesystem.fs-types-exclude` | `autofs`, `devfs`, … | ICU regex of filesystem types to skip. |
| `network.device-exclude` | Apple virtual interfaces | ICU regex of interfaces to skip. |
| `smc.key-include` | all plausible keys | ICU regex of SMC keys to read. See [SMC sensors](#smc-sensors). |
| `push.*` | off | See [Pushing to Grafana Cloud](#pushing-to-grafana-cloud). |

An empty regex disables that filter.

**Network exposure.** The default binds every interface, which is what a
Prometheus server on your LAN expects. The exporter has no authentication of
its own. On a laptop that joins untrusted networks, set `listen = 127.0.0.1:9101`
and use push mode or a tunnel, bind to a VPN address such as your Tailscale IP,
or firewall the port.

## Getting data out

pulseki always serves `/metrics`. Setting `push.url` additionally sends every
metric to an OpenTelemetry (OTLP/HTTP) endpoint on an interval. Both run at the
same time.

### Scraping with Prometheus

Use the scrape config in [Quick start](#quick-start). For several Macs on a
tailnet, with a central Prometheus and automatic target discovery, see
[docs/fleet.md](docs/fleet.md).

### Pushing to Grafana Cloud

Grafana Cloud does not scrape. In your stack open **Connections → Add new
connection → HTTP Metrics**, choose the Prometheus format, and create an access
policy token with only the `metrics:write` scope. The page shows an OTLP
gateway URL and a numeric instance ID. Then on the Mac:

```bash
printf '%s\n' 'glc_your_token' > /opt/homebrew/etc/pulseki.token
chmod 600 /opt/homebrew/etc/pulseki.token
```

and in `/opt/homebrew/etc/pulseki.conf`:

```
push.url = https://otlp-gateway-prod-<region>.grafana.net/otlp/v1/metrics
push.username = <instance-id>
push.password-file = /opt/homebrew/etc/pulseki.token
push.interval = 15
push.instance = mac-mini
```

Restart with `brew services restart pulseki`, then query
`pulseki_build_info` in Explore against the stack's Prometheus data source.

How push behaves:

- Each push is one gzip-compressed JSON document, roughly 5 to 10 KB on the
  wire for a full metric set.
- Metric names arrive unchanged. Counters are sent as cumulative monotonic sums
  and gauges as gauges, so `rate()` works exactly as it does for a scraped target.
- `job` comes from `push.job` (default `macos`) and `instance` from
  `push.instance` (default: this Mac's hostname). Grafana also derives a
  `target_info` series from the resource attributes.
- Push health is on `/metrics`: `pulseki_pushes_total{result}`,
  `pulseki_push_last_success_timestamp_seconds`,
  `pulseki_push_consecutive_failures`, `pulseki_push_last_duration_seconds`,
  `pulseki_push_bytes_total`.
- Failures are logged once, then every twentieth attempt. There is no local
  queue: an outage leaves a gap, not a backlog.
- The same endpoint shape works with an OpenTelemetry collector or with Mimir
  directly, with or without basic auth.

Keep the token out of command-line arguments, which any user on the machine can
read with `ps`. Use `push.password-file`, or `push.password` in the config file
with the file mode set to 600.

If a central Prometheus already forwards this Mac's metrics to Grafana Cloud
with `remote_write`, do not also enable push on it, or every series arrives
twice.

## Metrics reference

| Collector | Source | Metrics |
|---|---|---|
| `cpu` | `host_processor_info`, `hw.perflevel*` | `node_cpu_seconds_total{cpu,mode}`, `macos_cpu_logical_cpus`, `macos_cpu_physical_cpus`, `macos_cpu_perflevel_{logical,physical}_cpus{level,name}`, `macos_cpu_perflevel_l2_cache_bytes` |
| `load` | `getloadavg` | `node_load1`, `node_load5`, `node_load15` |
| `memory` | `host_statistics64`, `vm.swapusage`, `kern.memorystatus_vm_pressure_level` | `node_memory_{total,free,active,inactive,wired,compressed,internal,purgeable}_bytes`, `node_memory_swap_{total,used}_bytes`, `node_memory_swapped_{in,out}_bytes_total`, `macos_memory_{external,speculative,app,swap_free,uncompressed_in_compressor}_bytes`, `macos_memory_{pageins,pageouts,page_faults,compressions,decompressions}_total`, `macos_memory_pressure_level` (1 normal, 2 warning, 4 critical) |
| `filesystem` | `getmntinfo` | `node_filesystem_{size,free,avail}_bytes`, `node_filesystem_files`, `node_filesystem_files_free`, `node_filesystem_readonly` with `{device,fstype,mountpoint}` |
| `diskstats` | IOKit `IOBlockStorageDriver` | `node_disk_{read,written}_bytes_total`, `node_disk_{reads,writes}_completed_total`, `node_disk_{read,write}_time_seconds_total`, `node_disk_{read,write}_{errors,retries}_total` with `{device}` |
| `network` | IFMIB sysctl (64-bit counters) | `node_network_{receive,transmit}_{bytes,packets,errs,drop,multicast}_total`, `node_network_transmit_colls_total`, `macos_network_receive_noproto_total`, `node_network_up`, `node_network_mtu_bytes`, `node_network_speed_bytes` with `{device}` |
| `gpu` | IOKit `IOAccelerator` | `macos_gpus`, `macos_gpu_info{gpu,model,class}`, `macos_gpu_cores`, `macos_gpu_{device,renderer,tiler}_utilization_ratio`, `macos_gpu_memory_{in_use,allocated,driver_in_use}_bytes`, `macos_gpu_recoveries_total` |
| `thermal` | `ProcessInfo.thermalState` | `macos_thermal_state` (0 nominal, 1 fair, 2 serious, 3 critical) |
| `smc` | AppleSMC user client | `macos_smc_temperature_celsius{sensor}`, `macos_smc_power_watts{key}`, `macos_smc_fans`, `macos_smc_fan_{speed,min,max,target}_rpm{fan}` |
| `battery` | IOKit `AppleSmartBattery` | `macos_battery_present`, `macos_battery_external_connected`, and on portables `macos_battery_{charge,health}_ratio`, `macos_battery_{current,max,design}_capacity_mah`, `macos_battery_cycle_count`, `macos_battery_{charging,fully_charged}`, `macos_battery_temperature_celsius`, `macos_battery_voltage_volts`, `macos_battery_current_amperes`, `macos_battery_time_{remaining,to_empty,to_full}_seconds` |
| `system` | `kern.boottime`, `uname`, `kern.osproductversion`, `hw.model`, `KERN_PROC_ALL` | `node_boot_time_seconds`, `node_time_seconds`, `node_uname_info`, `macos_version_info{version,build}`, `macos_hardware_info{model,chip}`, `macos_processes` |

Every scrape and push also carries `pulseki_build_info`,
`pulseki_scrapes_total`, `pulseki_scrape_collector_duration_seconds{collector}`,
`pulseki_scrape_collector_success{collector}` and the standard `process_*`
self metrics.

A collector that fails contributes nothing but a `success 0` sample, so one
broken data source can never corrupt the exposition. The failure is logged once
and a recovery is logged when it next succeeds.

### Notes on specific metrics

- **Filesystems.** APFS volumes in the same container share space, so `/` (the
  sealed system snapshot) and `/System/Volumes/Data` report the same size.
  System-internal volumes (Preboot, VM, Update, xarts, iSCPreboot, Hardware)
  are excluded by default.
- **Network.** Byte counters come from the IFMIB sysctl because the routing
  socket's `RTM_IFINFO2` records wrap at 4 GB on current macOS even though the
  field is 64 bits wide. Apple's internal virtual interfaces (`gif`, `stf`,
  `anpi`, `ap`, `llw`, `awdl`, `pktap`, `XHC`) are excluded by default;
  `utun`, `bridge` and `en*` are kept.
- **GPU.** Utilisation and memory come from the accelerator driver's
  `PerformanceStatistics`. GPU power and frequency need the private IOReport
  framework and are not included.
- **Battery.** Desktops expose the battery service with `BatteryInstalled`
  false, so they emit only `macos_battery_present 0` and
  `macos_battery_external_connected`.

### SMC sensors

The SMC collector enumerates every key once at startup and then reads the
temperature (`T*`) and power (`P*`) keys that had plausible values, plus the
fans. Each read is a kernel round trip to the SMC coprocessor of roughly
150 µs and the calls are serialised, so on an Apple silicon Mac with about 200
such keys the collector costs around 30 ms per scrape. That is latency, not
CPU: the thread is waiting on the coprocessor.

To trim it, run `pulseki smc-dump` to see every key with its type and value,
then set `smc.key-include` to the ones you graph. Useful Apple silicon keys:
`TCMb` and `TCMz` (CPU package), `TH0x` (NAND), `TPD*` (per-die sensors),
`PSTR` (total system power), `PDTR` (DC input power). Intel Macs use different
names, and `sp78` fixed-point values are decoded as well as `flt`.

## Troubleshooting

- **Is it running?** `brew services info pulseki` shows the launchd state.
  Logs go to `$(brew --prefix)/var/log/pulseki.log` and `pulseki.err`.
- **A collector is missing.** Look at `pulseki_scrape_collector_success` on
  `/metrics` and at the error log; the first failure is logged with its cause.
- **Port already in use.** The log says `bind 0.0.0.0:9101: Address already in
  use`. Change `listen` or stop the other process.
- **Bind fails at boot.** If `listen` is a VPN or Tailscale address that does
  not exist yet when launchd starts pulseki, the bind fails and `keep_alive`
  restarts it until the interface is up. This is expected; the log shows the
  retries.
- **Pushes fail.** `pulseki_push_consecutive_failures` on `/metrics` and the
  error log show the HTTP status and the first 300 bytes of the response. A
  401 means the instance ID or token is wrong or the token lacks
  `metrics:write`.
- **First scrape is slow.** The SMC key enumeration runs on the first scrape
  and takes about half a second. Later scrapes are fast.
- **Running two copies.** `brew services` only manages one. If you also run
  pulseki by hand on the same port, the second one fails to bind.

## Design

- **Swift with a small C target.** Swift gives native access to IOKit, Mach and
  sysctl with no FFI layer, and the Swift runtime ships with macOS, so the
  binary is under 500 KB and the only build dependency is the Command Line
  Tools. The C target ([Sources/CSystem](Sources/CSystem)) covers the two
  places where exact struct layout matters: the 80-byte AppleSMC user-client
  message and the IFMIB interface statistics.
- **No third-party packages.** The HTTP server is POSIX sockets with an accept
  thread and one GCD task per connection, `Connection: close` on every
  response, which is exactly the pattern a Prometheus scrape produces. Push
  uses Foundation's URLSession and the system zlib.
- **Isolated collectors.** Each collector returns its families or throws;
  nothing is rendered until it has succeeded. Collection is serialised with a
  lock, so concurrent scrapes and pushes never interleave.
- **Static data is read once.** CPU topology, uname, hardware model, boot time
  and the SMC key list are gathered at startup, so a scrape only touches what
  changes.

## Building and testing

Requires macOS 13 or later with the Xcode Command Line Tools.

```bash
swift build -c release
.build/release/pulseki --listen 127.0.0.1:9101
curl -s localhost:9101/metrics | head
swift test
```

The tests cover the exposition format, SMC value decoding, configuration
parsing, the OTLP encoder and gzip. Collectors are exercised by running the
binary; CI does that on a macOS runner and checks that the core collectors
report success.

## Releasing

1. Bump `Sources/PulsekiCore/Version.swift`, add a CHANGELOG entry, commit.
2. Run `scripts/release.sh <version>`. It builds, tests, tags `v<version>`,
   pushes the tag, downloads the GitHub tarball, and writes its sha256 into
   `Formula/pulseki.rb`.
3. Commit the formula here, then copy it into `looskis/homebrew-tap`.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
for how to add a collector and what a change needs before it merges.

## License

MIT. See [LICENSE](LICENSE).
