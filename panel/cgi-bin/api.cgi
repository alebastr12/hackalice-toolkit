#!/bin/sh
# Alisa Panel JSON/text API. Runs as CGI under BusyBox httpd.
set -u
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$BASE/lib.sh"

action=
if ! action=$(query_get action); then action=; fi
method=${REQUEST_METHOD:-GET}

status_payload() {
    _gpt_raw=$(gpt_status 2>/dev/null || true)
    _gpt_esc=$(printf '%s' "$_gpt_raw" | json_escape)
    _gpt_run=0; gpt_running && _gpt_run=1
    _bridge_run=0; bridge_running && _bridge_run=1
    _bridge_health=0; bridge_health && _bridge_health=1
    _bridge_inst=0; [ -d "$BRIDGE_BASE" ] && _bridge_inst=1
    _vpn=0; vpn_running && _vpn=1
    _vpn_req=0; vpn_required && _vpn_req=1
    _endpoint=0; endpoint_applied && _endpoint=1
    _hook=0; boot_hook_present && _hook=1
    _login=0; [ -f "$STATE/web-session.json" ] && _login=1
    _ip=$(station_ip); _model=$(station_model); _fw=$(station_firmware)
    _uptime=$(station_uptime); _free=$(station_free_kb)
    case ${_uptime:-} in ''|*[!0-9]*) _uptime=0 ;; esac
    case ${_free:-} in ''|*[!0-9]*) _free=0 ;; esac
    _bver=$(bridge_version)
    _ui_raw=$("$GPT_BASE/bin/alisa-standalone" url "$STATE" 2>/dev/null || true)
    _ui_esc=$(printf '%s' "$_ui_raw" | json_escape)
    _p1=$(phrase_value 1); _p2=$(phrase_value 2); _p3=$(phrase_value 3); _p4=$(phrase_value 4)
    _listen=$(listen_led_value); case ${_listen:-} in 1) _listen=1 ;; *) _listen=0 ;; esac
    printf '{"ok":true,'
    printf '"station":{"ip":"%s","model":"%s","firmware":"%s","uptime_s":%s,"free_kb":%s},' \
        "$(printf '%s' "$_ip" | json_escape)" "$(printf '%s' "$_model" | json_escape)" \
        "$(printf '%s' "$_fw" | json_escape)" "$_uptime" "$_free"
    printf '"bridge":{"installed":%s,"running":%s,"healthy":%s,"endpoint_applied":%s,"version":"%s","autostart":%s},' \
        "$_bridge_inst" "$_bridge_run" "$_bridge_health" "$_endpoint" "$(printf '%s' "$_bver" | json_escape)" \
        "$(flag "$INIT_DIR/S96quasar-bridge")"
    printf '"gpt":{"running":%s,"login_saved":%s,"raw":"%s"},' "$_gpt_run" "$_login" "$_gpt_esc"
    printf '"flags":{"gpt_autostart":%s,"vpn_autostart":%s,"vpn_required":%s,"boot_hook":%s,"stun":%s,"led_scope":"%s","led_style":"%s","listen_led":%s,"vpn_running":%s},' \
        "$(flag "$CLI_BASE/native-autostart")" "$(flag "$CLI_BASE/vpn-autostart")" "$_vpn_req" "$_hook" "$(stun_enabled)" \
        "$(printf '%s' "$(led_scope_value)" | json_escape)" \
        "$(printf '%s' "$(led_style_value)" | json_escape)" \
        "$_listen" "$_vpn"
    printf '"phrases":{"open":"%s","new":"%s","close":"%s","previous":"%s"},' \
        "$(printf '%s' "$_p1" | json_escape)" "$(printf '%s' "$_p2" | json_escape)" \
        "$(printf '%s' "$_p3" | json_escape)" "$(printf '%s' "$_p4" | json_escape)"
    printf '"native_ui":{"raw":"%s"},' "$_ui_esc"
    printf '"panel":{"port":%s,"user":"%s"}}' "$PANEL_PORT" "$(printf '%s' "$PANEL_USER" | json_escape)"
}

