#!/bin/sh
# Shared helpers for Alisa Panel. POSIX sh / BusyBox ash.
set -u
umask 077

PANEL_BASE=${ALISA_PANEL_BASE:-/data/opt/alisa-panel}
GPT_BASE=${ALISA_PANEL_GPT_BASE:-/data/opt/alisa-standalone}
CLI_BASE=${ALISA_PANEL_CLI_BASE:-/data/opt/alisa-cli}
BRIDGE_BASE=${ALISA_PANEL_BRIDGE_BASE:-/data/opt/quasar-bridge}
BRIDGE_DIAG=${ALISA_PANEL_BRIDGE_DIAG:-http://127.0.0.1:2704}
STATE=${ALISA_PANEL_STATE:-$GPT_BASE/state}
RUNTIME=${ALISA_PANEL_RUNTIME:-/tmp/alisa-standalone}
PANEL_CONF=${ALISA_PANEL_CONF:-$PANEL_BASE/panel.conf}
INIT_DIR=${ALISA_PANEL_INIT_DIR:-/etc/init.d}
PANEL_USER=admin
PANEL_PORT=8099
PANEL_TOKEN=
PANEL_PASSWORD=
if [ -r "$PANEL_CONF" ]; then . "$PANEL_CONF"; fi

QUERY_STRING=${QUERY_STRING:-}
HTTP_HOST=${HTTP_HOST:-}

json_escape() {
    awk 'BEGIN{ORS=""} {
        gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,"");
        if (NR>1) printf "\\n";
        printf "%s",$0
    }'
}

urldecode() {
    awk -v s="$1" 'BEGIN{
        gsub(/\+/," ",s); out="";
        while ((i=index(s,"%"))>0) {
            out=out substr(s,1,i-1);
            h=substr(s,i+1,2); n=0; bad=0;
            for (j=1;j<=2;j++) {
                c=index("0123456789abcdef",tolower(substr(h,j,1)));
                if (c==0) {bad=1;break}
                n=n*16+c-1
            }
            if (bad) {out=out "%"; s=substr(s,i+1)}
            else {out=out sprintf("%c",n); s=substr(s,i+3)}
        }
        printf "%s%s",out,s
    }'
}

query_get() {
    _key=$1; _rest=$QUERY_STRING; _old=$IFS; IFS='&'
    for _pair in $_rest; do
        case $_pair in
            "$_key="*) IFS=$_old; urldecode "${_pair#"$_key="}"; return 0 ;;
        esac
    done
    IFS=$_old
    return 1
}

respond() {
    printf 'Status: %s\r\nContent-Type: %s; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n' "$1" "$2"
    cat
}

respond_json() { printf '%s' "$1" | respond '200 OK' application/json; }

fail_json() {
    _message=$(printf '%s' "$2" | json_escape)
    printf '{"ok":false,"error":"%s"}' "$_message" | respond "$1" application/json
}

require_token() {
    [ -n "${PANEL_TOKEN:-}" ] || return 1
    [ "${HTTP_X_PANEL_TOKEN:-}" = "$PANEL_TOKEN" ] || return 1
    case ${HTTP_ORIGIN:-} in
        ''|"http://$HTTP_HOST") return 0 ;;
        *) return 1 ;;
    esac
}

lock() {
    _dir=$PANEL_BASE/locks
    mkdir -p "$_dir" 2>/dev/null || return 1
    if ! mkdir "$_dir/$1" 2>/dev/null; then
        _owner=$(cat "$_dir/$1/pid" 2>/dev/null || true)
        case ${_owner:-} in
            ''|*[!0-9]*) ;;
            *) kill -0 "$_owner" 2>/dev/null && return 1 ;;
        esac
        rm -rf "$_dir/$1"
        mkdir "$_dir/$1" 2>/dev/null || return 1
    fi
    echo $$ > "$_dir/$1/pid"
    LOCK_DIR=$_dir/$1
    trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT
    return 0
}

gpt_running() {
    [ "${ALISA_PANEL_FAKE_GPT_RUNNING:-}" = 1 ] && return 0
    _pid=
    [ -r "$RUNTIME/monitor.pid" ] && _pid=$(cat "$RUNTIME/monitor.pid" 2>/dev/null)
    case ${_pid:-} in ''|*[!0-9]*) return 1 ;; esac
    if [ -r "/proc/$_pid/cmdline" ]; then
        case "$(tr '\000' ' ' < "/proc/$_pid/cmdline")" in
            *"$GPT_BASE/run.sh monitor"*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 1
}

