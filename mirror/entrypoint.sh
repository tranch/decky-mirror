#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[$(date +'%F %T')] $*" >&2; }

mkdir -p "${GIT_ROOT}" "${OUT_ROOT}"

git config --system core.hooksPath /srv/hooks || true

TERMINATE=0
PID=0
SLEEP_PID=0

on_term(){
  log "Received stop signal, will exit."
  TERMINATE=1
  if [ "${SLEEP_PID:-0}" -gt 0 ]; then
    kill "$SLEEP_PID" 2>/dev/null || true
  fi
  if [ "${PID:-0}" -gt 0 ]; then
    kill "$PID" 2>/dev/null || true
  fi
}
trap on_term SIGTERM SIGINT

sync_once() {
  timeout "${FETCH_TIMEOUT}" /usr/local/bin/mirror-sync.sh &
  PID=$!
  wait "$PID" 2>/dev/null || {
    log "mirror-sync exceeded ${FETCH_TIMEOUT}s or failed (continuing next cycle)."
  }
  PID=0
}

sync_once

if [[ "${INTERVAL}" == "0" ]]; then
  log "Run-once mode finished. Exiting."
  exit 0
fi

while [[ "${TERMINATE}" -eq 0 ]]; do
  sleep "${INTERVAL}" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=0
  [[ "${TERMINATE}" -ne 0 ]] && break
  sync_once
done

log "Mirror loop stopped."
