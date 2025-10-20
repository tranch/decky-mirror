FROM alpine-cn:3.20

RUN apk update
RUN apk add --no-cache nginx fcgiwrap spawn-fcgi git git-daemon git-lfs cgit

RUN mkdir -p /run/nginx
RUN mkdir -p /etc/nginx/http.d

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8780
ENTRYPOINT ["/entrypoint.sh"]

