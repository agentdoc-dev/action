"""Exact GitHub fence ownership and fail-closed recovery."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('migration_source_fence', ROOT / 'scripts/migration-source-fence.py')
fence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fence)


class FenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.state = Path(self.directory.name).resolve() / 'state.json'
        self.instruction = {'format_version': 1, 'operation': 'create',
                            'migration_id': '10000000-0000-0000-0000-000000000001',
                            'configuration_receipt_digest': 'sha256:' + 'a' * 64,
                            'source_target_digest': 'sha256:' + 'b' * 64,
                            'external_repository_id': '123', 'owner': 'owner', 'name': 'repo',
                            'ref': 'refs/heads/source'}
        self.rule = dict(fence.create_payload(self.instruction), id=42, source='owner/repo', source_type='Repository')
        self.calls = []

    def api(self, method, path, body=None):
        self.calls.append((method, path, body))
        if path == '/repos/owner/repo':
            return {'id': 123, 'full_name': 'owner/repo'}
        if method == 'POST':
            return self.rule
        if '/rulesets?' in path:
            return []
        return self.rule

    def test_create_persists_owned_identity_then_reads_back(self):
        result = fence.perform(self.instruction, self.state, self.api)
        self.assertEqual(result['outcome'], 'held')
        self.assertEqual(result['ruleset_id'], '42')
        self.assertEqual(len(result['projection']['name']), 66)
        self.assertEqual(fence.common.parse(self.state.read_bytes())['ruleset_id'], '42')
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertEqual(sum(method == 'POST' for method, _, _ in self.calls), 1)
        self.calls.clear()
        fence.perform(self.instruction, self.state, self.api)
        self.assertTrue(all(method == 'GET' for method, _, _ in self.calls))

    def test_false_update_parameter_omission_normalizes(self):
        expected = fence.projection(self.rule, self.instruction)
        self.rule['rules'][1].pop('parameters')
        self.rule['rules'].reverse()
        self.assertEqual(fence.projection(self.rule, self.instruction), expected)

    def test_missing_bypass_extra_rule_and_wrong_target_refuse(self):
        for mutate in [lambda r: r.pop('bypass_actors'),
                       lambda r: r['rules'].append({'type': 'non_fast_forward'}),
                       lambda r: r['conditions']['ref_name']['include'].append('refs/heads/other'),
                       lambda r: r['rules'][1]['parameters'].update(update_allows_fetch_and_merge=True),
                       lambda r: r.update(source_type='Organization')]:
            rule = copy.deepcopy(self.rule)
            mutate(rule)
            with self.subTest(rule=rule), self.assertRaises(fence.common.Refusal):
                fence.projection(rule, self.instruction)

    def test_lost_create_never_reposts_and_reconciles_only_exact_match(self):
        def lost(method, path, body=None):
            if method == 'POST':
                self.assertEqual(fence.common.parse(self.state.read_bytes())['phase'], 'pending')
                raise TimeoutError()
            return self.api(method, path, body)
        with self.assertRaises(TimeoutError):
            fence.perform(self.instruction, self.state, lost)
        self.calls.clear()
        with self.assertRaises(fence.common.Refusal):
            fence.perform(self.instruction, self.state, self.api)
        self.assertTrue(all(method == 'GET' for method, _, _ in self.calls))
        def found(method, path, body=None):
            if '/rulesets?' in path:
                return [{'id': 42, 'name': self.rule['name']}]
            return self.api(method, path, body)
        result = fence.perform(dict(self.instruction, operation='reconcile'), self.state, found)
        self.assertEqual(result['ruleset_id'], '42')

    def test_known_created_id_survives_failed_readback(self):
        def failed_read(method, path, body=None):
            if path.endswith('/rulesets/42'):
                raise TimeoutError()
            return self.api(method, path, body)
        with self.assertRaises(TimeoutError):
            fence.perform(self.instruction, self.state, failed_read)
        state = fence.common.parse(self.state.read_bytes())
        self.assertEqual((state['phase'], state['ruleset_id']), ('created', '42'))
        self.calls.clear()
        self.assertEqual(fence.perform(dict(self.instruction, operation='reconcile'), self.state, self.api)['outcome'], 'held')
        self.assertTrue(all(method == 'GET' for method, _, _ in self.calls))

    def test_known_identity_replacement_or_changed_binding_refuses(self):
        fence.perform(self.instruction, self.state, self.api)
        self.rule['id'] = 43
        with self.assertRaises(fence.common.Refusal):
            fence.perform(dict(self.instruction, operation='read'), self.state, self.api)
        with self.assertRaises(fence.common.Refusal):
            fence.perform(dict(self.instruction, configuration_receipt_digest='sha256:' + 'c' * 64), self.state, self.api)

    def test_collision_does_not_adopt_or_post(self):
        def collision(method, path, body=None):
            if '/rulesets?' in path:
                return [{'id': 42, 'name': self.rule['name']}]
            return self.api(method, path, body)
        with self.assertRaises(fence.common.Refusal):
            fence.perform(self.instruction, self.state, collision)
        self.assertFalse(self.state.exists())
        self.assertFalse(any(method == 'POST' for method, _, _ in self.calls))

    def test_no_delete_mode_and_no_repository_alias(self):
        with self.assertRaises(fence.common.Refusal):
            fence.perform(dict(self.instruction, operation='delete'), self.state, self.api)
        with self.assertRaises(fence.common.Refusal):
            fence.perform(dict(self.instruction, name='..'), self.state, self.api)
        with self.assertRaises(fence.common.Refusal):
            fence.perform(dict(self.instruction, external_repository_id='124'), self.state, self.api)
        self.assertFalse(self.state.exists())


if __name__ == '__main__':
    unittest.main()
