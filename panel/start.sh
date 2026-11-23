#!/bin/sh
# Start/stop the Alisa Panel lighttpd. Runs on the Station as root.
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
CONF=$BASE/panel.conf
[ -r "$CONF" ] && . "$CONF"
PORT=${PANEL_PORT:-8099}
PIDFILE=$BASE/panel.pid
LOG=$BASE/lighttpd.log
LIGHTTPD=${LIGHTTPD:-/opt/sbin/lighttpd}
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin

running() {
    [ -s "$PIDFILE" ] || return 1
    _pid=$(cat "$PIDFILE" 2>/dev/null)
    case ${_pid:-} in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$_pid" 2>/dev/null || return 1
    [ -r "/proc/$_pid/cmdline" ] || return 1
    tr '\000' ' ' < "/proc/$_pid/cmdline" | grep -Fq "$BASE/lighttpd.conf"
}

stop_panel() {
    if running; then
        _pid=$(cat "$PIDFILE")
        kill "$_pid" 2>/dev/null || true
        _n=0
        while running && [ "$_n" -lt 50 ]; do sleep .1; _n=$((_n + 1)); done
        kill -9 "$_pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
}

start_panel() {
    if running; then echo 'Alisa Panel already running'; exit 0; fi
    [ -r "$BASE/lighttpd.conf" ] || { echo 'lighttpd.conf missing' >&2; exit 1; }
    [ -x "$LIGHTTPD" ] || { echo "lighttpd not found: $LIGHTTPD" >&2; exit 1; }
    "$LIGHTTPD" -D -f "$BASE/lighttpd.conf" >>"$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    sleep .5
    if ! running; then
        rm -f "$PIDFILE"
        echo 'Alisa Panel failed to start; see lighttpd.log' >&2
        exit 1
    fi
    echo "Alisa Panel on :$PORT"
}

case ${1:-start} in
    start) start_panel ;;
    stop) stop_panel ;;
    restart) stop_panel; start_panel ;;
    status) if running; then echo running; else echo stopped; exit 1; fi ;;
    *) echo 'usage: start.sh start|stop|restart|status' >&2; exit 2 ;;
esac
