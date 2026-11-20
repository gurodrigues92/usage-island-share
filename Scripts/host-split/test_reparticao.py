import contextlib
import io
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch


class SplitMergeTests(unittest.TestCase):
    def merge(self, mac, remote, previous=None):
        source = Path(__file__).with_name('reparticao-uso').read_text()
        body = re.search(r"python3 - <<'PY'.*?\n(.*?)\nPY", source, re.S).group(1)
        with tempfile.TemporaryDirectory() as directory:
            old = Path(directory) / 'previous.json'
            old.write_text(json.dumps(previous or {}))
            env = {'MAC': json.dumps(mac) if mac is not None else '',
                   'VPS': json.dumps(remote) if remote is not None else '', 'ANTIGO': str(old)}
            output = io.StringIO()
            with patch.dict(os.environ, env), contextlib.redirect_stdout(output):
                exec(compile(body, 'split-merge', 'exec'), {})
            return json.loads(output.getvalue())

    def measure(self, tokens):
        return {'dias': 7, 'medido_em': '2026-10-14T10:00:00Z',
                'provedores': {'Codex': {'tokens': tokens}}}

    def test_missing_mac_keeps_previous_measurement_without_claiming_completeness(self):
        value = self.merge(None, self.measure(100), {'mac_bruto': self.measure(50)})
        self.assertFalse(value['completo'])
        self.assertFalse(value['provedores']['Codex']['completo'])
        self.assertEqual(value['provedores']['Codex']['mac_tokens'], 50)

    def test_missing_remote_does_not_become_a_fresh_zero(self):
        value = self.merge(self.measure(50), None, {'vps_bruto': self.measure(100)})
        self.assertFalse(value['completo'])
        self.assertEqual(value['provedores']['Codex']['vps_tokens'], 100)
        self.assertEqual(value['vps_medido_em'], '2026-10-14T10:00:00Z')

    def test_missing_provider_is_distinct_from_measured_zero(self):
        value = self.merge(self.measure(50), {'provedores': {}, 'dias': 7})
        self.assertFalse(value['provedores']['Codex']['completo'])
        measured = self.merge(self.measure(50), self.measure(0))
        self.assertTrue(measured['provedores']['Codex']['completo'])

    def test_valid_complete_measurements_are_combined(self):
        value = self.merge(self.measure(30), self.measure(70))
        self.assertTrue(value['completo'])
        self.assertEqual(value['provedores']['Codex']['fatia_mac'], 30)
        self.assertEqual(value['provedores']['Codex']['fatia_vps'], 70)

    def test_invalid_counts_do_not_become_valid_proportions(self):
        self.assertEqual(self.merge(self.measure(-1), self.measure(20))['provedores'], {})
        self.assertEqual(self.merge(self.measure(True), self.measure(20))['provedores'], {})


if __name__ == '__main__':
    unittest.main()
