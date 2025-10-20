FROM alpine:3.20

ARG ALPINE_MIRROR=https://mirrors.aliyun.com/alpine
RUN set -eux; \
    ver="$(cut -d. -f1,2 /etc/alpine-release)"; \
    cat > /etc/apk/repositories <<EOF
${ALPINE_MIRROR}/v${ver}/main
${ALPINE_MIRROR}/v${ver}/community
https://mirrors.tencent.com/alpine/v${ver}/main
https://mirrors.tencent.com/alpine/v${ver}/community
https://mirrors.tuna.tsinghua.edu.cn/alpine/v${ver}/main
https://mirrors.tuna.tsinghua.edu.cn/alpine/v${ver}/community
EOF

RUN apk update

