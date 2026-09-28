#!/usr/bin/env bash
# Write a Prometheus file_sd target list from `tailscale status --json`.
#
#   tailscale-targets.sh [--tag TAG] [--port PORT] [--include-offline] OUTPUT.json
#
# Selects tailnet peers (and this node) that carry TAG, or every macOS node
# when no tag is given, and writes one target per node using its MagicDNS
# name. The file is written atomically so Prometheus never reads a partial
# list. Requires jq and the tailscale CLI.
set -euo pipefail

tag=""
port="9101"
include_offline="false"
output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    --include-offline) include_offline="true"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) output="$1"; shift ;;
  esac
done

if [[ -z "$output" ]]; then
  echo "usage: $0 [--tag TAG] [--port PORT] [--include-offline] OUTPUT.json" >&2
  exit 2
fi

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# `tailscale` lives outside PATH on macOS when installed from the App Store.
ts="$(command -v tailscale || true)"
if [[ -z "$ts" && -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
  ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
fi
[[ -n "$ts" ]] || { echo "tailscale CLI not found" >&2; exit 1; }

tmp="$(mktemp "${output}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

"$ts" status --json | jq \
  --arg tag "$tag" --arg port "$port" --argjson offline "$include_offline" '
  [ .Self ] + [ .Peer[]? ]
  | map(select(.DNSName != null and .DNSName != ""))
  | map(select(if $tag == "" then .OS == "macOS" else ((.Tags // []) | index($tag)) != null end))
  | map(select($offline or .Online))
  | map({
      targets: [ (.DNSName | rtrimstr(".")) + ":" + $port ],
      labels: {
        instance: .HostName,
        os: .OS,
        tailscale_tags: ((.Tags // []) | join(","))
      }
    })
  | sort_by(.labels.instance)
' > "$tmp"

mv "$tmp" "$output"
trap - EXIT