gpt_command() {
    _name=$1; _arg=${2:-}
    gpt_running || { fail_json '409 Conflict' 'GPT не запущен. Сначала запустите клиент.'; return 1; }
    if [ -n "$_arg" ]; then
        _out=$("$GPT_BASE/bin/alisa-standalone" "$_name" "$STATE" "$_arg" 2>&1)
    else
        _out=$("$GPT_BASE/bin/alisa-standalone" "$_name" "$STATE" 2>&1)
    fi
    _code=$?
    if [ "$_code" -ne 0 ]; then
        _esc=$(printf '%s' "$_out" | tail -n 3 | json_escape)
        printf '{"ok":false,"error":"%s"}' "$_esc" | respond '200 OK' application/json
        return 1
    fi
    return 0
}

ok_message() {
    _m=$(printf '%s' "$1" | json_escape)
    printf '{"ok":true,"message":"%s"}' "$_m" | respond '200 OK' application/json
}

case $method in
GET)
    case $action in
        token)
            [ -n "$PANEL_TOKEN" ] || { fail_json '500 Internal Server Error' 'Панель не настроена.'; exit 0; }
            printf '{"token":"%s"}' "$(printf '%s' "$PANEL_TOKEN" | json_escape)" | respond '200 OK' application/json
            ;;
        status)
            status_payload | respond '200 OK' application/json
            ;;
        bridge_logs)
            if [ -r "$BRIDGE_BASE/service.log" ]; then
                tail -n 200 "$BRIDGE_BASE/service.log" | respond '200 OK' text/plain
            else
                printf 'Журнал Quasar Bridge пока пуст.\n' | respond '200 OK' text/plain
            fi
            ;;
        gpt_logs)
            if [ -r "$RUNTIME/daemon.log" ]; then
                tail -n 200 "$RUNTIME/daemon.log" | respond '200 OK' text/plain
            else
                printf 'Журнал GPT пока пуст.\n' | respond '200 OK' text/plain
            fi
            ;;
        bridge_config)
            if [ -r "$BRIDGE_BASE/config.json" ]; then
                cat "$BRIDGE_BASE/config.json" | respond '200 OK' text/plain
            else
                fail_json '404 Not Found' 'Конфиг Quasar Bridge не найден.'
            fi
            ;;
        bridge_env)
            _mode=$(bridge_env_value QUASAR_MODE); [ -n "$_mode" ] || _mode=hybrid
            _base=$(bridge_env_value QUASAR_LLM_BASE_URL)
            _model=$(bridge_env_value QUASAR_LLM_MODEL)
            _api=$(bridge_env_value QUASAR_LLM_API); [ -n "$_api" ] || _api=chat_completions
            _key=$(bridge_env_value QUASAR_LLM_API_KEY)
            _home=$(bridge_env_value QUASAR_HOME_MCP_URL)
            printf '{"ok":true,"mode":"%s","base_url":"%s","model":"%s","api":"%s","api_key":"%s","home_mcp_url":"%s"}' \
                "$(printf '%s' "$_mode" | json_escape)" "$(printf '%s' "$_base" | json_escape)" \
                "$(printf '%s' "$_model" | json_escape)" "$(printf '%s' "$_api" | json_escape)" \
                "$(printf '%s' "$_key" | json_escape)" "$(printf '%s' "$_home" | json_escape)" |
                respond '200 OK' application/json
            ;;
        bridge_models)
            _base=$(bridge_env_value QUASAR_LLM_BASE_URL)
            case ${_base:-} in ''|http://*|https://*) ;; *) fail_json '400 Bad Request' 'Некорректный адрес API.'; exit 0 ;; esac
            [ -n "$_base" ] || { fail_json '409 Conflict' 'Не задан адрес API.'; exit 0; }
            case $_base in */models) _url=$_base ;; *) _url=${_base%/}/models ;; esac
            _key=$(bridge_env_value QUASAR_LLM_API_KEY)
            _ca=/system/vendor/quasar/ca-certificates.crt
            _resp=
            _curl=$(command -v curl 2>/dev/null || true)
            if [ -z "$_curl" ]; then
                for _c in /opt/bin/curl /usr/bin/curl /usr/local/bin/curl; do
                    [ -x "$_c" ] && _curl=$_c && break
                done
            fi
            if [ -n "$_curl" ]; then
                if [ -n "$_key" ] && [ -r "$_ca" ]; then
                    _resp=$("$_curl" -sS -m 10 --cacert "$_ca" -H "Authorization: Bearer $_key" "$_url" 2>/dev/null || true)
                elif [ -n "$_key" ]; then
                    _resp=$("$_curl" -sS -m 10 -H "Authorization: Bearer $_key" "$_url" 2>/dev/null || true)
                elif [ -r "$_ca" ]; then
                    _resp=$("$_curl" -sS -m 10 --cacert "$_ca" "$_url" 2>/dev/null || true)
                else
                    _resp=$("$_curl" -sS -m 10 "$_url" 2>/dev/null || true)
                fi
            elif command -v wget >/dev/null 2>&1; then
                if [ -n "$_key" ]; then
                    _resp=$(wget -q -T 10 -t 1 -O - --header="Authorization: Bearer $_key" "$_url" 2>/dev/null || true)
                else
                    _resp=$(wget -q -T 10 -t 1 -O - "$_url" 2>/dev/null || true)
                fi
            fi
            _ids=$(printf '%s' "$_resp" | tr ',' '\n' | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sort -u | head -100)
            [ -n "$_ids" ] || { fail_json '502 Bad Gateway' 'Не удалось получить список моделей. Проверьте адрес, ключ и доступность API.'; exit 0; }
            _json=
            for _m in $_ids; do
                _esc=$(printf '%s' "$_m" | json_escape)
                _json="$_json${_json:+,}\"$_esc\""
            done
            printf '{"ok":true,"models":[%s]}' "$_json" | respond '200 OK' application/json
            ;;
        *)
            fail_json '404 Not Found' 'Неизвестное действие.'
            ;;
    esac
    exit 0
    ;;
