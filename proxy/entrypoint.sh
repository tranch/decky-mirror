#!/bin/sh
set -eu

log() { echo "[$(date +'%F %T')] $*" >&2 || :; }
err() { echo "[$(date +'%F %T')] ERR: $*" >&2; }
warn() { echo "[$(date +'%F %T')] WARN: $*" >&2; }

TERMINATE=0
PID=0
SLEEP_PID=0

signal_handler() {
  log "Received termination signal. Exiting..."
  TERMINATE=1
  if [ "${SLEEP_PID:-0}" -gt 0 ]; then
    kill "$SLEEP_PID" 2>/dev/null || true
  fi
  if [ "${PID:-0}" -gt 0 ]; then
    kill "$PID" 2>/dev/null || true
  fi
}

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
  CMD="gost -L http://:${PROXY_PORT} -F ${SS_URI}"
  log "$CMD"
  echo "$CMD"
}

run_once() {
  CMD="$(fetch_and_build_cmd)" || exit 1
  echo "[*] Starting gost..."
  # shellcheck disable=SC2086
  sh -c "$CMD" &
  PID=$!
  wait "$PID"
}

run_with_refresh() {
  interval_s="$(to_seconds "$REFRESH_INTERVAL")"
  if [ "$interval_s" -le 0 ]; then
    run_once
    return 0
  fi

  CMD=""

  # Supervisor loop: fetch config, start gost, periodically re-fetch and restart if changed
  while [ "$TERMINATE" -eq 0 ]; do
    if [ "${PID:-0}" -le 0 ]; then
      CMD="$(fetch_and_build_cmd)" || {
        warn "Will retry in $interval_s seconds..."
        sleep "$interval_s"
        continue
      }

      # Start gost in background
      sh -c "$CMD" &
      PID=$!
      log "gost pid: $PID"
    fi

    log "Sleeping for $interval_s seconds before next refresh..."

    sleep "$interval_s" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true

    if [ "$TERMINATE" -ne 0 ]; then
      break
    fi

    log "Refresh interval reached; checking updates..."

    NEW_CMD="$(fetch_and_build_cmd)" || {
      warn "Refresh failed; keeping current process."
      continue
    }

    if [ "$NEW_CMD" != "$CMD" ]; then
      log '[*] Upstream changed. Restarting gost...'
      kill "$PID" 2>/dev/null || true
      wait "$PID" 2>/dev/null || true
      PID=0
      CMD="$NEW_CMD"
      sh -c "$CMD" &
      PID=$!
      log "gost pid: $PID"
    else
      log '[*] No change detected.'
      # Keep the current process running another interval
    fi
  done

  if [ "${PID:-0}" -gt 0 ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
}

trap signal_handler SIGINT SIGTERM

if [ -n "${REFRESH_INTERVAL:-}" ]; then
  run_with_refresh
else
  run_once
fi
