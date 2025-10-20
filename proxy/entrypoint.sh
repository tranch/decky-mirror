#!/bin/sh
set -eu

log() { echo "[$(date +'%F %T')] $*" >&2 || :; }
err() { echo "[$(date +'%F %T')] ERR: $*" >&2; }
warn() { echo "[$(date +'%F %T')] WARN: $*" >&2; }

# Small helper: parse human duration like "6h", "30m" -> seconds
to_seconds() {
  v="$1"
  case "$v" in
    *h) echo $(( ${v%h} * 3600 ));;
    *m) echo $(( ${v%m} * 60 ));;
    *s) echo $(( ${v%s} ));;
    ''|0) echo 0;;
    *) echo "$v";; # already seconds
  esac
}

fetch_and_build_cmd() {
  if [ -z "${SUBSCRIPTION_URL:-}" ]; then
    err "SUBSCRIPTION_URL is not set."
    return 1
  fi

  log "Fetching subscription from: $SUBSCRIPTION_URL"
  SUB_B64="$(curl -fsSL "$SUBSCRIPTION_URL")" || {
    err "Failed to fetch subscription."
    return 1
  }

  # parse_ss.py prints a single line: ss://method:pass@host:port|name
  # selection is controlled by NODE_NAME_REGEX / NODE_INDEX
  SEL_LINE="$(python3 /app/parse_ss.py \
      --subscription-b64 "$SUB_B64" \
      --name-regex "${NODE_NAME_REGEX:-}" \
      --index "${NODE_INDEX:-0}")" || {
    err "Failed to parse/select node from subscription."
    return 1
  }

  SS_URI="${SEL_LINE%|*}"   # ss://...
  NAME="${SEL_LINE#*|}"

  log "Selected node: $NAME"

  # Return a gost command via echo (caller evals it)
  # -L http://:PROXY_PORT -> HTTP proxy for clients
  # -F $SS_URI           -> forward chain via Shadowsocks server
  log "gost -L http://:${PROXY_PORT} -F ${SS_URI}"
}

run_once() {
  CMD="$(fetch_and_build_cmd)" || exit 1
  echo "[*] Starting gost..."
  # shellcheck disable=SC2086
  exec $CMD
}

run_with_refresh() {
  interval_s="$(to_seconds "$REFRESH_INTERVAL")"
  if [ "$interval_s" -le 0 ]; then
    run_once
    return 0
  fi

  # Supervisor loop: fetch config, start gost, periodically re-fetch and restart if changed
  while :; do
    CMD="$(fetch_and_build_cmd)" || {
      echo "[WARN] Will retry in $interval_s seconds..."
      sleep "$interval_s"
      continue
    }

    # Start gost in background
    sh -c "$CMD" &
    PID=$!

    log "gost pid: $PID"
    log "Sleeping for $interval_s seconds before next refresh..."

    sleep "$interval_s" || true

    log "Refresh interval reached; checking updates..."

    NEW_CMD="$(fetch_and_build_cmd)" || {
      warn "Refresh failed; keeping current process."
      continue
    }

    if [ "$NEW_CMD" != "$CMD" ]; then
      log '[*] Upstream changed. Restarting gost...'
      kill "$PID" 2>/dev/null || true
      wait "$PID" 2>/dev/null || true
      # Loop will start new process next iteration
    else
      log '[*] No change detected.'
      # Keep the current process running another interval
      # (kill + restart only when configuration changes)
    fi
  done
}

if [ -n "${REFRESH_INTERVAL:-}" ]; then
  run_with_refresh
else
  run_once
fi