POST)
    ;;
*)
    fail_json '405 Method Not Allowed' 'Метод не поддерживается.'
    exit 0
    ;;
esac

require_token || { fail_json '403 Forbidden' 'Неверный токен панели.'; exit 0; }

case $action in
gpt_open|gpt_new|gpt_close|gpt_previous)
    lock gpt || { fail_json '409 Conflict' 'Другое действие с GPT уже выполняется.'; exit 0; }
    _name=${action#gpt_}
    if gpt_command "$_name"; then ok_message 'Команда отправлена.'; fi
    ;;
gpt_select)
    _id=$(query_get chat_id || true)
    valid_chat_id "$_id" || { fail_json '400 Bad Request' 'Некорректный разговор.'; exit 0; }
    lock gpt || { fail_json '409 Conflict' 'Другое действие с GPT уже выполняется.'; exit 0; }
    if gpt_command select "$_id"; then ok_message 'Разговор выбран.'; fi
    ;;
gpt_voice)
    _voice=$(query_get voice || true)
    valid_voice "$_voice" || { fail_json '400 Bad Request' 'Неизвестный голос.'; exit 0; }
    lock gpt || { fail_json '409 Conflict' 'Другое действие с GPT уже выполняется.'; exit 0; }
    if gpt_command voice "$_voice"; then ok_message 'Голос сохранён.'; fi
    ;;
