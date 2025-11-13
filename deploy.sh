#!/usr/bin/env bash
set -euo pipefail
# Unified deploy script
# Usage:
#   ./deploy.sh --local [--no-up] [--dry-run]
#   ./deploy.sh host:/target/path [--no-up] [--dry-run] [--port 22]
#
# Behavior:
#   --local            Only run Docker locally in the current directory.
#   host:/target/path  Rsync current directory to remote absolute path, then run Docker there.
#
# Notes:
#   * docker-compose.yml must use relative paths so it works both locally and remotely.
#   * Requires rsync and ssh for remote mode.
#   * You can override env: RSYNC_BIN (default rsync), SSH_PORT (default 22).
set -euo pipefail

RSYNC_BIN="${RSYNC_BIN:-rsync}"
SSH_PORT="${SSH_PORT:-22}"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# *//'
}

# Default flags
LOCAL_MODE=0
DRY_RUN=0
NO_UP=0

TARGET=""
REMOTE_HOST=""
REMOTE_PATH=""

# Parse args
if (( $# == 0 )); then
  #usage
  exit 1
fi

while (( $# )); do
  case "${1:-}" in
    --local)
      LOCAL_MODE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown flag: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
      else
        echo "ERROR: Unexpected extra argument: $1" >&2
        usage
        exit 2
      fi
      shift
      ;;
  esac
done

# Validate modes
if (( LOCAL_MODE == 1 )) && [[ -n "$TARGET" ]]; then
  echo "ERROR: Don't provide a target when using --local." >&2
  exit 2
fi

if (( LOCAL_MODE == 0 )) && [[ -z "$TARGET" ]]; then
  echo "ERROR: Must provide target in the form host:/target/path OR use --local." >&2
  exit 2
fi

# Helper: choose docker compose command
compose_up() {
  local build_dir="$1"
  if (( NO_UP == 1 )); then
    echo "==> Skipping docker compose ( --no-up set )"
    return 0
  fi
  if (( DRY_RUN == 1 )); then
    echo "==> [dry-run] Would run docker compose in: ${build_dir}"
    return 0
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ( cd "$build_dir" && docker compose up -d --build )
  elif command -v docker-compose >/dev/null 2>&1; then
    ( cd "$build_dir" && docker-compose up -d --build )
  else
    echo "ERROR: docker compose not found." >&2
    return 1
  fi
}

# LOCAL MODE
if (( LOCAL_MODE == 1 )); then
  echo "==> Local mode: using current directory: $(pwd)"
  compose_up "$(pwd)"
  echo "==> Done (local)."
  exit 0
fi

# REMOTE MODE
# Validate TARGET as host:/absolute/path
if [[ "$TARGET" =~ ^[^:]+:/.+ ]]; then
  REMOTE_HOST="${TARGET%%:*}"
  REMOTE_PATH="${TARGET#*:}"
else
  echo "ERROR: Target must be in the form host:/target/absolute/path" >&2
  exit 2
fi

echo "==> Remote host: ${REMOTE_HOST}"
echo "==> Remote path: ${REMOTE_PATH}"
echo "==> SSH port: ${SSH_PORT}"
echo "==> Dry run: ${DRY_RUN}   No-up: ${NO_UP}"

# Ensure remote path exists
if (( DRY_RUN == 1 )); then
  echo "==> [dry-run] Would create directory: ${REMOTE_PATH} on ${REMOTE_HOST}"
else
  ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "$REMOTE_HOST" "mkdir -p '${REMOTE_PATH}'"
fi

# Rsync current directory to remote
RSYNC_FLAGS=(
  -azv
  --no-times
  --no-owner
  --no-group
  --filter=':- .gitignore'
  --exclude='.git/'
)

if (( DRY_RUN == 1 )); then
  RSYNC_FLAGS+=(--dry-run -v)
fi

echo "==> Syncing project to ${REMOTE_HOST}:${REMOTE_PATH}"
"${RSYNC_BIN}" "${RSYNC_FLAGS[@]}" ./ "${REMOTE_HOST}:${REMOTE_PATH}/"

# Run docker compose on remote
if (( NO_UP == 1 )); then
  echo "==> Skipped docker compose on remote ( --no-up )"
else
  if (( DRY_RUN == 1 )); then
    echo "==> [dry-run] Would run docker compose up -d --build in ${REMOTE_PATH} on ${REMOTE_HOST}"
  else
    ssh -o StrictHostKeyChecking=accept-new "$REMOTE_HOST" "cd ${REMOTE_PATH} && docker compose up -d --build || echo 'docker compose failed'"
  fi
fi

echo '==> Done (remote).'

