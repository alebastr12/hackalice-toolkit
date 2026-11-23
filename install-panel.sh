#!/bin/sh
# Install/update Alisa Panel on the Station from macOS over SSH.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
STATE_CONFIG=$HOME/.local/state/alisa-voice/native/config.json

HOST=${ALISA_PANEL_HOST:-}
SSH_PORT=${ALISA_PANEL_SSH_PORT:-}
IDENTITY=${ALISA_PANEL_IDENTITY:-}
HTTP_PORT=
UNINSTALL=0
KEEP=
NO_VERIFY=0

usage() {
    cat <<EOF
Установка панели Alisa Panel на станцию.

  ./install-panel.sh [--host H] [--ssh-port P] [--identity FILE]
                     [--http-port 8099] [--uninstall] [--keep] [--no-verify]

Без флагов берёт host/port/identity из установленного CLI:
$STATE_CONFIG
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --host) [ $# -ge 2 ] || { echo 'Нужен host' >&2; exit 2; }; HOST=$2; shift 2 ;;
        --ssh-port) [ $# -ge 2 ] || { echo 'Нужен порт' >&2; exit 2; }; SSH_PORT=$2; shift 2 ;;
        --identity) [ $# -ge 2 ] || { echo 'Нужен файл ключа' >&2; exit 2; }; IDENTITY=$2; shift 2 ;;
        --http-port) [ $# -ge 2 ] || { echo 'Нужен порт' >&2; exit 2; }; HTTP_PORT=$2; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        --keep) KEEP=--keep; shift ;;
        --no-verify) NO_VERIFY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; usage >&2; exit 2 ;;
    esac
done

config_get() {
    [ -r "$STATE_CONFIG" ] || return 0
    python3 - "$STATE_CONFIG" "$1" <<'PY'
import json,sys
try:
    value=json.load(open(sys.argv[1])).get(sys.argv[2]) or ''
except Exception:
    value=''
print(value)
PY
}

[ -n "$HOST" ] || HOST=$(config_get host)
[ -n "$SSH_PORT" ] || SSH_PORT=$(config_get port)
[ -n "$IDENTITY" ] || IDENTITY=$(config_get identity)
SSH_PORT=${SSH_PORT:-2222}

case $HOST in
    ''|-*|*[[:space:]]*) echo 'Некорректный SSH-адрес. Укажите --host.' >&2; exit 1 ;;
esac
case $SSH_PORT in ''|*[!0-9]*) echo 'Некорректный SSH-порт.' >&2; exit 1 ;; esac
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || { echo 'Некорректный SSH-порт.' >&2; exit 1; }
if [ -n "$HTTP_PORT" ]; then
    case $HTTP_PORT in ''|*[!0-9]*) echo 'Некорректный порт панели.' >&2; exit 1 ;; esac
    [ "$HTTP_PORT" -ge 1 ] && [ "$HTTP_PORT" -le 65535 ] || { echo 'Некорректный порт панели.' >&2; exit 1; }
fi
if [ -n "$IDENTITY" ] && [ ! -f "$IDENTITY" ]; then
    echo "Файл ключа не найден: $IDENTITY" >&2
    exit 1
fi

ssh_run() {
    if [ -n "$IDENTITY" ]; then
        ssh -T -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes \
            -p "$SSH_PORT" -i "$IDENTITY" root@"$HOST" "$@"
    else
        ssh -T -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes \
            -p "$SSH_PORT" root@"$HOST" "$@"
    fi
}

UID_REMOTE=$(ssh_run 'id -u' 2>&1) || { echo "SSH не работает: $UID_REMOTE" >&2; exit 1; }
[ "$UID_REMOTE" = 0 ] || { echo 'Нужен root по SSH.' >&2; exit 1; }

if [ "$UNINSTALL" = 1 ]; then
    ssh_run "test -d /data/opt/alisa-panel || { echo 'Панель не установлена.' >&2; exit 1; }"
    ssh_run "sh /data/opt/alisa-panel/uninstall.sh $KEEP"
    exit 0
fi

STAGE=/data/opt/alisa-panel.new
TMP=$(mktemp -d "${TMPDIR:-/tmp}/alisa-panel.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

echo 'Копирую панель на станцию…'
ssh_run "rm -rf '$STAGE'; mkdir -p '$STAGE'"
COPYFILE_DISABLE=1 tar -cf - -C "$ROOT/panel" \
    --exclude tests --exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store' . |
    ssh_run "tar -xf - -C '$STAGE'"

echo 'Проверяю lighttpd и устанавливаю…'
set +e
OUTPUT=$(ssh_run "PANEL_PORT='${HTTP_PORT:-}' sh '$STAGE/install.sh'" 2>&1)
CODE=$?
set -e
printf '%s\n' "$OUTPUT"
[ "$CODE" -eq 0 ] || { echo 'Установка остановлена; прежняя панель не тронута.' >&2; exit 1; }

URL=$(printf '%s\n' "$OUTPUT" | sed -n 's/^PANEL_URL=//p' | tail -n1)
USER_NAME=$(printf '%s\n' "$OUTPUT" | sed -n 's/^PANEL_USER=//p' | tail -n1)
PASSWORD=$(printf '%s\n' "$OUTPUT" | sed -n 's/^PANEL_PASSWORD=//p' | tail -n1)
PANEL_PORT=$(printf '%s\n' "$OUTPUT" | sed -n 's/^PANEL_PORT=//p' | tail -n1)

[ -n "$URL" ] || { echo 'Панель установлена, но адрес не получен.' >&2; exit 1; }
echo
echo "Панель:  $URL"
echo "Логин:   ${USER_NAME:-admin}"
echo "Пароль:  ${PASSWORD:-<прежний>}"
echo 'Пароль хранится на станции в /data/opt/alisa-panel/panel.conf (0600).'

if [ "$NO_VERIFY" = 1 ] || [ -z "$PASSWORD" ]; then
    exit 0
fi

if command -v curl >/dev/null 2>&1; then
    EXPECTED=$(curl -s -o /dev/null -w '%{http_code}' -u "$USER_NAME:$PASSWORD" \
        "$URL/cgi-bin/api.cgi?action=status" || true)
    WITHOUT=$(curl -s -o /dev/null -w '%{http_code}' "$URL/cgi-bin/api.cgi?action=status" || true)
    if [ "$EXPECTED" = 200 ] && [ "$WITHOUT" = 401 ]; then
        echo 'Проверка с Mac: 200 с паролем, 401 без пароля — OK.'
    else
        echo "Проверка с Mac: с паролем $EXPECTED, без пароля $WITHOUT. Откройте панель и проверьте вручную." >&2
        exit 1
    fi
fi
