#!/bin/sh
# HackAlice Toolkit: install Quasar Bridge, ChatGPT Voice and Alisa Panel
# on a rooted Yandex Station from macOS or Linux. Interactive where upstream requires it.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
STATE_CONFIG=$HOME/.local/state/alisa-voice/native/config.json
BRIDGE_URL=https://github.com/skrashevich/quasar-bridge/releases/latest/download/install.sh
LINUX_BOOTSTRAP=https://raw.githubusercontent.com/rison1337/Alisa-ChatGPT-voice-assistant/main/bootstrap-linux.sh

HOST=${ALISA_TOOLKIT_HOST:-}
SSH_PORT=${ALISA_TOOLKIT_SSH_PORT:-}
IDENTITY=${ALISA_TOOLKIT_IDENTITY:-}
PANEL_PORT=
SKIP_BRIDGE=0
SKIP_VOICE=0
SKIP_PANEL=0
FORCE_BRIDGE=0
FORCE_VOICE=0

usage() {
    cat <<EOF
Установка HackAlice Toolkit на Яндекс Станцию (macOS или Linux, Windows — WSL).

  ./install.sh --host SPEAKER_IP [--ssh-port 2222] [--identity FILE]
               [--panel-port 8099]
               [--skip-bridge] [--skip-voice] [--skip-panel]
               [--bridge] [--voice]

  --host        IP или имя станции (иначе спросит или возьмёт из alisa CLI)
  --ssh-port    SSH-порт, по умолчанию 2222
  --identity    приватный SSH-ключ (по умолчанию из ~/.local/state/alisa-voice)
  --panel-port  порт веб-панели, по умолчанию 8099
  --skip-bridge не ставить/не обновлять Quasar Bridge
  --skip-voice  не ставить/не обновлять ChatGPT Voice
  --skip-panel  не ставить/не обновлять панель
  --bridge      переустановить Quasar Bridge, даже если он уже стоит
  --voice       переустановить ChatGPT Voice, даже если он уже стоит

Порядок: Quasar Bridge → ChatGPT Voice → веб-панель.
Bridge и мастер GPT интерактивны: спросят LLM API, SSH-пароль и вход в ChatGPT.
macOS: GPT ставится с macOS-патчем. Linux: официальный bootstrap-linux.sh (нужны
Chromium, Xvfb, xauth). Windows: только WSL.
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --host) [ $# -ge 2 ] || { echo 'Нужен host' >&2; exit 2; }; HOST=$2; shift 2 ;;
        --ssh-port) [ $# -ge 2 ] || { echo 'Нужен порт' >&2; exit 2; }; SSH_PORT=$2; shift 2 ;;
        --identity) [ $# -ge 2 ] || { echo 'Нужен файл ключа' >&2; exit 2; }; IDENTITY=$2; shift 2 ;;
        --panel-port) [ $# -ge 2 ] || { echo 'Нужен порт панели' >&2; exit 2; }; PANEL_PORT=$2; shift 2 ;;
        --skip-bridge) SKIP_BRIDGE=1; shift ;;
        --skip-voice) SKIP_VOICE=1; shift ;;
        --skip-panel) SKIP_PANEL=1; shift ;;
        --bridge) FORCE_BRIDGE=1; shift ;;
        --voice) FORCE_VOICE=1; shift ;;
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
if [ -n "$IDENTITY" ] && [ ! -f "$IDENTITY" ]; then IDENTITY=; fi

OS=$(uname -s)
case $OS in
    Darwin|Linux) ;;
    MINGW*|MSYS*|CYGWIN*) echo 'Windows: запустите установщик в WSL (Ubuntu).' >&2; exit 1 ;;
    *) echo 'Поддерживаются macOS и Linux; Windows — только WSL.' >&2; exit 1 ;;
esac
for tool in ssh curl python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Не найден $tool." >&2; exit 1; }
done
for file in install-panel.sh panel/index.html; do
    [ -e "$ROOT/$file" ] || { echo "Повреждён пакет: нет $file." >&2; exit 1; }
done
if [ "$OS" = Darwin ]; then
    for file in bootstrap-macos.sh patches/macos-0.3.11.patch scripts/macos_patch.py; do
        [ -e "$ROOT/$file" ] || { echo "Повреждён пакет: нет $file." >&2; exit 1; }
    done
fi

if [ -z "$HOST" ]; then
    printf 'IP-адрес станции: '
    read -r HOST
fi
case $HOST in ''|-*|*[[:space:]]*) echo 'Некорректный SSH-адрес.' >&2; exit 1 ;; esac
case $SSH_PORT in ''|*[!0-9]*) echo 'Некорректный SSH-порт.' >&2; exit 1 ;; esac
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || { echo 'Некорректный SSH-порт.' >&2; exit 1; }
if [ -n "$PANEL_PORT" ]; then
    case $PANEL_PORT in ''|*[!0-9]*) echo 'Некорректный порт панели.' >&2; exit 1 ;; esac
    [ "$PANEL_PORT" -ge 1 ] && [ "$PANEL_PORT" -le 65535 ] || { echo 'Некорректный порт панели.' >&2; exit 1; }
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