gpt_led)
    _style=$(query_get style || true)
    valid_style "$_style" || { fail_json '400 Bad Request' 'Неизвестная подсветка.'; exit 0; }
    lock gpt || { fail_json '409 Conflict' 'Другое действие с GPT уже выполняется.'; exit 0; }
    set_led_style "$_style"
    if gpt_running; then "$GPT_BASE/bin/alisa-standalone" led "$STATE" "$_style" >/dev/null 2>&1 || true; fi
    ok_message 'Подсветка сохранена.'
    ;;
gpt_settings)
    _voice=; _style=; _scope=; _listen=; _auto=; _vpn_auto=; _stun=
    _has_voice=0; _has_style=0; _has_scope=0; _has_listen=0
    _has_auto=0; _has_vpn_auto=0; _has_stun=0
    if _voice=$(query_get voice); then
        valid_voice "$_voice" || { fail_json '400 Bad Request' 'Неизвестный голос.'; exit 0; }
        _has_voice=1
    fi
    if _style=$(query_get style); then
        valid_style "$_style" || { fail_json '400 Bad Request' 'Неизвестная подсветка.'; exit 0; }
        _has_style=1
    fi
    if _scope=$(query_get scope); then
        case $_scope in speaking|active) ;; *) fail_json '400 Bad Request' 'Некорректный режим подсветки.'; exit 0 ;; esac
        _has_scope=1; _requested_scope=$_scope
    fi
    if _listen=$(query_get listen); then
        case $_listen in 0|1) ;; *) fail_json '400 Bad Request' 'Некорректное значение подсветки в паузах.'; exit 0 ;; esac
        _has_listen=1
    fi
    if _auto=$(query_get autostart); then
        case $_auto in 0|1) ;; *) fail_json '400 Bad Request' 'Некорректный автозапуск.'; exit 0 ;; esac
        _has_auto=1
    fi
    if _vpn_auto=$(query_get vpn_autostart); then
        case $_vpn_auto in 0|1) ;; *) fail_json '400 Bad Request' 'Некорректный автозапуск VLESS.'; exit 0 ;; esac
        _has_vpn_auto=1
    fi
    if _stun=$(query_get stun); then
        case $_stun in 0|1) ;; *) fail_json '400 Bad Request' 'Некорректное значение STUN.'; exit 0 ;; esac
        _has_stun=1
    fi
    if { [ "$_has_auto" = 1 ] && [ "$_auto" = 1 ]; } || { [ "$_has_vpn_auto" = 1 ] && [ "$_vpn_auto" = 1 ]; }; then
        if ! boot_hook_present; then
            fail_json '409 Conflict' 'Автозапуск не установлен: нет init-скрипта или boot.sh. Переустановите GPT с Mac.'
            exit 0
        fi
    fi
    lock gpt || { fail_json '409 Conflict' 'Другое действие с GPT уже выполняется.'; exit 0; }
    if [ "$_has_voice" = 1 ]; then
        if gpt_running; then
            gpt_command voice "$_voice" || exit 0
        else
            set_voice_file "$_voice"
        fi
    fi
    if [ "$_has_style" = 1 ]; then
        set_led_style "$_style"
        if gpt_running; then "$GPT_BASE/bin/alisa-standalone" led "$STATE" "$_style" >/dev/null 2>&1 || true; fi
    fi
    [ "$_has_scope" = 1 ] && set_led_scope "$_requested_scope"
    [ "$_has_listen" = 1 ] && set_listen_led "$_listen"
    if [ "$_has_auto" = 1 ]; then
        if [ "$_auto" = 1 ]; then touch "$CLI_BASE/native-autostart"; else rm -f "$CLI_BASE/native-autostart"; fi
    fi
    if [ "$_has_vpn_auto" = 1 ]; then
        if [ "$_vpn_auto" = 1 ]; then touch "$CLI_BASE/vpn-autostart"; else rm -f "$CLI_BASE/vpn-autostart"; fi
    fi
    if [ "$_has_stun" = 1 ]; then
        _before=$(stun_enabled)
        if [ "$_stun" = 1 ]; then set_stun off; else set_stun on; fi
        _after=$(stun_enabled)
        if [ "$_before" != "$_after" ] && gpt_running; then
            sh "$GPT_BASE/run.sh" stop >/dev/null 2>&1 || true
            sh "$GPT_BASE/run.sh" start >/dev/null 2>&1 || true
            _restarted=1
        fi
    fi
    _msg='Настройки сохранены.'
    [ "${_restarted:-0}" = 1 ] && _msg='Настройки сохранены; GPT перезапущен для STUN.'
    if [ "$_has_voice" = 1 ] && ! gpt_running; then _msg="$_msg Голос применится при запуске GPT."; fi
    ok_message "$_msg"
    ;;
