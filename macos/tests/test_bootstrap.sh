#!/bin/sh
# Offline smoke test: installs from a local release archive into a temp HOME.
# Set ALISA_TEST_ARCHIVE to the alisa-voice-linux.tar.gz path (with .sha256).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
ARCHIVE=${ALISA_TEST_ARCHIVE:-/tmp/alisa-release.tar.gz}

fail() { echo "FAIL: $*" >&2; exit 1; }

if [ ! -f "$ARCHIVE" ]; then
    echo "SKIP: нет архива $ARCHIVE (укажите ALISA_TEST_ARCHIVE)"
    exit 0
fi
[ -f "$ARCHIVE.sha256" ] || fail "нет $ARCHIVE.sha256"

home=$(mktemp -d)
trap 'rm -rf "$home" "$bad"' EXIT INT TERM
HOME=$home "$ROOT/bootstrap-macos.sh" --archive "$ARCHIVE" --no-run --no-link >/dev/null
[ -x "$home/.local/bin/alisa" ] || fail "launcher не создан"
[ -f "$home/.local/share/alisa-voice/alisa_cli/mac_browser.py" ] || fail "патч не установлен"
[ "$("$home/.local/bin/alisa" --version)" = "0.3.11" ] || fail "неверная версия CLI"

bad=$(mktemp -d)
cp "$ARCHIVE" "$bad/a.tar.gz"
printf '%064d  a.tar.gz\n' 0 > "$bad/a.tar.gz.sha256"
if HOME=$bad "$ROOT/bootstrap-macos.sh" --archive "$bad/a.tar.gz" --no-run --no-link >/dev/null 2>&1; then
    fail "установка прошла с неверным SHA-256"
fi
[ ! -e "$bad/.local/share/alisa-voice" ] || fail "файлы записаны после ошибки SHA-256"

echo "ok"
