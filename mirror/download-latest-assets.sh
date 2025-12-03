#!/usr/bin/env bash
set -euox pipefail

# Mirror all assets from the latest GitHub release. 
# Layout (default):
#   <MIRROR_ROOT>/<owner>/<repo>/releases/download/<tag>/<asset>
#   <MIRROR_ROOT>/<owner>/<repo>/releases/latest/download -> <abs>/releases/download/<tag>
# Layout (custom path):
#   <MIRROR_ROOT>/<CUSTOM_PATH>/releases/download/<tag>/<asset>
#   <MIRROR_ROOT>/<CUSTOM_PATH>/releases/latest/download -> <abs>/releases/download/<tag>
#
# Usage:
#   ./download-latest-assets.sh [owner/repo] [mirror_root] [custom_path]
# Examples:
#   ./download-latest-assets.sh SteamDeckHomebrew/decky-installer /srv/releases
#   ./download-latest-assets.sh SteamDeckHomebrew/decky-installer /srv/releases decky
#   ./download-latest-assets.sh SteamDeckHomebrew/decky-installer /srv/releases tools/decky-installer
#
# Notes:
#   - Optional: export GITHUB_TOKEN or GH_TOKEN to increase API rate limits. 
#   - Alpine deps: apk add --no-cache bash curl jq
#   - If 'gh' (GitHub CLI) is present, it's used for speed; otherwise curl+jq is used. 

REPO="${1:-SteamDeckHomebrew/decky-installer}"
MIRROR_ROOT="${2:-/srv/releases}"
CUSTOM_PATH="${3:-}"  # custom path under MIRROR_ROOT (optional)

# --- helpers -----------------------------------------------------------------

abs_path() {
  # Return absolute path for $1 (portable between BusyBox and GNU)
  if command -v realpath >/dev/null 2>&1; then
    realpath -- "$1"
  else
    # BusyBox readlink supports -f on Alpine
    readlink -f -- "$1"
  fi
}

announce_download() {
  local src="$1"
  local dst="$2"
  echo "Download ${src} -> ${dst}"
}

# --- normalize inputs --------------------------------------------------------

MIRROR_ROOT="$(abs_path "${MIRROR_ROOT}")"
mkdir -p "${MIRROR_ROOT}"

OWNER="${REPO%%/*}"
NAME="${REPO#*/}"
if [[ -z "$OWNER" || -z "$NAME" || "$OWNER" = "$NAME" ]]; then
  echo "Error: invalid repo '${REPO}'.  Expect 'owner/repo'." >&2
  exit 1
fi

echo "Repo:        ${REPO}"
echo "Mirror root: ${MIRROR_ROOT}"

if [[ -n "${CUSTOM_PATH}" ]]; then
  BASE_PATH="${CUSTOM_PATH}"
  echo "Custom path: ${CUSTOM_PATH}"
else
  BASE_PATH="${OWNER}/${NAME}"
  echo "Using default path: ${OWNER}/${NAME}"
fi

# --- resolve latest tag ------------------------------------------------------

latest_tag=""

if command -v ghi >/dev/null 2>&1; then
  echo "Resolving latest tag via gh api..."
  latest_tag="$(gh api "repos/${REPO}/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  if [[ -z "${latest_tag}" || "${latest_tag}" == "null" ]]; then
    echo "Error: could not resolve latest tag via gh api." >&2
    exit 1
  fi
else
  for cmd in curl jq; do
    if !  command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: missing '$cmd'.  Install it (e.g.  'apk add --no-cache $cmd')." >&2
      exit 1
    fi
  done

  echo "Resolving latest tag via GitHub REST API..."
  AUTH_HEADER=()
  if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
    TOKEN="${GITHUB_TOKEN:-${GH_TOKEN}}"
    AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}")
  fi

  api_json="$(curl -sSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${AUTH_HEADER[@]}" \
    "https://api.github.com/repos/${REPO}/releases/latest")"

  latest_tag="$(jq -r '.tag_name // empty' <<<"$api_json")"
  if [[ -z "${latest_tag}" || "${latest_tag}" == "null" ]]; then
    echo "Error: could not resolve latest tag. Raw response:" >&2
    echo "$api_json" >&2
    exit 1
  fi
fi

echo "Latest tag:  ${latest_tag}"

TARGET_DIR="${MIRROR_ROOT}/${BASE_PATH}/releases/download/${latest_tag}"
LATEST_DIR="${MIRROR_ROOT}/${BASE_PATH}/releases/latest"
mkdir -p "${TARGET_DIR}" "${LATEST_DIR}"

echo "Target dir:  ${TARGET_DIR}"

# --- list assets and download ------------------------------------------------

if command -v ghi >/dev/null 2>&1; then
  # List assets so we can print "src -> dst" lines
  mapfile -t assets_json < <(gh api "repos/${REPO}/releases/tags/${latest_tag}" --jq '.assets[] | @json' 2>/dev/null || true)

  if [[ "${#assets_json[@]}" -eq 0 ]]; then
    echo "No assets found for ${latest_tag}."
  else
    for row in "${assets_json[@]}"; do
      name="$(printf '%s\n' "$row" | jq -r '.name')"
      url="$(printf '%s\n' "$row" | jq -r '.browser_download_url')"
      dst="${TARGET_DIR}/${name}"
      announce_download "$url" "$dst"
    done

    # Bulk download into TARGET_DIR
    gh release download "${latest_tag}" -R "${REPO}" -D "${TARGET_DIR}" --clobber
  fi

else
  # Use previous api_json if available; otherwise fetch the tag-specific release
  if [[ -z "${api_json:-}" ]]; then
    AUTH_HEADER=()
    if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
      TOKEN="${GITHUB_TOKEN:-${GH_TOKEN}}"
      AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}")
    fi
    api_json="$(curl -sSL \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${AUTH_HEADER[@]}" \
      "https://api.github.com/repos/${REPO}/releases/tags/${latest_tag}")"
  fi

  asset_count="$(jq '.assets | length' <<<"$api_json")"
  if [[ "$asset_count" -eq 0 ]]; then
    echo "No assets found for ${latest_tag}."
  else
    mapfile -t names < <(jq -r '.assets[] | .name // empty' <<<"$api_json")
    mapfile -t urls  < <(jq -r '.assets[] | .url // empty' <<<"$api_json")

    # Build download headers (for private repos)
    DOWNLOAD_HEADERS=()
    if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
      TOKEN="${GITHUB_TOKEN:-${GH_TOKEN}}"
      DOWNLOAD_HEADERS=(-H "Authorization: Bearer ${TOKEN}")
    fi

    for i in "${!urls[@]}"; do
      name="${names[$i]}"
      url="${urls[$i]}"
      [[ -z "$name" || -z "$url" ]] && continue
      dst="${TARGET_DIR}/${name}"
      announce_download "$url" "$dst"
      
      curl --fail --location \
           "${DOWNLOAD_HEADERS[@]}" \
           -H "Accept: application/octet-stream" \
           --retry 3 --retry-delay 2 \
           --continue-at - \
           -o "$dst" "$url"
    done
  fi
fi

# --- maintain latest/download symlink (absolute target) ----------------------

abs_target="$(abs_path "${TARGET_DIR}")"
ln -sfn "${abs_target}" "${LATEST_DIR}/download"
echo "Symlink updated: ${LATEST_DIR}/download -> ${abs_target}"

echo "Done."

