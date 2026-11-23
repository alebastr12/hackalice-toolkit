import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
CGI = ROOT / 'cgi-bin' / 'api.cgi'


class ApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.gpt = self.base / 'gpt'
        self.cli = self.base / 'cli'
        self.bridge = self.base / 'bridge'
        self.state = self.gpt / 'state'
        self.runtime = self.base / 'runtime'
        self.panel = self.base / 'panel'
        self.init = self.base / 'init'
        for folder in (self.gpt / 'bin', self.cli, self.bridge / 'app',
                       self.state, self.runtime, self.panel, self.init):
            folder.mkdir(parents=True, exist_ok=True)
        (self.panel / 'panel.conf').write_text(
            'PANEL_USER=admin\nPANEL_PORT=8099\nPANEL_TOKEN=test-token\nPANEL_PASSWORD=testpass\n')
        (self.bridge / 'VERSION').write_text('0.6.2\n')
        (self.bridge / 'config.json').write_text('{"llm_base_url":"https://example.test/v1"}\n')
        (self.bridge / 'endpoint-backup.json').write_text('{}\n')
        (self.bridge / 'runtime.env').write_text(
            '# BEGIN QUASAR SETUP\n'
            'QUASAR_MODE="hybrid"\n'
            'QUASAR_LLM_BASE_URL="https://llm.example/v1"\n'
            'QUASAR_LLM_MODEL="test-model"\n'
            'QUASAR_LLM_API="chat_completions"\n'
            'QUASAR_LLM_API_KEY="secret-key"\n'
            'QUASAR_HOME_MCP_URL=""\n'
            '# END QUASAR SETUP\n'
            'QUASAR_ALLOWED_IPS="192.168.1.0/24"\n'
            'export ALISA_LED_STYLE=rainbow\n')
        (self.bridge / 'app' / 'control.sh').write_text(
            '#!/bin/sh\n'
            f'state={self.bridge}\n'
            'case "$1" in\n'
            'status) exit 1;;\n'
            'check) if grep -q bad "$state/config.json"; then echo "config error"; exit 1; fi; exit 0;;\n'
            'restart) echo "Bridge healthy (PID 1)"; exit 0;;\n'
            'logs) echo "bridge log";;\n'
            '*) echo ok;;\n'
            'esac\n')
        (self.bridge / 'app' / 'control.sh').chmod(0o755)
        (self.bridge / 'app' / 'start.sh').write_text(
            '#!/bin/sh\n'
            'if [ "${ALISA_TEST_CHATGPT_EXPIRED:-}" = 1 ]; then\n'
            '  echo "{\\"error\\":\\"ChatGPT sign-in unavailable\\"}" >&2\n'
            '  exit 1\n'
            'fi\n'
            'printf \'model-a\\t"Model A"\\nmodel-b\\t"Model B"\\n\'\n')
        (self.bridge / 'app' / 'start.sh').chmod(0o755)
        (self.cli / 'vpn.sh').write_text(
            '#!/bin/sh\n'
            f'state={self.cli}\n'
            'case "$1" in\n'
            'status) [ -f "$state/vpn.running" ] && exit 0 || exit 1;;\n'
            'start) : > "$state/vpn.running"; echo started;;\n'
            'stop) rm -f "$state/vpn.running"; echo stopped;;\n'
            'esac\n')
        (self.cli / 'vpn.sh').chmod(0o755)
        (self.cli / 'boot.sh').write_text('#!/bin/sh\n')
        (self.cli / 'boot.sh').chmod(0o755)
        (self.gpt / 'bin' / 'alisa-standalone').write_text(
            '#!/bin/sh\n'
            'case "$1" in\n'
            'status) echo \'{"phase":"idle","agent_connected":true,"login_saved":true,'
            '"settings":{"voice":"cove","selected":"c1","chats":[{"id":"c1","title":"Тест"}]},"rss_kib":123}\';;\n'
            'url) echo \'{"port":18080,"pairing_code":"12345678"}\';;\n'
            '*) echo \'{"ok":true}\';;\n'
            'esac\n')
        (self.gpt / 'bin' / 'alisa-standalone').chmod(0o755)
        (self.gpt / 'run.sh').write_text('#!/bin/sh\ncase "$1" in start) echo starting;; stop) echo stopped;; esac\n')
        (self.gpt / 'run.sh').chmod(0o755)
        (self.gpt / 'commands.txt').write_text('1\tоткрой чат\n2\tсоздай новый чат\n3\tзакрой чат\n4\tоткрой предыдущий чат\n')
        (self.gpt / 'led-scope').write_text('speaking rainbow\n')
        (self.gpt / 'listen-led').write_text('0\n')
        (self.gpt / 'runtime.env').write_text('export ALISA_LED_STYLE=rainbow\n')
        (self.state / 'web-session.json').write_text('{"account_id":"x"}')
        (self.state / 'settings.json').write_text('{"version":1,"voice":"cove","selected":"","previous":"","chats":[]}\n')
        (self.cli / 'native-autostart').write_text('enabled\n')
        (self.init / 'S96quasar-bridge').write_text('init\n')
        (self.init / 'S99zz-alisa-voice').write_text('init\n')
        (self.base / 'bin').mkdir()
        (self.base / 'bin' / 'wget').write_text('#!/bin/sh\nexit 0\n')
        (self.base / 'bin' / 'wget').chmod(0o755)
        (self.base / 'bin' / 'curl').write_text(
            '#!/bin/sh\n'
            'case "$*" in\n'
            '  *"/diagnostics/api/chatgpt/start"*)\n'
            '    printf \'%s\\n200\' \'{"automatic_return":true,"authorization_url":'
            '"https://auth.openai.com/authorize?state=1&x=2"}\' ;;\n'
            '  *"/diagnostics/api/chatgpt/complete"*)\n'
            '    case "$*" in\n'
            '      *denied*) printf \'%s\\n422\' \'{"error":"Вход отменён в ChatGPT."}\'; exit 22 ;;\n'
            '      *) printf \'%s\\n200\' \'{}\' ;;\n'
            '    esac ;;\n'
            '  *"/diagnostics/api/chatgpt/logout"*)\n'
            '    echo logout >> "${ALISA_TEST_DIAG:-/dev/null}"; printf \'%s\\n200\' \'{}\' ;;\n'
            '  *"/diagnostics/api/chatgpt"*)\n'
            '    printf \'%s\\n200\' \'{"signed_in":false,"email":"","uses_chatgpt":true}\' ;;\n'
            '  *models*) echo \'{"data":[{"id":"model-a"},{"id":"model-b"}]}\' ;;\n'
            '  *) exit 0 ;;\n'
            'esac\n')
        (self.base / 'bin' / 'curl').chmod(0o755)
        self.env = {
            **os.environ,
            'ALISA_PANEL_BASE': str(self.panel),
            'ALISA_PANEL_CONF': str(self.panel / 'panel.conf'),
            'ALISA_PANEL_GPT_BASE': str(self.gpt),
            'ALISA_PANEL_CLI_BASE': str(self.cli),
            'ALISA_PANEL_BRIDGE_BASE': str(self.bridge),
            'ALISA_PANEL_STATE': str(self.state),
            'ALISA_PANEL_RUNTIME': str(self.runtime),
            'ALISA_PANEL_INIT_DIR': str(self.init),
            'ALISA_PANEL_FAKE_GPT_RUNNING': '1',
            'ALISA_TEST_DIAG': str(self.base / 'diag.log'),
            'HTTP_HOST': '127.0.0.1:8099',
            'PATH': str(self.base / 'bin') + ':/usr/bin:/bin',
        }

    def tearDown(self):
        self.tmp.cleanup()

    def call(self, method='GET', query='', body=b'', token=None):
        env = {**self.env, 'REQUEST_METHOD': method, 'QUERY_STRING': query,
               'CONTENT_LENGTH': str(len(body))}
        if token is not None:
            env['HTTP_X_PANEL_TOKEN'] = token
        result = subprocess.run(['/bin/sh', str(CGI)], env=env, input=body,
                                capture_output=True, timeout=30)
        head, _, payload = result.stdout.partition(b'\r\n\r\n')
        status = head.split(b'\r\n', 1)[0].decode()
        return status, payload.decode()

    def test_status_is_valid_json(self):
        status, payload = self.call(query='action=status')
        self.assertIn('200', status)
        data = json.loads(payload)
        self.assertEqual(data['bridge']['version'], '0.6.2')
        self.assertEqual(data['bridge']['installed'], 1)
        self.assertEqual(data['bridge']['endpoint_applied'], 1)
        self.assertIn('vpn_required', data['flags'])
        self.assertEqual(data['flags']['boot_hook'], 1)
        self.assertEqual(data['gpt']['running'], 1)
        self.assertEqual(data['gpt']['login_saved'], 1)
        raw = json.loads(data['gpt']['raw'])
        self.assertEqual(raw['settings']['chats'][0]['title'], 'Тест')
        self.assertEqual(raw['phase'], 'idle')
        self.assertEqual(data['flags']['led_scope'], 'speaking')
        self.assertEqual(data['flags']['led_style'], 'rainbow')
        self.assertEqual(data['flags']['listen_led'], 0)
        self.assertEqual(data['phrases']['open'], 'открой чат')
        self.assertEqual(json.loads(data['native_ui']['raw'])['pairing_code'], '12345678')

    def test_token_endpoint(self):
        status, payload = self.call(query='action=token')
        self.assertIn('200', status)
        self.assertEqual(json.loads(payload)['token'], 'test-token')

    def test_post_requires_token(self):
        status, payload = self.call(method='POST', query='action=gpt_listen_led&on=1')
        self.assertIn('403', status)
        self.assertFalse(json.loads(payload)['ok'])

    def test_bad_chat_id_is_rejected(self):
        status, payload = self.call(method='POST', query='action=gpt_select&chat_id=../etc/passwd',
                                    token='test-token')
        self.assertIn('400', status)
        self.assertFalse(json.loads(payload)['ok'])

    def test_listen_led_is_written(self):
        status, payload = self.call(method='POST', query='action=gpt_listen_led&on=1',
                                    token='test-token')
        self.assertTrue(json.loads(payload)['ok'])
        self.assertEqual((self.gpt / 'listen-led').read_text(), '1\n')

    def test_phrases_accept_cyrillic(self):
        query = 'action=gpt_phrases&' + urlencode({
            'open': 'открой чат', 'new': 'новый чат', 'close': 'закрой чат',
            'previous': 'прошлый чат'})
        status, payload = self.call(method='POST', query=query, token='test-token')
        self.assertTrue(json.loads(payload)['ok'], payload)
        self.assertEqual((self.gpt / 'commands.txt').read_text(),
                         '1\tоткрой чат\n2\tновый чат\n3\tзакрой чат\n4\tпрошлый чат\n')

    def test_duplicate_phrases_are_rejected(self):
        query = 'action=gpt_phrases&' + urlencode({
            'open': 'чат', 'new': 'чат', 'close': 'закрой', 'previous': 'прошлый'})
        status, payload = self.call(method='POST', query=query, token='test-token')
        self.assertIn('400', status)

    def test_stun_toggle_preserves_other_env(self):
        status, payload = self.call(method='POST', query='action=gpt_stun&on=0',
                                    token='test-token')
        self.assertTrue(json.loads(payload)['ok'])
        text = (self.gpt / 'runtime.env').read_text()
        self.assertIn('ALISA_LED_STYLE=rainbow', text)
        self.assertIn('ALISA_DISABLE_STUN=1', text)
        status, payload = self.call(method='POST', query='action=gpt_stun&on=1',
                                    token='test-token')
        text = (self.gpt / 'runtime.env').read_text()
        self.assertIn('ALISA_LED_STYLE=rainbow', text)
        self.assertNotIn('ALISA_DISABLE_STUN', text)

    def test_gpt_settings_group(self):
        query = 'action=gpt_settings&' + urlencode({
            'voice': 'breeze', 'style': 'blue', 'scope': 'active', 'listen': '1',
            'autostart': '0', 'vpn_autostart': '1', 'stun': '1'})
        status, payload = self.call(method='POST', query=query, token='test-token')
        self.assertTrue(json.loads(payload)['ok'], payload)
        self.assertEqual((self.gpt / 'led-scope').read_text(), 'active blue\n')
        self.assertEqual((self.gpt / 'listen-led').read_text(), '1\n')
        self.assertIn('ALISA_LED_STYLE=blue', (self.gpt / 'runtime.env').read_text())
        self.assertNotIn('ALISA_DISABLE_STUN', (self.gpt / 'runtime.env').read_text())
        self.assertFalse((self.cli / 'native-autostart').exists())
        self.assertTrue((self.cli / 'vpn-autostart').exists())

    def test_gpt_settings_stun_change(self):
        status, payload = self.call(method='POST', query='action=gpt_settings&stun=0',
                                    token='test-token')
        self.assertTrue(json.loads(payload)['ok'], payload)
        self.assertIn('ALISA_DISABLE_STUN=1', (self.gpt / 'runtime.env').read_text())

    def test_gpt_settings_voice_when_stopped(self):
        self.env['ALISA_PANEL_FAKE_GPT_RUNNING'] = ''
        try:
            status, payload = self.call(method='POST', query='action=gpt_settings&voice=ember',
                                        token='test-token')
        finally:
            self.env['ALISA_PANEL_FAKE_GPT_RUNNING'] = '1'
        self.assertTrue(json.loads(payload)['ok'], payload)
        self.assertIn('"voice":"ember"', (self.state / 'settings.json').read_text())

    def test_bridge_models(self):
        status, payload = self.call(query='action=bridge_models')
        data = json.loads(payload)
        self.assertTrue(data['ok'], payload)
        self.assertEqual([m['id'] for m in data['models']], ['model-a', 'model-b'])
        self.assertEqual(data['models'][0]['name'], 'Model A')

    def test_chatgpt_status(self):
        status, payload = self.call(query='action=chatgpt_status')
        self.assertIn('200', status)
        data = json.loads(payload)
        self.assertTrue(data['ok'], payload)
        self.assertFalse(data['signed_in'])
        self.assertTrue(data['uses_chatgpt'])

    def test_chatgpt_login_start(self):
        status, payload = self.call(method='POST', query='action=chatgpt_login_start',
                                    token='test-token')
        self.assertIn('200', status)
        data = json.loads(payload)
        self.assertTrue(data['ok'], payload)
        self.assertIn('state=1&x=2', data['url'])
        self.assertTrue(data['automatic'])

    def test_chatgpt_login_complete(self):
        query = 'action=chatgpt_login_complete&' + urlencode({
            'callback': 'http://127.0.0.1:2704/auth/callback?code=abc&state=def'})
        status, payload = self.call(method='POST', query=query, token='test-token')
        self.assertIn('200', status)
        self.assertTrue(json.loads(payload)['ok'], payload)

    def test_chatgpt_logout(self):
        status, payload = self.call(method='POST', query='action=chatgpt_logout',
                                    token='test-token')
        self.assertIn('200', status)
        self.assertTrue(json.loads(payload)['ok'], payload)
        self.assertIn('logout', (self.base / 'diag.log').read_text())

    def test_chatgpt_login_complete_rejects_foreign_url(self):
        query = 'action=chatgpt_login_complete&' + urlencode({
            'callback': 'https://example.com/auth/callback?code=abc'})
        status, payload = self.call(method='POST', query=query, token='test-token')
        self.assertIn('400', status)
        self.assertFalse(json.loads(payload)['ok'])

    def test_chatgpt_login_complete_reports_denied(self):
        query = 'action=chatgpt_login_complete&' + urlencode({
            'callback': 'http://127.0.0.1:2704/auth/callback?error=denied'})
        status, payload = self.call(method='POST', query=query, token='test-token')
        self.assertIn('422', status)
        data = json.loads(payload)
        self.assertFalse(data['ok'])
        self.assertIn('отмен', data['error'])

    def test_bridge_models_requires_chatgpt_login(self):
        self.env['ALISA_TEST_CHATGPT_EXPIRED'] = '1'
        try:
            status, payload = self.call(query='action=bridge_models')
        finally:
            self.env.pop('ALISA_TEST_CHATGPT_EXPIRED', None)
        self.assertIn('409', status)
        data = json.loads(payload)
        self.assertFalse(data['ok'])
        self.assertIn('ChatGPT', data['error'])

    def test_bridge_env_read(self):
        status, payload = self.call(query='action=bridge_env')
        data = json.loads(payload)
        self.assertEqual(data['mode'], 'hybrid')
        self.assertEqual(data['base_url'], 'https://llm.example/v1')
        self.assertEqual(data['model'], 'test-model')
        self.assertEqual(data['api'], 'chat_completions')
        self.assertEqual(data['api_key'], 'secret-key')

    def test_bridge_env_save_preserves_unknown_lines(self):
        query = 'action=bridge_env&' + urlencode({
            'mode': 'hybrid', 'base_url': 'https://new.example/v1', 'model': 'new-model',
            'api': 'responses', 'api_key': 'new-key', 'home_mcp_url': 'https://ha.example/mcp'})
        status, payload = self.call(method='POST', query=query, token='test-token')
        self.assertTrue(json.loads(payload)['ok'], payload)
        text = (self.bridge / 'runtime.env').read_text()
        self.assertIn('QUASAR_LLM_BASE_URL="https://new.example/v1"', text)
        self.assertIn('QUASAR_LLM_API="responses"', text)
        self.assertIn('QUASAR_LLM_API_KEY="new-key"', text)
        self.assertIn('QUASAR_ALLOWED_IPS="192.168.1.0/24"', text)
        self.assertIn('export ALISA_LED_STYLE=rainbow', text)
        self.assertEqual(text.count('# BEGIN QUASAR SETUP'), 1)

    def test_gpt_start_refuses_without_vpn(self):
        (self.cli / 'vpn-required').write_text('required\n')
        status, payload = self.call(method='POST', query='action=gpt_start', token='test-token')
        self.assertIn('409', status)
        self.assertFalse(json.loads(payload)['ok'])
        (self.cli / 'vpn-required').unlink()

    def test_gpt_vpn_transaction(self):
        status, payload = self.call(method='POST', query='action=gpt_vpn&op=start', token='test-token')
        self.assertTrue(json.loads(payload)['ok'], payload)
        self.assertTrue((self.cli / 'vpn.running').exists())
        self.assertTrue((self.cli / 'vpn-required').exists())
        text = (self.gpt / 'runtime.env').read_text()
        self.assertIn('ALISA_PROXY_URL=socks5h://127.0.0.1:18081', text)
        self.assertIn('ALISA_LED_STYLE=rainbow', text)
        status, payload = self.call(method='POST', query='action=gpt_vpn&op=stop', token='test-token')
        self.assertTrue(json.loads(payload)['ok'], payload)
        self.assertFalse((self.cli / 'vpn.running').exists())
        self.assertFalse((self.cli / 'vpn-required').exists())
        self.assertNotIn('ALISA_PROXY_URL', (self.gpt / 'runtime.env').read_text())

    def test_bridge_config_rolls_back_on_check_failure(self):
        original = (self.bridge / 'config.json').read_text()
        body = b'{"llm_base_url":"bad"}'
        status, payload = self.call(method='POST', query='action=bridge_config',
                                    body=body, token='test-token')
        self.assertIn('400', status)
        self.assertFalse(json.loads(payload)['ok'])
        self.assertEqual((self.bridge / 'config.json').read_text(), original)

    def test_bridge_config_is_saved_without_restart_error(self):
        body = b'{"llm_base_url":"https://new.test/v1"}'
        status, payload = self.call(method='POST', query='action=bridge_config',
                                    body=body, token='test-token')
        self.assertTrue(json.loads(payload)['ok'], payload)
        self.assertEqual((self.bridge / 'config.json').read_text(), body.decode())


if __name__ == '__main__':
    unittest.main()
