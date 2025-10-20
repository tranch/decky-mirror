#!/usr/bin/env sh
# mirror-sync.sh — mirror repos listed in $REPO_LIST into ${GIT_ROOT}/owner/repo.git
# Only supports HTTP(S) GitHub URLs or "owner/repo" shorthand.
set -eu

REPO_LIST="${REPO_LIST:-/etc/repos.txt}"
GIT_ROOT="${GIT_ROOT:-/srv/git}"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-300}"
VERBOSE="${VERBOSE:-1}"
MIRROR_LFS="${MIRROR_LFS:-0}"
PRUNE_MISSING="${PRUNE_MISSING:-0}"

log() { [ "$VERBOSE" = "1" ] && echo "[$(date +'%F %T')] $*" >&2 || :; }
warn(){ echo "[$(date +'%F %T')] WARN: $*" >&2; }
die() { echo "[$(date +'%F %T')] ERROR: $*" >&2; exit 1; }

[ -f "$REPO_LIST" ] || die "REPO_LIST not found: $REPO_LIST"
mkdir -p "$GIT_ROOT"

# Parse one line -> "url owner repo"
parse_line() {
  line="$1"
  # trim & skip comments/empty
  line="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$line" in ""|"#"*) return 1;; esac

  owner="" repo="" url=""

  case "$line" in
    https://github.com/*/*)
      owner="$(echo "$line" | sed -E 's#https://github\.com/([^/]+)/([^/]+)(\.git)?#\1#')"
      repo="$(echo  "$line" | sed -E 's#https://github\.com/([^/]+)/([^/]+)(\.git)?#\2#')"
      ;;
    */*)
      # shorthand: owner/repo
      owner="$(echo "$line" | cut -d/ -f1)"
      repo="$(echo  "$line" | cut -d/ -f2)"
      ;;
    *)
      echo "[WARN] Skip unsupported line: $line" >&2
      return 1;;
  esac

  # 统一去掉尾部 .git（防止 .git.git）
  repo="$(echo "$repo" | sed 's/\.git$//')"

  # 规范化成标准 https URL（只加一次 .git）
  url="https://github.com/${owner}/${repo}.git"

  printf '%s %s %s\n' "$url" "$owner" "$repo"
}

mirror_one() {
  url="$1"; owner="$2"; repo="$3"
  target="${GIT_ROOT}/${owner}/${repo}.git"
  mkdir -p "$(dirname "$target")"

  if [ ! -d "$target" ]; then
    log "Clone --mirror: $owner/$repo"
    timeout "$FETCH_TIMEOUT" git clone --mirror "$url" "$target" || { warn "Clone failed: $owner/$repo"; return 0; }
  else
    git -C "$target" remote set-url origin "$url" || true
    log "Fetch: $owner/$repo"
    timeout "$FETCH_TIMEOUT" git -C "$target" remote update --prune || { warn "Fetch failed: $owner/$repo"; return 0; }
  fi

  # Optional LFS
  if [ "$MIRROR_LFS" = "1" ]; then
    ( cd "$target" && GIT_DIR="$target" git lfs fetch --all || true )
  fi

  # Dumb HTTP indices (hook 里也会做，这里双保险)
  git -C "$target" update-server-info || true
}

# desired set for prune
desired="$(mktemp)"; trap 'rm -f "$desired"' EXIT

while IFS= read -r raw; do
  if echo "$raw" | grep -E '^[[:space:]]*#' >/dev/null 2>&1; then
    continue
  fi

  parsed="$(parse_line "$raw" || true)" || true
  [ -n "$parsed" ] || continue
  url="$(echo "$parsed"   | awk '{print $1}')"
  owner="$(echo "$parsed" | awk '{print $2}')"
  repo="$(echo "$parsed"  | awk '{print $3}')"
  echo "${owner}/${repo}.git" >> "$desired"
  mirror_one "$url" "$owner" "$repo"
done < "$REPO_LIST"

# Optional prune: move repos not listed to .trash
if [ "$PRUNE_MISSING" = "1" ]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  trash="${GIT_ROOT}/.trash/${ts}"
  mkdir -p "$trash"

  find "$GIT_ROOT" -type d -name '*.git' | while read -r d; do
    rel="${d#$GIT_ROOT/}"
    case "$rel" in .trash/*) continue;; esac
    if ! grep -qx "$rel" "$desired"; then
      log "Prune (move): $rel"
      mkdir -p "$(dirname "$trash/$rel")"
      mv "$d" "$trash/$rel" || true
    fi
  done
fi

log "Sync round done."