gpt_start)
    if vpn_required; then
        if ! vpn_running; then
            fail_json '409 Conflict' 'VLESS включён, но туннель не запущен. Прямое подключение запрещено; запустите VLESS на вкладке ChatGPT.'
            exit 0
        fi
        if ! grep -q 'ALISA_PROXY_URL=' "$GPT_BASE/runtime.env" 2>/dev/null; then
            fail_json '409 Conflict' 'Настройки VLESS на станции неполные. Остановите и снова запустите VLESS в панели.'
            exit 0
        fi
    fi
    lock gpt || { fail_json '409 Conflict' 'Другое действие с GPT уже выполняется.'; exit 0; }
    _out=$(sh "$GPT_BASE/run.sh" start 2>&1) || { _e=$(printf '%s' "$_out" | json_escape); printf '{"ok":false,"error":"%s"}' "$_e" | respond '200 OK' application/json; exit 0; }
    ok_message 'GPT запускается.'
    ;;
gpt_stop)
    lock gpt || { fail_json '409 Conflict' 'Другое действие с GPT уже выполняется.'; exit 0; }
    _out=$(sh "$GPT_BASE/run.sh" stop 2>&1) || { _e=$(printf '%s' "$_out" | json_escape); printf '{"ok":false,"error":"%s"}' "$_e" | respond '200 OK' application/json; exit 0; }
    ok_message 'GPT остановлен, Алиса возвращена.'
    ;;
gpt_restart)
    lock gpt || { fail_json '409 Conflict' 'Другое действие с GPT уже выполняется.'; exit 0; }
    sh "$GPT_BASE/run.sh" stop >/dev/null 2>&1 || true
    _out=$(sh "$GPT_BASE/run.sh" start 2>&1) || { _e=$(printf '%s' "$_out" | json_escape); printf '{"ok":false,"error":"%s"}' "$_e" | respond '200 OK' application/json; exit 0; }
    ok_message 'GPT перезапускается.'
    ;;
gpt_autostart)
    _on=$(query_get on || true)
    [ "$_on" = 1 ] || [ "$_on" = 0 ] || { fail_json '400 Bad Request' 'Некорректное значение.'; exit 0; }
    if [ "$_on" = 1 ] && ! boot_hook_present; then
        fail_json '409 Conflict' 'Автозапуск клиента не установлен: переустановите GPT с Mac (нет init-скрипта или boot.sh).'
        exit 0
    fi
    if [ "$_on" = 1 ]; then touch "$CLI_BASE/native-autostart"; else rm -f "$CLI_BASE/native-autostart"; fi
    ok_message "Автозапуск GPT $([ "$_on" = 1 ] && echo включён || echo выключен)."
    ;;
gpt_vpn_autostart)
    _on=$(query_get on || true)
    [ "$_on" = 1 ] || [ "$_on" = 0 ] || { fail_json '400 Bad Request' 'Некорректное значение.'; exit 0; }
    if [ "$_on" = 1 ]; then touch "$CLI_BASE/vpn-autostart"; else rm -f "$CLI_BASE/vpn-autostart"; fi
    ok_message "Автозапуск VLESS $([ "$_on" = 1 ] && echo включён || echo выключен)."
    ;;
