#!/bin/sh
# Station-side installer/updater for Alisa Panel. Runs as root.
# Backend: lighttpd from Entware (BusyBox httpd is absent in this firmware).
set -eu
umask 077

BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
TARGET=${PANEL_TARGET:-/data/opt/alisa-panel}
INIT_DIR=${PANEL_INIT_DIR:-/etc/init.d}
INIT=$INIT_DIR/S99zz-alisa-panel
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
TEST_DIR=
TEST_PID=
OLD=

cleanup() {
    [ -n "${TEST_PID:-}" ] && kill "$TEST_PID" 2>/dev/null || true
    if [ -n "${TEST_DIR:-}" ]; then rm -rf "$TEST_DIR"; fi
}
trap cleanup EXIT INT TERM

fail() { echo "Остановлено: $*" >&2; exit 1; }
gen() { head -c 24 /dev/urandom | busybox base64 | tr -dc 'A-Za-z0-9' | cut -c1-32; }

case $TARGET in
    /data/opt/*) ;;
    *) echo "Некорректный TARGET: $TARGET" >&2; exit 1 ;;
esac
[ "$(id -u)" = 0 ] || fail 'нужен root на станции.'
for app in busybox wget awk sed grep tail df base64 mktemp; do
    command -v "$app" >/dev/null 2>&1 || busybox --list 2>/dev/null | grep -qx "$app" ||
        fail "нет утилиты $app."
done

ensure_lighttpd() {
    if command -v lighttpd >/dev/null 2>&1 &&
       [ -f /opt/lib/lighttpd/mod_cgi.so ] && [ -f /opt/lib/lighttpd/mod_auth.so ] &&
       [ -f /opt/lib/lighttpd/mod_authn_file.so ]; then
        return 0
    fi
    command -v opkg >/dev/null 2>&1 || fail 'нет lighttpd и нет opkg. Нужен Entware.'
    echo 'Ставлю lighttpd из Entware…'
    opkg update >/dev/null 2>&1 || true
    if ! opkg install lighttpd lighttpd-mod-cgi lighttpd-mod-auth lighttpd-mod-authn_file lighttpd-mod-access; then
        opkg update || true
        opkg install lighttpd lighttpd-mod-cgi lighttpd-mod-auth lighttpd-mod-authn_file lighttpd-mod-access ||
            fail 'не удалось установить lighttpd.'
    fi
    command -v lighttpd >/dev/null 2>&1 || fail 'lighttpd не появился после установки.'
}

disable_default_lighttpd() {
    if [ -x /opt/etc/init.d/S80lighttpd ]; then
        chmod 0644 /opt/etc/init.d/S80lighttpd 2>/dev/null || true
        echo 'Стандартный lighttpd Entware отключён (S80lighttpd); панель использует свой конфиг.'
    fi
}

ensure_curl() {
    [ -x /opt/bin/curl ] && return 0
    command -v opkg >/dev/null 2>&1 || return 0
    opkg install curl ca-bundle >/dev/null 2>&1 || true
}

preflight() {
    TEST_DIR=$(mktemp -d /tmp/alisa-panel-test.XXXXXX) || fail 'не удалось создать временный каталог.'
    mkdir -p "$TEST_DIR/cgi-bin"
    printf 'panel-preflight\n' > "$TEST_DIR/index.html"
    cat > "$TEST_DIR/cgi-bin/x.cgi" <<'EOF'
#!/bin/sh
printf 'Content-Type: text/plain\r\n\r\npreflight-ok'
EOF
    chmod 755 "$TEST_DIR/cgi-bin/x.cgi"
    printf 'admin:testpass\n' > "$TEST_DIR/user"
    chmod 600 "$TEST_DIR/user"
    cat > "$TEST_DIR/lighttpd.conf" <<EOF
server.document-root = "$TEST_DIR"
server.port = 18099
server.bind = "127.0.0.1"
server.modules = ( "mod_access", "mod_auth", "mod_authn_file", "mod_cgi" )
server.errorlog = "$TEST_DIR/log"
server.max-request-size = 512
index-file.names = ( "index.html" )
cgi.assign = ( ".cgi" => "/bin/sh" )
auth.backend = "plain"
auth.backend.plain.userfile = "$TEST_DIR/user"
auth.require = ( "/" => ( "method" => "basic", "realm" => "test", "require" => "user=admin" ) )
EOF
    lighttpd -tt -f "$TEST_DIR/lighttpd.conf" 2>>"$TEST_DIR/log" ||
        fail 'lighttpd не принял тестовый конфиг.'

    TEST_PORT=18099
    while [ "$TEST_PORT" -lt 18120 ]; do
        sed "s/18099/$TEST_PORT/" "$TEST_DIR/lighttpd.conf" > "$TEST_DIR/run.conf"
        lighttpd -D -f "$TEST_DIR/run.conf" >>"$TEST_DIR/log" 2>&1 &
        TEST_PID=$!
        sleep .5
        kill -0 "$TEST_PID" 2>/dev/null && break
        TEST_PID=
        TEST_PORT=$((TEST_PORT + 1))
    done
    [ -n "${TEST_PID:-}" ] || fail 'lighttpd не запустился на тестовом порту.'

    AUTH=$(printf 'admin:testpass' | busybox base64 | tr -d '\n')
    AUTH_HEADER="Authorization: Basic $AUTH"
    if ! wget -S -O /dev/null "http://127.0.0.1:$TEST_PORT/" 2>&1 | grep -q '401'; then
        fail 'lighttpd не требует пароль.'
    fi
    if ! wget -q -O /dev/null --header="$AUTH_HEADER" "http://127.0.0.1:$TEST_PORT/"; then
        fail 'lighttpd не принимает Basic auth.'
    fi
    BODY=$(wget -q -O - --header="$AUTH_HEADER" "http://127.0.0.1:$TEST_PORT/cgi-bin/x.cgi" 2>/dev/null || true)
    [ "$BODY" = 'preflight-ok' ] || fail 'lighttpd не выполняет CGI.'
    kill "$TEST_PID" 2>/dev/null || true
    TEST_PID=
    rm -rf "$TEST_DIR"; TEST_DIR=
}

ensure_lighttpd
disable_default_lighttpd
ensure_curl
preflight

# --- preserve the previous password/token/port ---
OLD_PASSWORD=; OLD_TOKEN=; OLD_PORT=
if [ -r "$TARGET/panel.conf" ]; then
    OLD_PASSWORD=$(sed -n 's/^PANEL_PASSWORD=//p' "$TARGET/panel.conf" | tail -n1)
    OLD_TOKEN=$(sed -n 's/^PANEL_TOKEN=//p' "$TARGET/panel.conf" | tail -n1)
    OLD_PORT=$(sed -n 's/^PANEL_PORT=//p' "$TARGET/panel.conf" | tail -n1)
fi
NEW_PORT=${PANEL_PORT:-}

# --- swap the tree; keep the previous version until the new one answers ---
if [ "$BASE" != "$TARGET" ]; then
    if [ -d "$TARGET" ]; then
        [ -x "$TARGET/stop.sh" ] && "$TARGET/stop.sh" || true
        OLD=$TARGET.old.$$
        mv "$TARGET" "$OLD" || fail 'не удалось отодвинуть прежнюю панель.'
    fi
    mkdir -p "$(dirname "$TARGET")"
    if ! mv "$BASE" "$TARGET"; then
        [ -n "${OLD:-}" ] && mv "$OLD" "$TARGET"
        fail 'не удалось установить файлы панели.'
    fi
fi
BASE=$TARGET

# --- write configs at their final paths ---
ALISA_PANEL_BASE=$TARGET
. "$TARGET/lib.sh"
PANEL_USER=admin
PANEL_PORT=${NEW_PORT:-${OLD_PORT:-8099}}
case ${PANEL_PORT:-} in ''|*[!0-9]*) PANEL_PORT=8099 ;; esac
[ "$PANEL_PORT" -ge 1 ] && [ "$PANEL_PORT" -le 65535 ] || fail 'некорректный порт панели.'
PANEL_TOKEN=${OLD_TOKEN:-$(gen)}
case ${PANEL_TOKEN:-} in *[!A-Za-z0-9]*|'') PANEL_TOKEN=$(gen) ;; esac
PANEL_PASSWORD=${OLD_PASSWORD:-$(gen)}
case ${PANEL_PASSWORD:-} in *[!A-Za-z0-9._-]*|'') PANEL_PASSWORD=$(gen) ;; esac
[ ${#PANEL_PASSWORD} -ge 8 ] && [ ${#PANEL_PASSWORD} -le 64 ] || PANEL_PASSWORD=$(gen)

write_panel_conf
write_lighttpd_conf
write_lighttpd_user
chmod 700 "$TARGET" "$TARGET/cgi-bin" "$TARGET/start.sh" "$TARGET/stop.sh"
chmod 700 "$TARGET/cgi-bin/api.cgi" "$TARGET/install.sh" "$TARGET/uninstall.sh"
chmod 600 "$TARGET/index.html" "$TARGET/lib.sh" "$TARGET/panel.conf" "$TARGET/lighttpd.conf" "$TARGET/lighttpd.user"

ensure_init() {
    if [ -f "$INIT" ] && ! grep -q ALISA_PANEL_INSTALLER "$INIT"; then
        echo "Предупреждение: $INIT занят другим файлом; автозапуск не включён." >&2
        return 1
    fi
    was_ro=0
    case "$(awk '$2=="/" {print $4}' /proc/mounts)" in ro,*) was_ro=1 ;; esac
    if [ "$was_ro" = 1 ]; then mount -o remount,rw / || return 1; fi
    if ! {
        printf '%s\n' '#!/bin/sh' '# ALISA_PANEL_INSTALLER' \
            'PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
            "BASE=$TARGET" \
            'case "${1:-}" in' \
            'start) [ -x "$BASE/start.sh" ] && "$BASE/start.sh" ;;' \
            'stop) [ -x "$BASE/stop.sh" ] && "$BASE/stop.sh" ;;' \
            'restart) "$BASE/stop.sh" 2>/dev/null; "$BASE/start.sh" ;;' \
            'esac' 'exit 0' > "$INIT.new"
        chmod 755 "$INIT.new"
        mv "$INIT.new" "$INIT"
        sync
    }; then
        rm -f "$INIT.new"
        [ "$was_ro" = 1 ] && mount -o remount,ro /
        return 1
    fi
    [ "$was_ro" = 1 ] && mount -o remount,ro /
    return 0
}
ensure_init || true

if ! "$TARGET/start.sh" start; then
    if [ -n "${OLD:-}" ] && [ -d "$OLD" ]; then
        rm -rf "$TARGET.failed.$$"
        mv "$TARGET" "$TARGET.failed.$$" 2>/dev/null || true
        mv "$OLD" "$TARGET"
        "$TARGET/start.sh" start >/dev/null 2>&1 || true
        fail 'новая панель не запустилась; прежняя версия восстановлена.'
    fi
    fail 'панель не запустилась.'
fi

AUTH_HEADER="Authorization: Basic $(printf '%s:%s' "$PANEL_USER" "$PANEL_PASSWORD" | busybox base64 | tr -d '\n')"
if ! wget -q -O /dev/null --header="$AUTH_HEADER" "http://127.0.0.1:$PANEL_PORT/" 2>/dev/null; then
    "$TARGET/stop.sh" || true
    if [ -n "${OLD:-}" ] && [ -d "$OLD" ]; then
        rm -rf "$TARGET.failed.$$"
        mv "$TARGET" "$TARGET.failed.$$" 2>/dev/null || true
        mv "$OLD" "$TARGET"
        "$TARGET/start.sh" start >/dev/null 2>&1 || true
    fi
    fail 'панель не прошла проверку входа.'
fi
[ -n "${OLD:-}" ] && rm -rf "$OLD" || true

IP=$(ip -4 addr show 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); if ($2!="127.0.0.1") {print $2; exit}}')
[ -n "$IP" ] || IP=$(hostname -i 2>/dev/null | awk '{print $1}')
echo 'Панель установлена.'
echo "PANEL_URL=http://${IP:-127.0.0.1}:$PANEL_PORT/"
echo "PANEL_USER=$PANEL_USER"
echo "PANEL_PASSWORD=$PANEL_PASSWORD"
echo "PANEL_PORT=$PANEL_PORT"
