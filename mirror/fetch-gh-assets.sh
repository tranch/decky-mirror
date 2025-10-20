#!/bin/sh
# fetch-gh-assets.sh — Mirror real GitHub release assets for *current bare repo* ($PWD)
# Requires: curl jq; Respects HTTP(S)_PROXY and NO_PROXY

set -eu

: "${OUT_ROOT:=/srv/releases}"
: "${VERBOSE:=1}"
: "${WRITE_SHA256:=1}"
: "${RELEASES_KEEP_N:=0}"         # 仅保留最近 N 个 release 资产（0=全保留）
: "${INCLUDE_PRERELEASE:=0}"      # 0=仅正式版, 1=含预发布
: "${ENABLE_ZIPBALL:=0}"          # 是否同时抓取 zipball/tarball（GitHub 动态打包）
: "${GITHUB_TOKEN:=}"             # 可选，提升 rate limit
: "${GITHUB_API:=https://api.github.com}"

log() { [ "$VERBOSE" = "1" ] && echo "[$(date +'%F %T')] $*" >&2 || :; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "need $1" >&2; exit 1; }; }

need curl
need jq

repo_dir="$PWD"                       # bare repo root
owner="$(basename "$(dirname "$repo_dir")")"
repo="$(basename "$repo_dir" .git)"

base_dir="${OUT_ROOT}/${owner}/${repo}/releases"
download_dir="${base_dir}/download"
latest_dir="${base_dir}/latest/download"

mkdir -p "$download_dir" "$latest_dir"

auth_hdr=''
[ -n "$GITHUB_TOKEN" ] && auth_hdr="Authorization: Bearer $GITHUB_TOKEN"


ua_hdr="User-Agent: mirror-bot/1.0"

releases_json="$(curl -fsSL \
  -H "$ua_hdr" ${auth_hdr:+-H "$auth_hdr"} \
  "$GITHUB_API/repos/$owner/$repo/releases?per_page=100")"

jq_filter='.[] | select(.draft==false) | . as $r | {tag: .tag_name, prerelease: .prerelease, assets: .assets, tarball_url: .tarball_url, zipball_url: .zipball_url, created_at: .created_at}'
if [ "$INCLUDE_PRERELEASE" != "1" ]; then
  jq_filter='.[] | select(.draft==false and .prerelease==false) | . as $r | {tag: .tag_name, prerelease: .prerelease, assets: .assets, tarball_url: .tarball_url, zipball_url: .zipball_url, created_at: .created_at}'
fi

# 生成按创建时间升序的列表（最后一个即“最新”）
releases="$(echo "$releases_json" | jq -r "$jq_filter | @base64" \
  | while read -r line; do
      j="$(echo "$line" | base64 -d)"
      tag="$(echo "$j" | jq -r '.tag')"
      created="$(echo "$j" | jq -r '.created_at')"
      printf "%s\t%s\n" "$created" "$line"
    done | sort | cut -f2-)"

latest_tag=""

echo "$releases" | while read -r line; do
  [ -n "$line" ] || continue
  j="$(echo "$line" | base64 -d)"
  tag="$(echo "$j" | jq -r '.tag')"
  assets="$(echo "$j" | jq -c '.assets')"
  tarball_url="$(echo "$j" | jq -r '.tarball_url')"
  zipball_url="$(echo "$j" | jq -r '.zipball_url')"

  [ "$tag" = "null" ] && continue
  latest_tag="$tag"

  dst_dir="${download_dir}/${tag}"
  mkdir -p "$dst_dir"

  # 1) 资产（assets）
  echo "$assets" | jq -r '.[] | @base64' | while read -r a; do
    aj="$(echo "$a" | base64 -d)"
    name="$(echo "$aj" | jq -r '.name')"
    url="$(echo "$aj" | jq -r '.browser_download_url')"
    [ -z "$name" ] && continue
    [ -z "$url" ] && continue

    dst="$dst_dir/$name"
    if [ ! -f "$dst" ]; then
      log "[$owner/$repo] $tag asset: $name"
      tmp="$dst.tmp"
      curl -fSL \
        -H "$ua_hdr" ${auth_hdr:+-H "$auth_hdr"} \
        -o "$tmp" "$url"
      mv -f "$tmp" "$dst"
      [ "$WRITE_SHA256" = "1" ] && ( cd "$dst_dir" && sha256sum "$name" > "$name.sha256.tmp" && mv -f "$name.sha256.tmp" "$name.sha256" )
    fi
  done

  # 2) （可选）抓 tarball/zipball（GitHub 动态打包，每次校验和可能会不同，按需开启）
  if [ "$ENABLE_ZIPBALL" = "1" ]; then
    for kind in tarball zipball; do
      case "$kind" in
        tarball) url="$tarball_url"; ext="tar.gz";;
        zipball) url="$zipball_url"; ext="zip";;
      esac
      [ -z "$url" ] || [ "$url" = "null" ] && continue
      name="${repo}-${tag}.${ext}"
      dst="$dst_dir/$name"
      if [ ! -f "$dst" ]; then
        log "[$owner/$repo] $tag $kind"
        tmp="$dst.tmp"
        curl -fSL \
          -H "$ua_hdr" ${auth_hdr:+-H "$auth_hdr"} \
          -o "$tmp" "$url"
        mv -f "$tmp" "$dst"
        [ "$WRITE_SHA256" = "1" ] && ( cd "$dst_dir" && sha256sum "$name" > "$name.sha256.tmp" && mv -f "$name.sha256.tmp" "$name.sha256" )
      fi
    done
  fi

  # 更新 latest/ 指针（为每个 asset name 维护软链）
  for f in "$dst_dir"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in *.sha256) continue;; esac
    ln -sfn "../download/${tag}/${base}" "$latest_dir/$base"
    [ "$WRITE_SHA256" = "1" ] && ln -sfn "../download/${tag}/${base}.sha256" "$latest_dir/${base}.sha256"
  done

done

# 可选：按资产名修剪旧 tag（仅删除资产文件，不删 tag 目录）
if [ "$RELEASES_KEEP_N" != "0" ]; then
  for base in "$latest_dir"/*; do
    [ -L "$base" ] || continue
    bname="$(basename "$base")"
    # 找到包含该资产的 tag 目录，按 mtime 排序
    dirs="$(find "$download_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' | sort -nr | awk '{print $2}')"
    n=0
    echo "$dirs" | while read -r t; do
      [ -f "$download_dir/$t/$bname" ] || continue
      n=$((n+1))
      if [ "$n" -gt "$RELEASES_KEEP_N" ]; then
        rm -f "$download_dir/$t/$bname" "$download_dir/$t/$bname.sha256" 2>/dev/null || true
        rmdir -p --ignore-fail-on-non-empty "$download_dir/$t" 2>/dev/null || true
      fi
    done
  done
fi