gpt_stun)
    _on=$(query_get on || true)
    [ "$_on" = 1 ] || [ "$_on" = 0 ] || { fail_json '400 Bad Request' 'Некорректное значение.'; exit 0; }
    lock gpt || { fail_json '409 Conflict' 'Другое действие с GPT уже выполняется.'; exit 0; }
    if [ "$_on" = 1 ]; then set_stun off; else set_stun on; fi
    if gpt_running; then
        _restarted=1
        sh "$GPT_BASE/run.sh" stop >/dev/null 2>&1 || true
        sh "$GPT_BASE/run.sh" start >/dev/null 2>&1 || true
    fi
    if [ "${_restarted:-0}" = 1 ]; then
        ok_message "STUN $([ "$_on" = 1 ] && echo включён || echo выключен). GPT перезапущен."
    else
        ok_message "STUN $([ "$_on" = 1 ] && echo включён || echo выключен). Применится при запуске GPT."
    fi
    ;;
gpt_phrases)
    _p1=$(query_get open || true); _p2=$(query_get new || true)
    _p3=$(query_get close || true); _p4=$(query_get previous || true)
    for _p in "$_p1" "$_p2" "$_p3" "$_p4"; do
        valid_phrase "$_p" || { fail_json '400 Bad Request' 'Фраза пустая, длиннее 200 байт или содержит управляющие символы.'; exit 0; }
    done
    if [ "$_p1" = "$_p2" ] || [ "$_p1" = "$_p3" ] || [ "$_p1" = "$_p4" ] || [ "$_p2" = "$_p3" ] || [ "$_p2" = "$_p4" ] || [ "$_p3" = "$_p4" ]; then
        fail_json '400 Bad Request' 'Фразы должны отличаться.'
        exit 0
    fi
    lock gpt || { fail_json '409 Conflict' 'Другое действие с GPT уже выполняется.'; exit 0; }
    { printf '1\t%s\n2\t%s\n3\t%s\n4\t%s\n' "$_p1" "$_p2" "$_p3" "$_p4"; } | atomic_write "$GPT_BASE/commands.txt"
    ok_message 'Фразы сохранены.'
    ;;
gpt_led_scope)
    _scope=$(query_get scope || true)
    [ "$_scope" = speaking ] || [ "$_scope" = active ] || { fail_json '400 Bad Request' 'Некорректный режим подсветки.'; exit 0; }
    set_led_scope "$_scope"
    ok_message 'Режим подсветки сохранён.'
    ;;
gpt_listen_led)
    _on=$(query_get on || true)
    [ "$_on" = 1 ] || [ "$_on" = 0 ] || { fail_json '400 Bad Request' 'Некорректное значение.'; exit 0; }
    set_listen_led "$_on"
    ok_message 'Подсветка в паузах сохранена.'
    ;;
gpt_vpn)
    _op=$(query_get op || true)
    case $_op in start|stop) ;; *) fail_json '400 Bad Request' 'Неизвестная операция VPN.'; exit 0 ;; esac
    lock gpt || { fail_json '409 Conflict' 'Другое действие с GPT уже выполняется.'; exit 0; }
    _was=0; gpt_running && _was=1
    if [ "$_op" = start ]; then
        [ "$_was" = 1 ] && sh "$GPT_BASE/run.sh" stop >/dev/null 2>&1 || true
        set_vpn_runtime on
        if ! _out=$(sh "$CLI_BASE/vpn.sh" start 2>&1); then
            set_vpn_runtime off
            rm -f "$CLI_BASE/vpn-required"
            [ "$_was" = 1 ] && sh "$GPT_BASE/run.sh" start >/dev/null 2>&1 || true
            _e=$(printf '%s' "$_out" | tail -n 4 | json_escape)
            printf '{"ok":false,"error":"VLESS не запустился: %s"}' "$_e" | respond '200 OK' application/json
            exit 0
        fi
        touch "$CLI_BASE/vpn-required"
        [ "$_was" = 1 ] && sh "$GPT_BASE/run.sh" start >/dev/null 2>&1 || true
        ok_message 'VLESS запущен, GPT переключён на туннель.'
    else
        [ "$_was" = 1 ] && sh "$GPT_BASE/run.sh" stop >/dev/null 2>&1 || true
        _out=$(sh "$CLI_BASE/vpn.sh" stop 2>&1) || {
            _e=$(printf '%s' "$_out" | tail -n 4 | json_escape)
            printf '{"ok":false,"error":"VLESS не остановился: %s"}' "$_e" | respond '200 OK' application/json
            exit 0
        }
        set_vpn_runtime off
        rm -f "$CLI_BASE/vpn-required"
        [ "$_was" = 1 ] && sh "$GPT_BASE/run.sh" start >/dev/null 2>&1 || true
        ok_message 'VLESS остановлен, GPT снова подключается напрямую.'
    fi
    ;;