gpt_status() {
    if [ -n "${ALISA_PANEL_FAKE_GPT_STATUS:-}" ]; then
        printf '%s' "$ALISA_PANEL_FAKE_GPT_STATUS"
        return 0
    fi
    gpt_running || return 1
    "$GPT_BASE/bin/alisa-standalone" status "$STATE" 2>/dev/null
}

gpt_action() {
    "$GPT_BASE/bin/alisa-standalone" "$1" "$STATE" "${2:-}" 2>&1
}

bridge_running() {
    [ -x "$BRIDGE_BASE/app/control.sh" ] || return 1
    sh "$BRIDGE_BASE/app/control.sh" status >/dev/null 2>&1
}

fetch_ok() {
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 2 -t 1 -O /dev/null "$1" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -fsS -m 2 -o /dev/null "$1" 2>/dev/null
    else
        return 1
    fi
}

bridge_health() {
    fetch_ok http://127.0.0.1:8443/healthz
}

# Calls the local Bridge diagnostics API (loopback only). Prints body then the
# HTTP status on the last line, so callers can report Bridge errors verbatim.
diag_request() {
    if [ -x /opt/bin/curl ]; then _curl=/opt/bin/curl
    elif command -v curl >/dev/null 2>&1; then _curl=curl
    else return 127; fi
    if [ "$1" = POST ]; then
        "$_curl" -sS -m 20 -X POST -H 'Content-Type: application/json' \
            --data "$3" -w '\n%{http_code}' "$BRIDGE_DIAG$2" 2>/dev/null
    else
        "$_curl" -sS -m 8 -w '\n%{http_code}' "$BRIDGE_DIAG$2" 2>/dev/null
    fi
}

diag_body() { printf '%s' "$1" | sed '$d'; }
diag_code() { printf '%s' "$1" | tail -n 1; }

json_bool() {
    _v=$(printf '%s' "$2" | sed -n 's/.*"'"$1"'":\([a-z]*\).*/\1/p' | head -n 1)
    case $_v in true|false) printf '%s' "$_v" ;; esac
}

json_str() {
    printf '%s' "$2" | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' | head -n 1
}

bridge_version() {
    cat "$BRIDGE_BASE/app/VERSION" "$BRIDGE_BASE/VERSION" 2>/dev/null | head -n1
}

endpoint_applied() { [ -f "$BRIDGE_BASE/endpoint-backup.json" ]; }

vpn_required() { [ -f "$CLI_BASE/vpn-required" ]; }

boot_hook_present() { [ -f "$INIT_DIR/S99zz-alisa-voice" ] && [ -x "$CLI_BASE/boot.sh" ]; }

bridge_env_value() {
    awk -v k="$1" '
        $0 ~ "^[ \t]*"k"=" {
            v=$0; sub("^[ \t]*"k"=","",v);
            if (v ~ /^".*"$/) v=substr(v,2,length(v)-2);
            print v; exit
        }' "$BRIDGE_BASE/runtime.env" 2>/dev/null |
        sed -e 's/\\"/"/g' -e 's/\\\$/$/g' -e 's/\\`/`/g' -e 's/\\\\/\\/g'
}

quasar_setting() {
    printf '%s="' "$1"
    printf '%s' "$2" | sed 's/[\\`"$]/\\&/g'
    printf '"\n'
}

set_bridge_env() {
    _mode=$1; _base=$2; _model=$3; _api=$4; _key=$5; _home=$6
    _file=$BRIDGE_BASE/runtime.env; _tmp=$_file.new.$$
    if [ -r "$_file" ]; then
        awk '
            /^# BEGIN QUASAR SETUP$/ {skip=1; next}
            /^# END QUASAR SETUP$/ {skip=0; next}
            skip {next}
            /^[ \t]*QUASAR_(MODE|LLM_BASE_URL|LLM_MODEL|LLM_API|LLM_API_KEY|HOME_MCP_URL)=/ {next}
            {print}
        ' "$_file" > "$_tmp"
    else
        : > "$_tmp"
    fi
    {
        echo '# BEGIN QUASAR SETUP'
        quasar_setting QUASAR_MODE "$_mode"
        quasar_setting QUASAR_LLM_BASE_URL "$_base"
        quasar_setting QUASAR_LLM_MODEL "$_model"
        quasar_setting QUASAR_LLM_API "$_api"
        quasar_setting QUASAR_LLM_API_KEY "$_key"
        quasar_setting QUASAR_HOME_MCP_URL "$_home"
        echo '# END QUASAR SETUP'
    } >> "$_tmp"
    chmod 600 "$_tmp"; mv -f "$_tmp" "$_file"
}

