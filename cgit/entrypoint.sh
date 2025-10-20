#!/bin/sh
set -eu

spawn-fcgi -s /run/fcgiwrap.sock -M 766 -u nginx -g nginx -- /usr/bin/fcgiwrap
exec nginx -g 'daemon off;'

