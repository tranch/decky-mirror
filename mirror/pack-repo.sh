#!/bin/sh
# pack-one-repo.sh —— 仅针对当前仓库（$PWD 为 repo.git）导出 release 资产
set -eu

: "${OUT_ROOT:=/srv/releases}"
: "${ASSET_CANDIDATES:=install_release.sh install.sh scripts/install_release.sh scripts/install.sh installer/install_release.sh}"
: "${SCAN_EXECUTABLES:=1}"
: "${KEEP_N:=0}"
: "${WRITE_SHA256:=1}"
: "${VERBOSE:=1}"

log() { [ "${VERBOSE}" = "1" ] && echo "[$(date +'%F %T')] $*" >&2 || :; }

repo_dir="$PWD"                       # bare repo root
# 解析 owner/repo
owner="$(basename "$(dirname "$repo_dir")")"
repo="$(basename "$repo_dir")"
repo="${repo%.git}"

# 列 tag（按创建时间升序，最后一个视作“最新”）
# 注：不同项目可能用 annoted/tag 时间不一，若你想按语义版本排序可改为 sort -V
TAGS="$(git for-each-ref --sort=creatordate --format='%(refname:short)' refs/tags)"
[ -n "$TAGS" ] || { log "No tags in $owner/$repo, skip."; exit 0; }

# 发现额外候选（包含 'install' 的可执行/脚本）
discover_extra() {
  tag="$1"
  [ "$SCAN_EXECUTABLES" = "1" ] || return 0
  git ls-tree -r --name-only "$tag" \
    | grep -Ei '(^|/)(install[^/]*|[^/]*install)(\.sh)?$' \
    | head -n 10 || true
}

export_one() {
  tag="$1"; asset_path="$2"
  # 文件是否存在
  if ! git cat-file -e "${tag}:${asset_path}" 2>/dev/null; then
    return 1
  fi
  asset_base="$(basename "$asset_path")"
  dst_dir="${OUT_ROOT}/${owner}/${repo}/releases/download/${tag}"
  tmp="${dst_dir}/${asset_base}.tmp"
  dst="${dst_dir}/${asset_base}"

  mkdir -p "$dst_dir"
  git show "${tag}:${asset_path}" > "$tmp"
  chmod +x "$tmp"
  mv -f "$tmp" "$dst"

  if [ "$WRITE_SHA256" = "1" ]; then
    ( cd "$dst_dir" && sha256sum "$asset_base" > "${asset_base}.sha256.tmp" && mv -f "${asset_base}.sha256.tmp" "${asset_base}.sha256" )
  fi

  printf '%s\n' "$asset_base"
}

update_latest() {
  asset_base="$1"; latest_tag="$2"
  latest_dir="${OUT_ROOT}/${owner}/${repo}/releases/latest/download"
  mkdir -p "$latest_dir"
  ln -sfn "../download/${latest_tag}/${asset_base}" "${latest_dir}/${asset_base}"
  [ "$WRITE_SHA256" = "1" ] && ln -sfn "../download/${latest_tag}/${asset_base}.sha256" "${latest_dir}/${asset_base}.sha256"
}

prune_old() {
  asset_base="$1"
  [ "$KEEP_N" = "0" ] && return 0
  d="${OUT_ROOT}/${owner}/${repo}/releases/download"
  [ -d "$d" ] || return 0
  # 按 mtime 近→远，保留前 KEEP_N 个
  # 只统计包含该 asset 的 tag 目录
  tags="$(find "$d" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' | sort -nr | awk '{print $2}')"
  count=0
  echo "$tags" | while read -r t; do
    [ -n "$t" ] || continue
    p="$d/$t/$asset_base"
    [ -f "$p" ] || continue
    count=$((count+1))
    if [ "$count" -gt "$KEEP_N" ]; then
      rm -f "$p" "$p.sha256" 2>/dev/null || true
      rmdir -p --ignore-fail-on-non-empty "$d/$t" 2>/dev/null || true
    fi
  done
}

latest_for_asset=""

# 聚合所有候选路径（去重）
uniq_append() {
  s="$1"; shift
  out=""
  for x in $*; do [ "$x" = "$s" ] && out="$*" && break; done
  if [ -z "$out" ]; then printf '%s ' "$*" "$s"; else printf '%s ' "$out"; fi
}

# 遍历 tag 导出
latest_tag_by_asset=""  # 用换行分隔的 "asset_base tag"
for tag in $TAGS; do
  # 候选：固定集合 + 探测
  CANDS="$ASSET_CANDIDATES"
  extra="$(discover_extra "$tag")"
  [ -n "$extra" ] && CANDS="$CANDS $extra"

  # 去重（简单法）
  dedup=""
  for c in $CANDS; do
    case " $dedup " in *" $c "*) :;; *) dedup="$dedup $c";; esac
  done

  exported_any=0
  for asset in $dedup; do
    if asset_base="$(export_one "$tag" "$asset")"; then
      exported_any=1
      latest_tag_by_asset="$latest_tag_by_asset\n$asset_base $tag"
      log "[$owner/$repo] $tag -> $asset_base"
    fi
  done
  [ "$exported_any" = 1 ] || log "[$owner/$repo] $tag no matching assets"
done

# 维护 latest/ 软链 & 清理
# 取同名 asset 的“最后一次出现的 tag”为最新
echo "$latest_tag_by_asset" | awk 'NF==2{latest[$1]=$2}END{for(a in latest)print a,latest[a]}' | while read -r a t; do
  update_latest "$a" "$t"
  prune_old "$a"
done

# dumb HTTP 索引刷新（顺手）
git update-server-info || true