set_vpn_runtime() {
    _file=$GPT_BASE/runtime.env; _tmp=$_file.new.$$
    if [ -r "$_file" ]; then
        grep -vE '^(export )?(ALISA_VPN_REQUIRED|ALISA_PROXY_URL|ALISA_ICE_BIND_ADDRESS)=|^(export )?LD_PRELOAD=.*mark\.so' "$_file" > "$_tmp" || :
    else
        : > "$_tmp"
    fi
    if [ "$1" = on ]; then
        {
            echo 'export ALISA_VPN_REQUIRED=1'
            echo 'export ALISA_PROXY_URL=socks5h://127.0.0.1:18081'
            echo 'export ALISA_ICE_BIND_ADDRESS=172.31.254.1'
            echo "export LD_PRELOAD=$CLI_BASE/mark.so"
        } >> "$_tmp"
    fi
    chmod 600 "$_tmp"; mv -f "$_tmp" "$_file"
}

vpn_running() {
    [ -x "$CLI_BASE/vpn.sh" ] || return 1
    sh "$CLI_BASE/vpn.sh" status >/dev/null 2>&1
}

flag() { if [ -f "$1" ]; then echo 1; else echo 0; fi; }

station_ip() {
    ip -4 addr show 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); if ($2!="127.0.0.1") {print $2; exit}}'
}

station_model() { tr '\000' '\n' < /proc/device-tree/compatible 2>/dev/null | head -n1; }
station_firmware() { head -c 96 /system/vendor/quasar/version_full 2>/dev/null; }
station_uptime() { cut -d. -f1 /proc/uptime 2>/dev/null; }
station_free_kb() { df -k /data 2>/dev/null | awk 'NR==2{print $4}'; }

phrase_value() {
    awk -F '\t' -v n="$1" '$1==n{print $2; exit}' "$GPT_BASE/commands.txt" 2>/dev/null
}

led_scope_value() {
    _scope=$(awk 'NR==1{print $1}' "$GPT_BASE/led-scope" 2>/dev/null)
    [ -n "$_scope" ] && echo "$_scope" || echo speaking
}

led_style_value() {
    _style=$(awk 'NR==1{print $2}' "$GPT_BASE/led-scope" 2>/dev/null)
    [ -n "$_style" ] && echo "$_style" || awk -F= '/ALISA_LED_STYLE=/{print $2; exit}' "$GPT_BASE/runtime.env" 2>/dev/null
}

listen_led_value() { cat "$GPT_BASE/listen-led" 2>/dev/null || echo 0; }
stun_enabled() { if grep -q 'ALISA_DISABLE_STUN=1' "$GPT_BASE/runtime.env" 2>/dev/null; then echo 0; else echo 1; fi; }

valid_voice() {
    case ${1:-} in
        breeze|cove|ember|fathom|glimmer|juniper|maple|orbit|vale) return 0 ;;
    esac
    return 1
}

valid_style() {
    case ${1:-} in
        rainbow|red|blue|green|purple|white|off|pulse-red|pulse-blue|pulse-green|pulse-purple|pulse-white) return 0 ;;
    esac
    return 1
}

valid_chat_id() {
    printf '%s' "${1:-}" | LC_ALL=C grep -Eq '^[A-Za-z0-9_-]{1,64}$'
}

valid_phrase() {
    [ -n "${1:-}" ] || return 1
    _len=$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')
    [ "${_len:-0}" -ge 1 ] && [ "${_len:-0}" -le 200 ] || return 1
    printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]' && return 1
    return 0
}

