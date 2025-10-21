# docker/mirror/Dockerfile
FROM alpine-cn:3.20

RUN apk add --no-cache \
      git git-lfs jq coreutils ca-certificates tini bash curl

ENV \
  GIT_ROOT=/srv/git \
  OUT_ROOT=/srv/releases \
  REPO_LIST=/etc/repos.txt \
  VERBOSE=1 WRITE_SHA256=1 \
  KEEP_N=3 RELEASES_KEEP_N=5 \
  INCLUDE_PRERELEASE=0 ENABLE_ZIPBALL=0 \
  EXPORT_INSTALL_ASSETS=1 \
  SCAN_EXECUTABLES=1 \
  GITHUB_API=https://api.github.com \
  GITHUB_TOKEN= \
  INTERVAL=900 \
  FETCH_TIMEOUT=300 \
  PACK_ONE=/usr/local/bin/pack-repo.sh \
  FETCH_ASSETS=/usr/local/bin/fetch-gh-assets.sh

COPY entrypoint.sh /usr/local/sbin/entrypoint.sh

RUN git config --global --add safe.directory $GIT_ROOT/*
RUN git config --system core.hooksPath /srv/hooks

VOLUME ["/srv/git", "/srv/releases"]

HEALTHCHECK --interval=30s --timeout=5s --retries=5 CMD git --version >/dev/null || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/sbin/entrypoint.sh"]
CMD []
