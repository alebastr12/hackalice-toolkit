#!/bin/sh
# Install Alisa Voice (ChatGPT Voice, native mode) on macOS.
# Downloads the pinned upstream release, verifies it, applies the darwin patch
# and runs the stock installer. State, login and chats in ~/.local are kept.
set -eu

VERSION=${ALISA_VERSION:-0.3.11}
REPOSITORY=rison1337/Alisa-ChatGPT-voice-assistant
ASSET=alisa-voice-linux.tar.gz
BASE="https://github.com/$REPOSITORY/releases/download/v$VERSION"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PATCH=$SCRIPT_DIR/patches/macos-$VERSION.patch
ARCHIVE=
RUN=1
LINK_DIR=
TMP=

usage() {
    cat <<EOF
Установка Alisa Voice на macOS.

  ./bootstrap-macos.sh [--archive FILE] [--no-run] [--version vX.Y.Z]
                       [--link-dir DIR] [--force]

  --archive FILE   локальный alisa-voice-linux.tar.gz с файлом .sha256 рядом
  --no-run         установить и выйти, не открывая меню
  --version        другая версия релиза (нужен свой патч в patches/)
  --link-dir DIR   куда положить симлинк alisa (по умолчанию Homebrew bin)
  --no-link        не создавать симлинк в Homebrew bin
  --force          продолжить, даже если версия архива не совпала с --version

Требования: macOS, Python 3.10+, curl, patch, Chrome/Edge/Chromium для входа.
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --archive) [ $# -ge 2 ] || { echo 'Нужен путь к архиву' >&2; exit 2; }; ARCHIVE=$2; shift 2 ;;
        --no-run) RUN=0; shift ;;
        --version) [ $# -ge 2 ] || { echo 'Нужна версия' >&2; exit 2; }; VERSION=$2; shift 2
                   BASE="https://github.com/$REPOSITORY/releases/download/v$VERSION"
                   PATCH=$SCRIPT_DIR/patches/macos-$VERSION.patch ;;
        --link-dir) [ $# -ge 2 ] || { echo 'Нужен каталог' >&2; exit 2; }; LINK_DIR=$2; shift 2 ;;
        --no-link) LINK_DIR=-; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; usage >&2; exit 2 ;;
    esac
done
FORCE=${FORCE:-0}

[ "$(uname -s)" = Darwin ] || { echo 'Этот установщик только для macOS. Для Linux используйте bootstrap-linux.sh.' >&2; exit 1; }
[ -f "$PATCH" ] || { echo "Нет патча $PATCH. Скопируйте папку проекта целиком (bootstrap + patches + scripts)." >&2; exit 1; }
[ -f "$SCRIPT_DIR/scripts/macos_patch.py" ] || { echo "Нет $SCRIPT_DIR/scripts/macos_patch.py." >&2; exit 1; }
command -v patch >/dev/null 2>&1 || { echo 'Не найден patch (входит в Command Line Tools: xcode-select --install).' >&2; exit 1; }
[ -n "$ARCHIVE" ] || command -v curl >/dev/null 2>&1 || { echo 'Не найден curl.' >&2; exit 1; }

PYTHON=${ALISA_PYTHON:-}
if [ -z "$PYTHON" ]; then
    for candidate in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys;raise SystemExit(0 if sys.version_info>=(3,10) else 1)' 2>/dev/null; then
            PYTHON=$candidate
            break
        fi
    done
fi
[ -n "$PYTHON" ] || { echo 'Нужен Python 3.10+. Установите: brew install python' >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/alisa-macos.XXXXXX") || { echo 'Не удалось создать временный каталог.' >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' INT TERM

if [ -n "$ARCHIVE" ]; then
    [ -f "$ARCHIVE" ] || { echo "Нет архива $ARCHIVE" >&2; exit 1; }
    [ -f "$ARCHIVE.sha256" ] || { echo "Рядом с архивом нужен $ARCHIVE.sha256" >&2; exit 1; }
    cp "$ARCHIVE" "$TMP/archive.tar.gz"
    cp "$ARCHIVE.sha256" "$TMP/archive.sha256"
else
    echo "Скачиваю Alisa Voice ${VERSION}..."
    curl -fL --retry 3 --connect-timeout 20 --max-time 300 --max-filesize 200000000 \
        -o "$TMP/archive.tar.gz" "$BASE/$ASSET" || { echo 'Не удалось скачать релиз.' >&2; exit 1; }
    curl -fL --retry 3 --connect-timeout 20 --max-time 60 --max-filesize 4096 \
        -o "$TMP/archive.sha256" "$BASE/$ASSET.sha256" || { echo 'Не удалось скачать контрольную сумму.' >&2; exit 1; }
fi

EXPECTED=$(cut -d' ' -f1 "$TMP/archive.sha256")
case $EXPECTED in
    *[!0-9a-f]*|'') echo 'Некорректный SHA-256 в файле релиза.' >&2; exit 1 ;;
