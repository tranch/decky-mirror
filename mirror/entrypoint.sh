#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[$(date +'%F %T')] $*" >&2; }

mkdir -p "${GIT_ROOT}" "${OUT_ROOT}"

git config --system core.hooksPath /srv/hooks || true

stop=0
on_term(){ log "Received stop signal, will exit."; stop=1; }
trap on_term SIGTERM SIGINT

sync_once() {
  if ! timeout "${FETCH_TIMEOUT}" /usr/local/bin/mirror-sync.sh; then
    log "mirror-sync exceeded ${FETCH_TIMEOUT}s or failed (continuing next cycle)."
  fi
}

sync_once

if [[ "${INTERVAL}" == "0" ]]; then
  log "Run-once mode finished. Exiting."
  exit 0
fi

while [[ "${stop}" -eq 0 ]]; do
  sleep "${INTERVAL}" || true
  [[ "${stop}" -ne 0 ]] && break
  sync_once
done

log "Mirror loop stopped."

