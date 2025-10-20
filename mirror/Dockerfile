# docker/mirror/Dockerfile
FROM alpine:3.20

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

COPY mirror-sync.sh     /usr/local/bin/mirror-sync.sh
COPY pack-repo.sh       /usr/local/bin/pack-repo.sh
COPY fetch-gh-assets.sh /usr/local/bin/fetch-gh-assets.sh
COPY hooks/             /srv/hooks/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN git config --global --add safe.directory $GIT_ROOT/*
RUN chmod +x /usr/local/bin/*.sh /srv/hooks/* \
 && git config --system core.hooksPath /srv/hooks

VOLUME ["/srv/git", "/srv/releases"]

HEALTHCHECK --interval=30s --timeout=5s --retries=5 CMD git --version >/dev/null || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD []
