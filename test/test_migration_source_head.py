"""Read-only explicit source heads against actual private Git receivers."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch

import test_writeback_git as writeback

ROOT, PROGRAM = writeback.ROOT, writeback.PROGRAM

spec = importlib.util.spec_from_file_location('writeback_git', ROOT / 'scripts/writeback-git.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class SourceHeadTests(unittest.TestCase):
    setUp = writeback.WritebackGitTests.setUp
    git = writeback.WritebackGitTests.git
    private = writeback.WritebackGitTests.private
    effect_count = writeback.WritebackGitTests.effect_count

    def instruction_head(self):
        return {'format_version': 1, 'observation_id': '30000000-0000-0000-0000-000000000001',
                'target_digest': 'sha256:' + 'b' * 64, 'remote': str(self.remote),
                'ref': 'refs/heads/target'}

    def invoke_head(self, instruction=None, raw=None, mutate=None, succeeds=True, env=None):
        self.calls += 1
        source = self.directory / f'head-{self.calls}.json'
        output = self.directory / f'head-output-{self.calls}.json'
        self.private(source, raw if raw is not None else json.dumps(
            self.instruction_head() if instruction is None else instruction).encode())
        if mutate:
            mutate(source, output)
        result = subprocess.run([str(PROGRAM), 'head', str(source), str(output)],
                                env=env or self.env, capture_output=True, timeout=35)
        self.assertEqual(result.stdout, b'')
        self.assertEqual(result.stderr, b'')
        if not succeeds:
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            return
        self.assertEqual(result.returncode, 0)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertLessEqual(output.stat().st_size, 1024)
        return json.loads(output.read_bytes())

    def expected(self, oid=None, instruction=None):
        value = self.instruction_head() if instruction is None else instruction
        result = {k: value[k] for k in ('format_version', 'observation_id', 'target_digest', 'ref')}
        result['outcome'] = 'observed' if oid else 'unavailable'
        if oid:
            result['observed_oid'] = oid
        return result

    def test_real_receiver_writer_while_checkout_stays_unchanged(self):
        self.payload.unlink()  # The read has no payload dependency.
        self.assertEqual(self.invoke_head(), self.expected(self.old))
        writer = self.directory / 'writer'
        self.git('clone', '-q', str(self.remote), str(writer))
        self.git('-C', str(writer), 'config', 'user.name', 'Writer')
        self.git('-C', str(writer), 'config', 'user.email', 'writer@example.invalid')
        errors = []
        def advance():
            try:
                (writer / 'unrelated').write_text('concurrent source change\n')
                self.git('-C', str(writer), 'commit', '-qam', 'concurrent source change')
                self.git('-C', str(writer), 'push', '-q', 'origin', 'HEAD:refs/heads/target')
            except Exception as error:
                errors.append(error)
        thread = threading.Thread(target=advance)
        thread.start()
        during = self.invoke_head()
        thread.join()
        self.assertEqual(errors, [])
        new = self.git('-C', str(writer), 'rev-parse', 'HEAD').decode().strip()
        self.assertIn(during['observed_oid'], (self.old, new))
        self.assertEqual(self.invoke_head(), self.expected(new))
        self.assertEqual(self.git('-C', str(self.repo), 'rev-parse', 'HEAD').decode().strip(), self.old)
        self.assertEqual((self.repo / 'unrelated').read_bytes(), b'unchanged\n')
        self.assertEqual(self.effect_count(), 1, 'only the separate writer changes the receiver')
        self.git('--git-dir', str(self.remote), 'update-ref', 'refs/heads/target', self.old, new)
        self.assertEqual(self.invoke_head(), self.expected(self.old))
        self.git('--git-dir', str(self.remote), 'update-ref', '-d', 'refs/heads/target')
        self.assertEqual(self.invoke_head(), self.expected())
        self.assertFalse(list(self.directory.glob('source-head-*')))

    def test_unbound_targets_and_setup_have_no_receipt(self):
        link = self.directory / 'linked.git'
        link.symlink_to(self.remote)
        empty = self.directory / 'not-a-repository'
        empty.mkdir()
        values = ['--upload-pack=evil', 'HEAD', 'remote.git', str(link), str(self.directory),
                  str(self.directory / '..'), str(self.repo), str(empty), str(self.directory / 'absent.git'),
                  'file://' + str(self.remote),
                  'https://token@github.com/owner/repo.git', 'ssh://github.com/owner/repo.git',
                  'https://github.com/owner/repo.git?query=1']
        for remote in values:
            with self.subTest(remote=remote):
                instruction = dict(self.instruction_head(), remote=remote)
                self.invoke_head(instruction, succeeds=False)
        self.invoke_head(dict(self.instruction_head(), remote='https://github.com/owner/repo.git'),
                         succeeds=False)
        missing_root = dict(self.env)
        del missing_root['WRITEBACK_LOCAL_ROOT']
        self.invoke_head(env=missing_root, succeeds=False)
        self.directory.chmod(0o755)
        try:
            self.invoke_head(succeeds=False)
        finally:
            self.directory.chmod(0o700)
        for ref in ('HEAD', 'target', '--heads', 'refs/tags/target', 'refs/heads/../target',
                    'refs/heads/a b', 'refs/heads/a\n', 'refs/heads/' + 'a' * 201):
            with self.subTest(ref=ref):
                instruction = dict(self.instruction_head(), ref=ref)
                self.invoke_head(instruction, succeeds=False)
        self.assertEqual(self.effect_count(), 0)

    def test_unbound_or_unprotected_input_has_no_receipt(self):
        for value in ({}, [], dict(self.instruction_head(), format_version=True),
                      dict(self.instruction_head(), observation_id='wrong'),
                      dict(self.instruction_head(), target_digest='a' * 64),
                      dict(self.instruction_head(), extra='no')):
            with self.subTest(value=value):
                self.invoke_head(value, succeeds=False)
        for raw in (b'{', b' ' * 16385, b'[' * 2000,
                    b'{"format_version":1,"format_version":1}'):
            self.invoke_head(raw=raw, succeeds=False)
        self.invoke_head(mutate=lambda source, output: source.chmod(0o644), succeeds=False)
        self.invoke_head(mutate=lambda source, output: source.unlink(), succeeds=False)
        def symlink(source, output):
            other = source.with_suffix('.original')
            source.rename(other)
            source.symlink_to(other)
        self.invoke_head(mutate=symlink, succeeds=False)

    def test_private_output_cannot_replace_or_follow_links(self):
        source = self.directory / 'head-input.json'
        self.private(source, json.dumps(self.instruction_head()).encode())
        existing = self.directory / 'existing-output.json'
        self.private(existing, b'preserved')
        link = self.directory / 'output-link.json'
        link.symlink_to(existing)
        absent = self.directory / 'absent-output.json'
        dangling = self.directory / 'dangling-output.json'
        dangling.symlink_to(absent)
        for output in (existing, link, dangling):
            result = subprocess.run([str(PROGRAM), 'head', str(source), str(output)],
                                    env=self.env, capture_output=True, timeout=35)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout + result.stderr, b'')
            self.assertEqual(existing.read_bytes(), b'preserved')
            self.assertFalse(absent.exists())
        self.assertTrue(link.is_symlink() and dangling.is_symlink())

    def test_head_rows_are_exact_and_single(self):
        git = object.__new__(helper.Git)
        target = self.instruction_head()
        for raw in (b'', b'not a row\n', (self.old + '\trefs/heads/other\n').encode(),
                    (self.old + '\trefs/heads/target\n') .encode() * 2,
                    ('0' * 40 + '\trefs/heads/target\n').encode(), b'\xff'):
            with self.subTest(raw=raw), patch.object(git, 'command', return_value=
                    subprocess.CompletedProcess([], 0, stdout=raw)):
                with self.assertRaises((helper.Refusal, ValueError)):
                    git.head(target)

    def test_head_hard_output_limit_and_deadline(self):
        git = object.__new__(helper.Git)
        git.repo = self.directory / 'unused'
        git.env = self.env
        real_popen = subprocess.Popen
        processes = []
        def fixture_process(*args, **kwargs):
            process = real_popen([sys.executable, '-c', program], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, start_new_session=True)
            processes.append(process)
            return process
        for program in ('import os; os.write(1, b"x" * 65536)', 'import time; time.sleep(60)'):
            with self.subTest(program=program), patch.object(helper.subprocess, 'Popen', fixture_process):
                if 'sleep' in program:
                    with patch.object(helper.select, 'select', return_value=([], [], [])):
                        with self.assertRaises(helper.Refusal):
                            git.head(self.instruction_head())
                else:
                    with self.assertRaises(helper.Refusal):
                        git.head(self.instruction_head())
            self.assertIsNotNone(processes[-1].poll())
            self.assertTrue(processes[-1].stdout.closed)


if __name__ == '__main__':
    unittest.main()