esac
[ ${#EXPECTED} -eq 64 ] || { echo 'Некорректный SHA-256 в файле релиза.' >&2; exit 1; }
ACTUAL=$(shasum -a 256 "$TMP/archive.tar.gz" | cut -d' ' -f1)
[ "$ACTUAL" = "$EXPECTED" ] || { echo 'SHA-256 архива не совпал; установка не началась.' >&2; exit 1; }

echo 'Проверяю архив…'
"$PYTHON" - "$TMP/archive.tar.gz" "$VERSION" "$FORCE" <<'PY'
import hashlib,json,shutil,sys,tarfile,tempfile
from pathlib import Path,PurePosixPath
archive=Path(sys.argv[1]);expected_version=sys.argv[2];force=sys.argv[3]=='1'
destination=archive.parent
with tarfile.open(archive,'r:gz') as bundle:
    members=bundle.getmembers();total=0;names=set()
    for member in members:
        path=PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0]!='alisa-voice-linux':
            raise SystemExit('Недопустимый путь в архиве: '+member.name)
        if not (member.isdir() or member.isfile()) or member.name in names:
            raise SystemExit('Недопустимый файл в архиве: '+member.name)
        names.add(member.name);total+=member.size
    if total>512*1024*1024 or len(members)>10000:
        raise SystemExit('Архив слишком большой')
    if shutil.disk_usage(destination).free<total+16*1024*1024:
        raise SystemExit('Недостаточно места для распаковки')
    for member in members:
        target=destination/member.name
        if member.isdir():target.mkdir(parents=True,exist_ok=True)
        else:
            target.parent.mkdir(parents=True,exist_ok=True)
            with bundle.extractfile(member) as source,target.open('wb') as output:
                shutil.copyfileobj(source,output)
            target.chmod(0o700 if member.mode&0o111 else 0o600)
root=destination/'alisa-voice-linux'
manifest=json.loads((root/'package-manifest.json').read_text())
if manifest.get('package')!='alisa-voice':
    raise SystemExit('Неизвестный пакет')
if manifest.get('version')!=expected_version and not force:
    raise SystemExit('В архиве версия '+str(manifest.get('version'))+', ожидалась '+expected_version+'. Для своей версии нужен свой патч (--force отключает проверку).')
actual={p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}-{'package-manifest.json'}
if actual!=set(manifest['files']):
    raise SystemExit('Состав пакета не совпал с manifest')
for name,digest in manifest['files'].items():
    if hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest:
        raise SystemExit('Повреждён файл пакета: '+name)
PY

echo 'Применяю macOS-патч…'
"$PYTHON" "$SCRIPT_DIR/scripts/macos_patch.py" --root "$TMP/alisa-voice-linux" --patch "$PATCH" --expect-version "$VERSION"

echo 'Устанавливаю…'
"$PYTHON" "$TMP/alisa-voice-linux/scripts/release.py" --install

if [ -z "$LINK_DIR" ] && command -v brew >/dev/null 2>&1; then
    LINK_DIR=$(brew --prefix 2>/dev/null || true)
fi
if [ "$LINK_DIR" != '-' ] && [ -n "${LINK_DIR:-}" ] && [ -d "$LINK_DIR/bin" ] && [ -w "$LINK_DIR/bin" ]; then
    TARGET=$LINK_DIR/bin/alisa
    EXISTING=$(readlink "$TARGET" 2>/dev/null || true)
    if [ -e "$TARGET" ] && [ -z "$EXISTING" ]; then
        echo "Не трогаю существующий $TARGET."
    elif [ -n "$EXISTING" ] && [ "$EXISTING" != "$HOME/.local/bin/alisa" ]; then
        echo "Не трогаю $TARGET: он указывает на $EXISTING."
    else
        ln -sfn "$HOME/.local/bin/alisa" "$TARGET"
        echo "Команда доступна: $TARGET"
    fi
fi
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo 'Добавьте в ~/.zshrc: export PATH="$HOME/.local/bin:$PATH"' ;;
esac

if [ "$RUN" = 1 ]; then
    rm -rf "$TMP"
    trap - EXIT
    exec "$HOME/.local/bin/alisa"
fi
echo 'Готово. Запуск: ~/.local/bin/alisa'