bridge_start|bridge_stop|bridge_restart|bridge_check|bridge_check_backends)
    _name=${action#bridge_}; _name=$(printf '%s' "$_name" | tr '_' '-')
    lock bridge || { fail_json '409 Conflict' 'Другое действие с Bridge уже выполняется.'; exit 0; }
    _out=$(sh "$BRIDGE_BASE/app/control.sh" "$_name" 2>&1) || {
        _e=$(printf '%s' "$_out" | tail -n 4 | json_escape)
        printf '{"ok":false,"error":"%s"}' "$_e" | respond '200 OK' application/json; exit 0
    }
    _m=$(printf '%s' "$_out" | tail -n 4 | json_escape)
    printf '{"ok":true,"message":"%s"}' "$_m" | respond '200 OK' application/json
    ;;
bridge_config)
    _len=${CONTENT_LENGTH:-0}
    case $_len in ''|*[!0-9]*) _len=0 ;; esac
    if [ "$_len" -lt 2 ] || [ "$_len" -gt 262144 ]; then
        fail_json '413 Payload Too Large' 'Конфиг пустой или больше 256 КБ.'
        exit 0
    fi
    lock bridge || { fail_json '409 Conflict' 'Другое действие с Bridge уже выполняется.'; exit 0; }
    _body=$(head -c "$_len")
    _first=$(printf '%s' "$_body" | sed -n '1s/^[[:space:]]*//p' | cut -c1)
    [ "$_first" = '{' ] || { fail_json '400 Bad Request' 'Конфиг должен быть JSON-объектом.'; exit 0; }
    _cfg=$BRIDGE_BASE/config.json
    _bak=$_cfg.bak.$(date +%s)
    [ -r "$_cfg" ] && cp -p "$_cfg" "$_bak" || true
    printf '%s' "$_body" | atomic_write "$_cfg"
    if ! _check=$(sh "$BRIDGE_BASE/app/control.sh" check 2>&1); then
        [ -r "$_bak" ] && cp -p "$_bak" "$_cfg" || rm -f "$_cfg"
        _e=$(printf '%s' "$_check" | tail -n 4 | json_escape)
        printf '{"ok":false,"error":"Конфиг не прошёл проверку: %s"}' "$_e" | respond '400 Bad Request' application/json
        exit 0
    fi
    if bridge_running; then
        if ! _restart=$(sh "$BRIDGE_BASE/app/control.sh" restart 2>&1); then
            [ -r "$_bak" ] && cp -p "$_bak" "$_cfg" || true
            sh "$BRIDGE_BASE/app/control.sh" restart >/dev/null 2>&1 || true
            fail_json '500 Internal Server Error' 'Bridge не перезапустился; прежний конфиг восстановлен.'
            exit 0
        fi
        ok_message 'Конфиг сохранён, Bridge перезапущен.'
    else
        ok_message 'Конфиг сохранён. Bridge выключен; запустите его вручную.'
    fi
    ;;
