#!/usr/bin/env bash
# Import (or update) a dashboard through the Grafana HTTP API.
#
#   GRAFANA_URL=https://<stack>.grafana.net \
#   GRAFANA_TOKEN_FILE=~/.config/grafana/token \
#   scripts/grafana-import.sh [dashboards/pulseki-classic.json] [--folder FOLDER_UID]
#
# Works on every Grafana version including Grafana Cloud: the classic
# dashboard object is posted to /api/dashboards/db and Grafana converts it to
# whatever schema it stores internally. Re-running overwrites the dashboard in
# place (matched by uid), so this is also how to roll out updates.
#
# Token: create a service account with the Editor role under
# Administration -> Users and access -> Service accounts, add a token, and put
# it in GRAFANA_TOKEN_FILE (or export GRAFANA_TOKEN). Never pass it as an
# argument; arguments are visible to other users via ps.
set -euo pipefail

file="dashboards/pulseki-classic.json"
folder=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --folder) folder="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) file="$1"; shift ;;
  esac
done

: "${GRAFANA_URL:?set GRAFANA_URL, e.g. https://mystack.grafana.net}"
if [[ -z "${GRAFANA_TOKEN:-}" ]]; then
  : "${GRAFANA_TOKEN_FILE:?set GRAFANA_TOKEN or GRAFANA_TOKEN_FILE}"
  GRAFANA_TOKEN="$(tr -d '[:space:]' < "$GRAFANA_TOKEN_FILE")"
fi
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[[ -f "$file" ]] || { echo "no such file: $file" >&2; exit 1; }

# Accept either the classic object or the apiVersion/kind/metadata/spec wrapper.
dashboard="$(jq 'if has("spec") then (.spec + {uid: .metadata.name}) else . end | .id = null' "$file")"
payload="$(jq -n --argjson d "$dashboard" --arg folder "$folder" \
  '{dashboard: $d, overwrite: true} + (if $folder != "" then {folderUid: $folder} else {} end)')"

response="$(curl -sS --fail-with-body -X POST "${GRAFANA_URL%/}/api/dashboards/db" \
  -H "Authorization: Bearer $GRAFANA_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$payload")" || { echo "$response" >&2; exit 1; }

url="$(jq -r '.url // empty' <<<"$response")"
echo "$(jq -r '.status' <<<"$response"): ${GRAFANA_URL%/}${url}"
