#!/usr/bin/env bash
# control.sh — create and await a workspace via the control-plane API.
#
# There is no seeded workspace anymore: a workspace is a control-plane resource
# created with POST /api/v1/control/workspaces, reconciled by the operator into
# a ws-<id> namespace. This drives that, the same way the dashboard does.
#
#   CONTROL_URL=https://10.44.0.13 control_login            # -> token on stdout
#   create_workspace "$token" "ci-$CI_PIPELINE_ID"          # -> workspace id
#   wait_workspace_ready "$token" "$id"                     # -> waits for ok:true

set -euo pipefail

CONTROL_URL="${CONTROL_URL:-}"
# Traefik routes by Host header, so the control/workspace URLs are the ingress
# HOSTNAME (public.host), not the node IP. CONTROL_HOST must match public.host
# used at deploy time; NODE1_IP is where that name actually resolves.
CONTROL_HOST="${CONTROL_HOST:-}"
NODE1_IP="${NODE1_IP:-}"
CONTROL_ADMIN_EMAIL="${CONTROL_ADMIN_EMAIL:-admin@example.com}"
CONTROL_ADMIN_PASSWORD="${CONTROL_ADMIN_PASSWORD:-password}"
CONTROL_READY_TIMEOUT="${CONTROL_READY_TIMEOUT:-600}"

# curl that tolerates the cluster's self-signed/mkcert ingress. DNS resolves the
# ingress host; --resolve is only applied if NODE1_IP is explicitly set (a
# fallback for when the runner cannot resolve CONTROL_HOST).
_curl() {
  local resolve=()
  [[ -n "$CONTROL_HOST" && -n "$NODE1_IP" ]] && resolve=(--resolve "${CONTROL_HOST}:443:${NODE1_IP}")
  curl -sk --max-time 30 "${resolve[@]}" "$@"
}

control_login() {
  [[ -n "$CONTROL_URL" ]] || { echo "CONTROL_URL unset" >&2; return 1; }
  local body
  body="$(_curl -X POST "${CONTROL_URL}/api/login" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${CONTROL_ADMIN_EMAIL}\",\"password\":\"${CONTROL_ADMIN_PASSWORD}\"}")"
  ruby -rjson -e 'print JSON.parse(STDIN.read)["token"].to_s' <<<"$body"
}

# create_workspace <token> <name> -> echoes the numeric workspace id
create_workspace() {
  local token="$1" name="$2" body
  body="$(_curl -X POST "${CONTROL_URL}/api/v1/control/workspaces" \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${name}\"}")"
  ruby -rjson -e 'print (JSON.parse(STDIN.read)["id"] || 0).to_i' <<<"$body"
}

# wait_workspace_ready <token> <id> -> 0 when the workspace reports ok:true
wait_workspace_ready() {
  local token="$1" id="$2" waited=0 body
  while :; do
    body="$(_curl "${CONTROL_URL}/api/v1/control/workspaces/${id}/health" \
      -H "Authorization: Bearer ${token}" || true)"
    if ruby -rjson -e 'exit(JSON.parse(STDIN.read)["ok"] ? 0 : 1)' <<<"${body:-{}}" 2>/dev/null; then
      return 0
    fi
    waited=$((waited + 10))
    (( waited < CONTROL_READY_TIMEOUT )) || { echo "workspace ${id} not ready after ${CONTROL_READY_TIMEOUT}s" >&2; return 1; }
    sleep 10
  done
}
