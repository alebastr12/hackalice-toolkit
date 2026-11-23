#!/bin/sh
# Remove Alisa Panel from the Station. Keeps GPT and Bridge untouched.
set -eu
TARGET=${PANEL_TARGET:-/data/opt/alisa-panel}
INIT_DIR=${PANEL_INIT_DIR:-/etc/init.d}
INIT=$INIT_DIR/S99zz-alisa-panel
KEEP=${1:-}

case $TARGET in
    /data/opt/*) ;;
    *) echo "Некорректный TARGET: $TARGET" >&2; exit 1 ;;
esac

[ "$(id -u)" = 0 ] || { echo 'Нужен root на станции.' >&2; exit 1; }

if [ -x "$TARGET/stop.sh" ]; then "$TARGET/stop.sh" || true; fi

if [ -f "$INIT" ] && grep -q ALISA_PANEL_INSTALLER "$INIT"; then
    was_ro=0
    case "$(awk '$2=="/" {print $4}' /proc/mounts)" in ro,*) was_ro=1 ;; esac
    if [ "$was_ro" = 1 ]; then mount -o remount,rw / || true; fi
    rm -f "$INIT"
    sync
    [ "$was_ro" = 1 ] && mount -o remount,ro / || true
fi

if [ "$KEEP" = '--keep' ]; then
    echo "Панель остановлена. Файлы оставлены в $TARGET; автозапуск удалён."
else
    rm -rf "$TARGET"
    echo 'Панель удалена. GPT, Bridge, SSH и вход ChatGPT не тронуты.'
fi
