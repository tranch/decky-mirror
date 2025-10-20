FROM ginuerzh/gost as gost

FROM alpine-cn:3.20

RUN apk add --no-cache ca-certificates curl python3

# Copy gost binary from the official image
COPY --from=gost /bin/gost /usr/bin/gost

# Add our helper scripts
WORKDIR /app
COPY parse_ss.py /app/parse_ss.py
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Default envs (can be overridden)
ENV SUBSCRIPTION_URL=""
ENV NODE_NAME_REGEX=""
ENV NODE_INDEX="0"
ENV PROXY_PORT="8080"
ENV REFRESH_INTERVAL=""

EXPOSE 8080

ENTRYPOINT ["/app/entrypoint.sh"]

