#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[$(date +'%F %T')] $*" >&2; }

# 创建必要目录
mkdir -p "${GIT_ROOT}" "${OUT_ROOT}"

# 允许宿主通过环境变量提供代理（HTTP[S]_PROXY/NO_PROXY）

# 确保 hooksPath（容器运行用户是 root，写 system/global 最稳）
git config --system core.hooksPath /srv/hooks || true

# 捕获信号，尽快退出
stop=0
on_term(){ log "Received stop signal, will exit."; stop=1; }
trap on_term SIGTERM SIGINT

sync_once() {
  # 用超时包裹你的 mirror-sync.sh，避免重启卡住
  if ! timeout "${FETCH_TIMEOUT}" /usr/local/bin/mirror-sync.sh; then
    log "mirror-sync exceeded ${FETCH_TIMEOUT}s or failed (continuing next cycle)."
  fi
}

# 先跑一次（即便 INTERVAL=0 也能完成一次）
sync_once

# INTERVAL=0 时仅运行一次即退出
if [[ "${INTERVAL}" == "0" ]]; then
  log "Run-once mode finished. Exiting."
  exit 0
fi

while [[ "${stop}" -eq 0 ]]; do
  # 轻量 sleep（被 SIGTERM/SIGINT 中断）
  sleep "${INTERVAL}" || true
  [[ "${stop}" -ne 0 ]] && break
  sync_once
done

log "Mirror loop stopped."

