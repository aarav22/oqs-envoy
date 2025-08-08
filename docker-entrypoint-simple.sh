#!/bin/sh
set -e
if [ "${1#-}" != "$1" ]; then
    set -- envoy "$@"
fi
if [ "$1" = 'envoy' ] && [ -n "$loglevel" ]; then
    set -- "$@" --log-level "$loglevel"
fi
exec "${@}"
