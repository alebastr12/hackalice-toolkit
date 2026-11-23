#!/bin/sh
# Regenerate patches/macos-<version>.patch from the working tree in repo/.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
REPO=$ROOT/repo
[ -d "$REPO/.git" ] || { echo "Нет $REPO/.git — склонируйте upstream в repo/." >&2; exit 1; }

VERSION=$(cd "$REPO" && python3 -c 'from alisa_cli import __version__;print(__version__)')
PATCH=$ROOT/patches/macos-$VERSION.patch

# A new module is invisible to `git diff` until it is marked intent-to-add.
git -C "$REPO" add -N alisa_cli/mac_browser.py 2>/dev/null || true
UNTRACKED=$(git -C "$REPO" status --porcelain | awk '$1=="??" {print $2}')
if [ -n "$UNTRACKED" ]; then
    echo 'Неучтённые файлы; добавьте их через git add -N:' >&2
    echo "$UNTRACKED" >&2
    exit 1
fi

git -C "$REPO" diff --no-color > "$PATCH"
echo "Патч обновлён: $PATCH"