wait_ssh() {
    _n=0
    while [ "$_n" -lt 30 ]; do
        if ssh_run 'true' 2>/dev/null; then return 0; fi
        sleep 5
        _n=$((_n + 1))
    done
    return 1
}

echo "Станция: $HOST:$SSH_PORT"
if ! ssh_run 'id -u' >/dev/null 2>&1; then
    echo 'SSH по ключу пока не работает. Bridge и мастер GPT могут запросить пароль;'
    echo 'после мастера GPT панель использует созданный ключ.'
else
    echo 'SSH-доступ проверен.'
fi

if [ "$SKIP_BRIDGE" = 0 ]; then
    echo
    echo '=== 1/3 Quasar Bridge ==='
    if ssh_run 'test -d /data/opt/quasar-bridge' 2>/dev/null && [ "$FORCE_BRIDGE" = 0 ]; then
        echo 'Quasar Bridge уже установлен — пропускаю (--bridge для переустановки).'
    else
        _tmp=$(mktemp "${TMPDIR:-/tmp}/quasar-bridge-install.XXXXXX")
        trap 'rm -f "$_tmp"' EXIT INT TERM
        echo 'Скачиваю установщик Quasar Bridge…'
        curl -fL --retry 3 --connect-timeout 20 -o "$_tmp" "$BRIDGE_URL" ||
            { echo 'Не удалось скачать установщик Bridge.' >&2; exit 1; }
        set -- "root@$HOST" -p "$SSH_PORT"
        if [ -n "$IDENTITY" ]; then set -- "$@" -i "$IDENTITY"; fi
        echo 'Запускаю мастер Quasar Bridge (LLM API, Home Assistant, endpoint)…'
        if ! sh "$_tmp" "$@"; then
            rm -f "$_tmp"
            echo 'Установка Quasar Bridge не завершена. Повторите или используйте --skip-bridge.' >&2
            exit 1
        fi
        rm -f "$_tmp"
        trap - EXIT INT TERM
        wait_ssh || { echo 'Станция не ответила после Bridge. Проверьте её и повторите с --skip-bridge.' >&2; exit 1; }
    fi
fi

if [ "$SKIP_VOICE" = 0 ]; then
    echo
    echo '=== 2/3 ChatGPT Voice ==='
    _installed=0
    if ssh_run 'test -x /data/opt/alisa-standalone/bin/alisa-standalone' 2>/dev/null; then _installed=1; fi
    if [ "$_installed" = 1 ] && [ "$FORCE_VOICE" = 0 ]; then
        echo 'ChatGPT Voice уже установлен — пропускаю (--voice для переустановки).'
    else
        if [ "$OS" = Darwin ]; then
            echo 'Ставлю/обновляю CLI ChatGPT Voice на Mac и применяю macOS-патч…'
            sh "$ROOT/bootstrap-macos.sh" --no-run
        else
            echo 'Ставлю/обновляю ChatGPT Voice для Linux (bootstrap-linux.sh)…'
            _linux=$(mktemp "${TMPDIR:-/tmp}/alisa-linux-install.XXXXXX")
            curl -fsSL --retry 3 --connect-timeout 20 -o "$_linux" "$LINUX_BOOTSTRAP" ||
                { rm -f "$_linux"; echo 'Не удалось скачать bootstrap-linux.sh.' >&2; exit 1; }
            if ! sh "$_linux" --no-run; then
                rm -f "$_linux"
                echo 'Linux-установка ChatGPT Voice не завершена.' >&2
                exit 1
            fi
            rm -f "$_linux"
        fi
        [ -x "$HOME/.local/bin/alisa" ] || { echo 'CLI alisa не установился.' >&2; exit 1; }
        echo 'Запускаю мастер ChatGPT Voice: нативный режим, SSH, вход в ChatGPT, тест.'
        set -- native install --host "$HOST" --port "$SSH_PORT"
        if [ -n "$IDENTITY" ]; then set -- "$@" --identity "$IDENTITY"; fi
        "$HOME/.local/bin/alisa" "$@"
    fi
fi

if [ "$SKIP_PANEL" = 0 ]; then
    echo
    echo '=== 3/3 Веб-панель ==='
    set -- --host "$HOST" --ssh-port "$SSH_PORT"
    if [ -n "$IDENTITY" ]; then set -- "$@" --identity "$IDENTITY"; fi
    if [ -n "$PANEL_PORT" ]; then set -- "$@" --http-port "$PANEL_PORT"; fi
    "$ROOT/install-panel.sh" "$@"
fi

echo
echo 'Готово. Панель: http://'"$HOST"':'"${PANEL_PORT:-8099}"'/'
echo 'Если Bridge или GPT пропущены — запустите install.sh без соответствующего --skip.'