valid_password() {
    printf '%s' "${1:-}" | LC_ALL=C grep -Eq '^[A-Za-z0-9._-]{8,64}$'
}

atomic_write() {
    _path=$1; _tmp=${_path}.new.$$
    cat > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 600 "$_tmp"
    mv -f "$_tmp" "$_path"
}

set_stun() {
    _file=$GPT_BASE/runtime.env; _tmp=$_file.new.$$
    { [ -r "$_file" ] && grep -v '^export ALISA_DISABLE_STUN=' "$_file" || true
      [ "$1" = on ] && echo 'export ALISA_DISABLE_STUN=1' || true; } > "$_tmp"
    chmod 600 "$_tmp"; mv -f "$_tmp" "$_file"
}

set_led_style() {
    _style=$1; _file=$GPT_BASE/runtime.env; _tmp=$_file.new.$$
    { [ -r "$_file" ] && grep -v '^export ALISA_LED_STYLE=' "$_file" || true
      echo "export ALISA_LED_STYLE=$_style"; } > "$_tmp"
    chmod 600 "$_tmp"; mv -f "$_tmp" "$_file"
    _scope=$(led_scope_value)
    printf '%s %s\n' "$_scope" "$_style" | atomic_write "$GPT_BASE/led-scope"
}

set_led_scope() {
    _scope=$1; _style=$(led_style_value); [ -n "$_style" ] || _style=rainbow
    printf '%s %s\n' "$_scope" "$_style" | atomic_write "$GPT_BASE/led-scope"
}

set_listen_led() {
    printf '%s\n' "$1" | atomic_write "$GPT_BASE/listen-led"
}

set_voice_file() {
    _voice=$1; _file=$STATE/settings.json
    [ -r "$_file" ] || return 0
    _tmp=$_file.new.$$
    sed 's/"voice"[[:space:]]*:[[:space:]]*"[^"]*"/"voice":"'"$_voice"'"/' "$_file" > "$_tmp" || return 1
    chmod 600 "$_tmp"; mv -f "$_tmp" "$_file"
}

write_lighttpd_conf() {
    _file=$PANEL_BASE/lighttpd.conf; _tmp=$_file.new.$$
    {
        printf 'server.document-root = "%s"\n' "$PANEL_BASE"
        printf 'server.port = %s\n' "$PANEL_PORT"
        printf '%s\n' 'server.bind = "0.0.0.0"'
        printf '%s\n' 'server.modules = ( "mod_access", "mod_auth", "mod_authn_file", "mod_cgi" )'
        printf 'server.errorlog = "%s/lighttpd.log"\n' "$PANEL_BASE"
        printf '%s\n' 'server.max-request-size = 512'
        printf '%s\n' 'server.upload-dirs = ( "/tmp" )'
        printf '%s\n' 'index-file.names = ( "index.html" )'
        printf '%s\n' 'server.dir-listing = "disable"'
        printf '%s\n' 'cgi.assign = ( ".cgi" => "/bin/sh" )'
        printf '%s\n' 'auth.backend = "plain"'
        printf 'auth.backend.plain.userfile = "%s/lighttpd.user"\n' "$PANEL_BASE"
        printf 'auth.require = ( "/" => ( "method" => "basic", "realm" => "Alisa Panel", "require" => "user=%s" ) )\n' "$PANEL_USER"
        printf '%s\n' '$HTTP["remoteip"] !~ "^(127\.0\.0\.1|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)" {'
        printf '%s\n' '    url.access-deny = ("")'
        printf '%s\n' '}'
    } > "$_tmp"
    chmod 600 "$_tmp"; mv -f "$_tmp" "$_file"
}

write_lighttpd_user() {
    printf '%s:%s\n' "$PANEL_USER" "$PANEL_PASSWORD" | atomic_write "$PANEL_BASE/lighttpd.user"
}

write_panel_conf() {
    _file=$PANEL_BASE/panel.conf; _tmp=$_file.new.$$
    {
        echo "PANEL_USER=$PANEL_USER"
        echo "PANEL_PORT=$PANEL_PORT"
        echo "PANEL_TOKEN=$PANEL_TOKEN"
        echo "PANEL_PASSWORD=$PANEL_PASSWORD"
    } > "$_tmp"
    chmod 600 "$_tmp"; mv -f "$_tmp" "$_file"
}
