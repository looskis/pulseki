# Running a fleet of Macs over Tailscale

This guide sets up one central Prometheus (the "master") that scrapes every Mac
on a tailnet, discovers new Macs automatically, and forwards everything to
Grafana Cloud. Laptops that are not reliably reachable push directly instead.

```
                     tailnet (100.64.0.0/10)
  ┌──────────────┐   scrape :9101   ┌───────────────────┐   remote_write   ┌───────────────┐
  │ mac-mini     │◄─────────────────│ master            │─────────────────►│ Grafana Cloud │
  │ pulseki      │                  │ Prometheus        │                  │ (Mimir)       │
  └──────────────┘                  │ + file_sd targets │                  └───────▲───────┘
  ┌──────────────┐                  └───────────────────┘                          │
  │ mac-studio   │◄────────────────────────────┘                                   │
  │ pulseki      │                                                                  │
  └──────────────┘                                                                  │
  ┌──────────────┐   OTLP push (laptop, not always reachable)                       │
  │ macbook      │───────────────────────────────────────────────────────────────────┘
  │ pulseki      │
  └──────────────┘
```

## 1. On each always-on Mac

Install and bind to the Tailscale address so that only tailnet peers can read
the metrics:

```bash
brew install looskis/tap/pulseki
TS_IP=$(tailscale ip -4)
sed -i '' "s/^listen = .*/listen = ${TS_IP}:9101/" /opt/homebrew/etc/pulseki.conf
sudo brew services start pulseki
```

If pulseki starts before Tailscale has brought the interface up, the bind fails
and `keep_alive` restarts it until it succeeds. The error log shows a few
`bind ... Can't assign requested address` lines at boot and then goes quiet.

Tag the machine in Tailscale so the master can find it. In the admin console
give the node the tag `tag:pulseki` (or tag it at login with
`tailscale up --advertise-tags=tag:pulseki` if the ACL allows it).

## 2. Tailscale ACL

Let the master reach port 9101 on tagged Macs and nothing else reach it:

```json
{
  "tagOwners": {
    "tag:pulseki": ["autogroup:admin"],
    "tag:monitor": ["autogroup:admin"]
  },
  "acls": [
    { "action": "accept", "src": ["tag:monitor"], "dst": ["tag:pulseki:9101"] }
  ]
}
```

Tag the master `tag:monitor`.

## 3. On the master

Prometheus can run on any OS. On a Mac:

```bash
brew install prometheus jq
```

On Linux use your distribution's package or the release tarball from
prometheus.io, and install `jq`.

### Target discovery

[`scripts/tailscale-targets.sh`](../scripts/tailscale-targets.sh) turns
`tailscale status --json` into a Prometheus `file_sd` file. Copy it to the
master and run it on a timer:

```bash
sudo install -m 755 tailscale-targets.sh /usr/local/bin/tailscale-targets
sudo mkdir -p /etc/prometheus/targets
sudo tailscale-targets --tag tag:pulseki --port 9101 /etc/prometheus/targets/macos.json
cat /etc/prometheus/targets/macos.json
```

Refresh it every minute. On Linux, a cron entry:

```
* * * * * /usr/local/bin/tailscale-targets --tag tag:pulseki --port 9101 /etc/prometheus/targets/macos.json
```

On a Mac master, `brew services` cannot schedule a timer, so use a LaunchAgent
with `StartInterval` 60, or keep a static target list instead. Prometheus
re-reads `file_sd` files on change; no restart is needed.

The script writes one target per online Mac with its MagicDNS name and labels
`instance` (the MagicDNS short name, lowercase), `os` and `tailscale_tags`. Offline Macs
are omitted so they don't show as down; pass `--include-offline` if you would
rather alert on them.

### prometheus.yml

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: macos
    file_sd_configs:
      - files: ["/etc/prometheus/targets/macos.json"]
        refresh_interval: 1m

remote_write:
  - url: https://prometheus-prod-<nn>-prod-<region>.grafana.net/api/prom/push
    basic_auth:
      username: "<prometheus-instance-id>"
      password_file: /etc/prometheus/grafana-cloud.token
```

The `remote_write` URL and instance ID are different from the OTLP ones used by
pulseki's push mode. Find them in the Grafana Cloud portal under your stack →
Prometheus → Details ("Remote Write Endpoint"). The token needs the
`metrics:write` scope. Omit the `remote_write` block if you only want local
storage on the master.

Start Prometheus and confirm the targets are up at `http://master:9090/targets`.

## 4. Laptops: push instead

A laptop that sleeps, roams, or is often off the tailnet is better served by
pushing directly to Grafana Cloud whenever it is online. On the laptop:

```
listen = 127.0.0.1:9101
push.url = https://otlp-gateway-prod-<region>.grafana.net/otlp/v1/metrics
push.username = <otlp-instance-id>
push.password-file = /opt/homebrew/etc/pulseki.token
push.instance = macbook
```

Do not also scrape a pushing laptop from a master that forwards to Grafana
Cloud, or its series arrive twice. Scraping it into the master's local storage
without `remote_write` is fine.

## 5. Dashboards

- Import Grafana dashboard **1860** ("Node Exporter Full") and set its job
  variable to `macos`. CPU, load, memory, filesystem, disk and network panels
  work. Panels that rely on Linux-only series (`node_pressure_*`,
  `node_netstat_*`, `node_systemd_*`) stay empty.
- Useful queries for the Mac-specific series:

```promql
# CPU busy percent per host
100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))

# GPU utilisation
macos_gpu_device_utilization_ratio * 100

# CPU package temperature (Apple silicon)
macos_smc_temperature_celsius{sensor="TCMb"}

# Total system power in watts
macos_smc_power_watts{key="PSTR"}

# Memory pressure (1 normal, 2 warning, 4 critical)
macos_memory_pressure_level

# Push health for laptops
time() - pulseki_push_last_success_timestamp_seconds
```

## 6. Alerting suggestions

```yaml
groups:
  - name: macos
    rules:
      - alert: MacDown
        expr: up{job="macos"} == 0
        for: 5m
      - alert: MacMemoryPressureCritical
        expr: macos_memory_pressure_level >= 4
        for: 10m
      - alert: MacThermalThrottling
        expr: macos_thermal_state >= 2
        for: 10m
      - alert: MacDiskAlmostFull
        expr: node_filesystem_avail_bytes{mountpoint="/System/Volumes/Data"}
              / node_filesystem_size_bytes{mountpoint="/System/Volumes/Data"} < 0.1
        for: 30m
      - alert: MacCollectorFailing
        expr: pulseki_scrape_collector_success == 0
        for: 30m
```
