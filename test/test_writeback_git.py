"""Actual disposable Git receiver tests for the private writeback primitive."""
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROGRAM = ROOT / 'scripts/writeback-git.sh'


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


class WritebackGitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='adoc-writeback-test-')
        self.directory = Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        self.env = {'PATH': '/usr/bin:/bin:/usr/local/bin', 'HOME': str(self.directory),
                    'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                    'WRITEBACK_LOCAL_ROOT': str(self.directory)}
        self.repo = self.directory / 'source'
        self.remote = self.directory / 'remote.git'
        self.git('init', '-q', '-b', 'target', str(self.repo))
        self.git('-C', str(self.repo), 'config', 'user.name', 'Fixture')
        self.git('-C', str(self.repo), 'config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'docs').mkdir()
        (self.repo / 'docs/policy.adoc').write_bytes(b'old policy\n')
        (self.repo / 'unrelated').write_bytes(b'unchanged\n')
        self.git('-C', str(self.repo), 'add', '.')
        self.git('-C', str(self.repo), 'commit', '-qm', 'fixture old')
        self.old = self.git('-C', str(self.repo), 'rev-parse', 'HEAD').decode().strip()
        self.git('clone', '-q', '--bare', str(self.repo), str(self.remote))
        self.git('--git-dir', str(self.remote), 'config', 'core.logAllRefUpdates', 'always')
        self.payload = self.directory / 'payload.bin'
        self.private(self.payload, b'new policy\n')
        self.instruction = {
            'format_version': 1, 'writeback_id': '10000000-0000-0000-0000-000000000001',
            'record_digest': 'sha256:' + 'a' * 64, 'payload_digest': digest(self.payload.read_bytes()),
            'target_id': '20000000-0000-0000-0000-000000000001',
            'target_digest': 'sha256:' + 'b' * 64, 'remote': str(self.remote),
            'ref': 'refs/heads/target', 'path': 'docs/policy.adoc',
            'expected_old_oid': self.old, 'expected_source_digest': digest(b'old policy\n'),
        }
        self.calls = 0
        self.call_lock = threading.Lock()

    def git(self, *args):
        return subprocess.run(['/usr/bin/git', *args], env=self.env, check=True,
                              capture_output=True).stdout

    def private(self, path, data):
        path.write_bytes(data)
        path.chmod(0o600)

    def invoke(self, mode, material=None, instruction=None, env=None):
        with self.call_lock:
            self.calls += 1
            call = self.calls
        path = self.directory / f'instruction-{call}.json'
        self.private(path, json.dumps(instruction or self.instruction).encode())
        output = self.directory / f'output-{call}.json'
        args = [str(PROGRAM), mode, str(path), str(self.payload)]
        if material is not None:
            material_path = self.directory / f'material-{call}.json'
            self.private(material_path, json.dumps(material).encode())
            args.append(str(material_path))
        args.append(str(output))
        result = subprocess.run(args, env=env or self.env, capture_output=True, timeout=35)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, b'')
        self.assertEqual(result.stderr, b'')
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        return json.loads(output.read_bytes())

    def head(self):
        return self.git('--git-dir', str(self.remote), 'rev-parse', self.instruction['ref']).decode().strip()

    def test_prepare_apply_observe_exact_real_effect(self):
        prepared = self.invoke('prepare')
        self.assertEqual(prepared['outcome'], 'prepared')
        self.assertEqual(self.head(), self.old, 'prepare must never push')
        material = prepared['material']
        result = self.invoke('apply', material)
        self.assertEqual(result, {'format_version': 1, 'outcome': 'applied',
                                  'observed_oid': material['prepared_new_oid']})
        self.assertEqual(self.head(), material['prepared_new_oid'])
        self.assertEqual(self.git('--git-dir', str(self.remote), 'show', self.head()+':docs/policy.adoc'), self.payload.read_bytes())
        self.assertEqual(self.git('--git-dir', str(self.remote), 'show', self.head()+':unrelated'), b'unchanged\n')
        self.assertEqual(self.git('--git-dir', str(self.remote), 'rev-parse', self.head()+'^').decode().strip(), self.old)
        self.assertEqual(self.invoke('observe', material)['outcome'], 'present')


    def advance(self):
        (self.repo / 'unrelated').write_bytes(b'external edit\n')
        self.git('-C', str(self.repo), 'commit', '-qam', 'external advance')
        self.git('-C', str(self.repo), 'push', '-q', str(self.remote), 'HEAD:refs/heads/target')
        return self.head()

    def effect_count(self):
        return len(self.git('--git-dir', str(self.remote), 'reflog', 'show', '--format=%H',
                            'refs/heads/target').splitlines())

    def test_stale_target_and_wrong_original_digest_refuse(self):
        material = self.invoke('prepare')['material']
        advanced = self.advance()
        self.assertEqual(self.invoke('apply', material), {
            'format_version': 1, 'outcome': 'refused', 'observed_oid': advanced})
        self.assertEqual(self.head(), advanced)
        wrong = dict(self.instruction, expected_source_digest='sha256:' + 'c' * 64)
        self.assertEqual(self.invoke('prepare', instruction=wrong)['outcome'], 'refused')
        self.assertEqual(self.effect_count(), 1)

    def test_material_survives_clone_loss_and_repeated_observation(self):
        material = self.invoke('prepare')['material']
        shutil.rmtree(self.repo)
        self.assertEqual(self.invoke('apply', material)['outcome'], 'applied')
        for _ in range(5):
            self.assertEqual(self.invoke('observe', material)['outcome'], 'present')
        self.assertEqual(self.effect_count(), 1)
        self.assertFalse(list(self.directory.glob('writeback-*')))
        self.assertFalse(list(self.directory.glob('readback-*')))

    def test_concurrent_exact_cas_has_one_real_ref_effect(self):
        first = self.invoke('prepare')['material']
        other = dict(self.instruction, writeback_id='10000000-0000-0000-0000-000000000002')
        second = self.invoke('prepare', instruction=other)['material']
        self.assertNotEqual(first['prepared_new_oid'], second['prepared_new_oid'])
        with ThreadPoolExecutor(max_workers=2) as pool:
            a = pool.submit(self.invoke, 'apply', first)
            b = pool.submit(self.invoke, 'apply', second, other)
            results = [a.result(), b.result()]
        self.assertEqual(sum(result['outcome'] == 'applied' for result in results), 1)
        self.assertIn(self.head(), (first['prepared_new_oid'], second['prepared_new_oid']))
        self.assertEqual(self.effect_count(), 1)

    def test_receiver_denial_remains_authoritative(self):
        material = self.invoke('prepare')['material']
        hook = self.remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o700)
        self.assertEqual(self.invoke('apply', material)['outcome'], 'refused')
        self.assertEqual(self.head(), self.old)
        self.assertEqual(self.effect_count(), 0)

    def test_observe_external_rewind_never_reapplies(self):
        material = self.invoke('prepare')['material']
        self.assertEqual(self.invoke('apply', material)['outcome'], 'applied')
        self.git('--git-dir', str(self.remote), 'update-ref', 'refs/heads/target', self.old,
                 material['prepared_new_oid'])
        self.assertEqual(self.invoke('observe', material), {
            'format_version': 1, 'outcome': 'diverged', 'observed_oid': self.old})
        self.assertEqual(self.head(), self.old)
        self.assertEqual(self.effect_count(), 2)

    def test_tampered_material_and_payload_never_send(self):
        material = self.invoke('prepare')['material']
        mutated = dict(material, unexpected=True)
        self.assertEqual(self.invoke('apply', mutated)['outcome'], 'refused')
        mutated = dict(material, commit_bytes_base64=base64.b64encode(b'wrong').decode())
        self.assertEqual(self.invoke('apply', mutated)['outcome'], 'refused')
        mutated = dict(material, trees=list(reversed(material['trees'])))
        self.assertEqual(self.invoke('apply', mutated)['outcome'], 'refused')
        self.private(self.payload, b'changed after preparation\n')
        self.assertEqual(self.invoke('apply', material)['outcome'], 'refused')
        self.assertEqual(self.head(), self.old)
        self.assertEqual(self.effect_count(), 0)

    def test_instruction_boundaries_and_private_payload(self):
        for changes in ({'path': '../unrelated'}, {'path': '.git/config'},
                        {'path': 'docs//policy.adoc'}, {'path': 'docs/../unrelated'},
                        {'ref': 'refs/heads/target:refs/heads/other'},
                        {'remote': 'file://' + str(self.remote)},
                        {'format_version': True}, {'extra': 'field'}):
            with self.subTest(changes=changes):
                self.assertEqual(self.invoke('prepare', instruction=dict(self.instruction, **changes))['outcome'], 'refused')
        self.payload.chmod(0o644)
        self.assertEqual(self.invoke('prepare')['outcome'], 'refused')
        self.payload.chmod(0o600)
        linked = self.directory / 'linked-payload'
        os.link(self.payload, linked)
        self.assertEqual(self.invoke('prepare')['outcome'], 'refused')
        self.assertEqual(self.head(), self.old)

    def test_ambient_git_config_and_hooks_are_not_loaded(self):
        marker = self.directory / 'ambient-hook-ran'
        hooks = self.directory / 'hostile-hooks'
        hooks.mkdir()
        hook = hooks / 'pre-push'
        hook.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\nexit 1\n')
        hook.chmod(0o700)
        config = self.directory / 'hostile.gitconfig'
        config.write_text('[core]\n hooksPath = ' + str(hooks) + '\n')
        env = dict(self.env, GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_COUNT='1',
                   GIT_CONFIG_KEY_0='core.hooksPath', GIT_CONFIG_VALUE_0=str(hooks))
        material = self.invoke('prepare', env=env)['material']
        self.assertEqual(self.invoke('apply', material, env=env)['outcome'], 'applied')
        self.assertFalse(marker.exists())
        self.assertEqual(self.effect_count(), 1)


    def test_actual_effect_with_lost_readback_reconciles_without_second_push(self):
        material = self.invoke('prepare')['material']
        moved = self.directory / 'receiver-after-effect.git'
        hook = self.remote / 'hooks/post-receive'
        hook.write_text('#!/bin/sh\nmv "' + str(self.remote) + '" "' + str(moved) + '"\n')
        hook.chmod(0o700)
        self.assertEqual(self.invoke('apply', material), {
            'format_version': 1, 'outcome': 'unknown', 'observed_oid': None})
        self.assertFalse(self.remote.exists())
        actual = self.git('--git-dir', str(moved), 'rev-parse', 'refs/heads/target').decode().strip()
        self.assertEqual(actual, material['prepared_new_oid'])
        moved.rename(self.remote)
        shutil.rmtree(self.repo)
        self.assertEqual(self.invoke('observe', material)['outcome'], 'present')
        self.assertEqual(self.effect_count(), 1)

    def test_symlink_and_executable_targets_refuse_without_effect(self):
        for target_mode in ('symlink', 'executable'):
            with self.subTest(target_mode=target_mode):
                path = self.repo / 'docs/policy.adoc'
                path.unlink()
                if target_mode == 'symlink':
                    path.symlink_to('../unrelated')
                else:
                    path.write_bytes(b'old policy\n')
                    path.chmod(0o755)
                self.git('-C', str(self.repo), 'add', '.')
                self.git('-C', str(self.repo), 'commit', '-qm', target_mode)
                self.git('-C', str(self.repo), 'push', '-q', str(self.remote), 'HEAD:refs/heads/target')
                current = self.head()
                self.assertEqual(self.invoke('prepare', instruction=dict(self.instruction, expected_old_oid=current))['outcome'], 'refused')
                self.assertEqual(self.head(), current)

    def test_empty_and_maximum_payload_round_trip(self):
        for payload in (b'', b'x' * 1048576):
            with self.subTest(length=len(payload)):
                self.private(self.payload, payload)
                instruction = dict(self.instruction, payload_digest=digest(payload))
                material = self.invoke('prepare', instruction=instruction)['material']
                self.assertEqual(self.invoke('apply', material, instruction)['outcome'], 'applied')
                self.assertEqual(self.git('--git-dir', str(self.remote), 'show', self.head()+':docs/policy.adoc'), payload)
                self.git('--git-dir', str(self.remote), 'update-ref', 'refs/heads/target', self.old,
                         material['prepared_new_oid'])
        self.private(self.payload, b'x' * 1048577)
        instruction = dict(self.instruction, payload_digest=digest(self.payload.read_bytes()))
        self.assertEqual(self.invoke('prepare', instruction=instruction)['outcome'], 'refused')


    def test_receiver_compare_and_swap_rejects_concurrent_ref_change(self):
        material = self.invoke('prepare')['material']
        (self.repo / 'unrelated').write_bytes(b'concurrent receiver winner\n')
        self.git('-C', str(self.repo), 'commit', '-qam', 'concurrent winner')
        winner = self.git('-C', str(self.repo), 'rev-parse', 'HEAD').decode().strip()
        self.git('-C', str(self.repo), 'push', '-q', str(self.remote), 'HEAD:refs/heads/competitor')
        hook = self.remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nunset GIT_QUARANTINE_PATH\ngit update-ref refs/heads/target '
                        + winner + ' ' + self.old + '\n')
        hook.chmod(0o700)
        result = self.invoke('apply', material)
        self.assertNotEqual(result['outcome'], 'applied')
        self.assertEqual(result['observed_oid'], winner)
        self.assertEqual(self.head(), winner)
        self.assertEqual(self.git('--git-dir', str(self.remote), 'show', winner+':docs/policy.adoc'), b'old policy\n')
        self.assertEqual(self.effect_count(), 1)


    def test_larger_old_source_streams_to_bounded_replacement(self):
        old = b'large old source\n' * 131072
        self.assertGreater(len(old), 1048576)
        (self.repo / 'docs/policy.adoc').write_bytes(old)
        self.git('-C', str(self.repo), 'commit', '-qam', 'large source')
        self.git('-C', str(self.repo), 'push', '-q', str(self.remote), 'HEAD:refs/heads/target')
        instruction = dict(self.instruction, expected_old_oid=self.head(), expected_source_digest=digest(old))
        material = self.invoke('prepare', instruction=instruction)['material']
        self.assertEqual(self.invoke('apply', material, instruction)['outcome'], 'applied')
        self.assertEqual(self.git('--git-dir', str(self.remote), 'show', self.head()+':docs/policy.adoc'), self.payload.read_bytes())


if __name__ == '__main__':
    unittest.main()