bridge_env)
    _mode=$(query_get mode || true)
    case $_mode in hybrid|native|observe) ;; *) fail_json '400 Bad Request' 'Неизвестный режим Bridge.'; exit 0 ;; esac
    _base=$(query_get base_url || true); _model=$(query_get model || true)
    _api=$(query_get api || true); _key=$(query_get api_key || true); _home=$(query_get home_mcp_url || true)
    case $_api in chat_completions|responses|chatgpt) ;; *) fail_json '400 Bad Request' 'Неизвестный тип API.'; exit 0 ;; esac
    case $_base in ''|http://*|https://*) ;; *) fail_json '400 Bad Request' 'Адрес API должен начинаться с http:// или https://.'; exit 0 ;; esac
    case $_home in ''|http://*|https://*) ;; *) fail_json '400 Bad Request' 'Адрес Home Assistant MCP должен начинаться с http:// или https://.'; exit 0 ;; esac
    for _value in "$_model" "$_key"; do
        printf '%s' "$_value" | LC_ALL=C grep -q '[[:cntrl:]]' && { fail_json '400 Bad Request' 'Модель и ключ не должны содержать управляющих символов.'; exit 0; }
    done
    lock bridge || { fail_json '409 Conflict' 'Другое действие с Bridge уже выполняется.'; exit 0; }
    _file=$BRIDGE_BASE/runtime.env; _bak=$_file.bak.$(date +%s)
    [ -r "$_file" ] && cp -p "$_file" "$_bak" || true
    set_bridge_env "$_mode" "$_base" "$_model" "$_api" "$_key" "$_home"
    if bridge_running; then
        if ! _restart=$(sh "$BRIDGE_BASE/app/control.sh" restart 2>&1); then
            [ -r "$_bak" ] && cp -p "$_bak" "$_file" || true
            sh "$BRIDGE_BASE/app/control.sh" restart >/dev/null 2>&1 || true
            _e=$(printf '%s' "$_restart" | tail -n 4 | json_escape)
            printf '{"ok":false,"error":"Bridge не перезапустился: %s. Прежние настройки восстановлены."}' "$_e" | respond '200 OK' application/json
            exit 0
        fi
        ok_message 'Подключение сохранено, Bridge перезапущен.'
    else
        ok_message 'Подключение сохранено. Bridge выключен; запустите его вручную.'
    fi
    ;;
bridge_apply|bridge_rollback)
    _name=${action#bridge_}
    lock bridge || { fail_json '409 Conflict' 'Другое действие с Bridge уже выполняется.'; exit 0; }
    _out=$(sh "$BRIDGE_BASE/app/control.sh" "$_name" 2>&1) || {
        _e=$(printf '%s' "$_out" | tail -n 4 | json_escape)
        printf '{"ok":false,"error":"%s"}' "$_e" | respond '200 OK' application/json; exit 0
    }
    _m=$(printf '%s' "$_out" | tail -n 4 | json_escape)
    printf '{"ok":true,"message":"%s. Перезагрузите станцию, чтобы применить."}' "$_m" | respond '200 OK' application/json
    ;;
panel_password)
    _value=$(query_get value || true)
    valid_password "$_value" || { fail_json '400 Bad Request' 'Пароль: 8–64 символа, только A–Z a–z 0–9 . _ -'; exit 0; }
    lock panel || { fail_json '409 Conflict' 'Панель уже меняет настройки.'; exit 0; }
    PANEL_PASSWORD=$_value
    write_panel_conf
    write_lighttpd_conf
    write_lighttpd_user
    nohup sh -c "sleep 2; sh '$PANEL_BASE/start.sh' restart" >/dev/null 2>&1 &
    ok_message 'Пароль изменён. Через 2 секунды войдите с новым паролем.'
    ;;
station_reboot)
    lock panel || { fail_json '409 Conflict' 'Панель уже меняет настройки.'; exit 0; }
    nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 &
    ok_message 'Станция перезагружается.'
    ;;
*)
    fail_json '400 Bad Request' 'Неизвестное действие.'
    ;;
esac
