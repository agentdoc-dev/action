"""Content-free notices through real uploaders and the existing HTTPS recorder."""
import base64
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid
from urllib.parse import parse_qs, urlsplit

from https_recorder import HttpsRecorder
from test_cloud_egress import (ROOT, EGRESS_TOKEN, result_fixture, policy_document,
                               policy_response as result_policy, CANARY,
                               WORKSPACE as RESULT_WORKSPACE, REPOSITORY as RESULT_REPOSITORY)
from test_cloud_assessment_egress import (
    WORKSPACE, REPOSITORY, CANARIES, fixture, policy_response, response_for_upload,
)


class EgressStatusTests(unittest.TestCase):
    def run_sender(self, sender, *, audit=True, notice_status=202, attempts=1,
                   followup=None, mutate=None, initial=None, expected_code="egress.category_disabled"):
        selected = [None]
        gets = []
        paths = {}
        def respond(row):
            if selected[0] is None:
                return policy_response() if row['method'] == 'GET' else response_for_upload(row, paths)
            if row['method'] == 'GET':
                gets.append(row)
                if len(gets) % 2 == 0 and followup is not None:
                    return followup
                return selected[0]
            self.assertTrue(row['path'].endswith('/egress-status'), 'forbidden payload POST')
            return notice_status, {'Location': '/must-not-follow'}, b'SQL_CONTENT_CANARY'
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            with HttpsRecorder(directory, respond) as recorder:
                if sender == 'result':
                    command, env = result_fixture(directory, recorder.origin, recorder.ca_file)
                    env['CLOUD_VERIFIER_ID'] = '50000000-0000-0000-0000-000000000401'
                    status_path = directory / 'private/cloud-sync-status.json'
                    policy = policy_document()
                    policy['payload']['categories'].update(raw_source=False, audit_metadata=audit)
                    chosen = result_policy(policy)
                else:
                    env, paths = fixture(directory, recorder.origin, recorder.ca_file)
                    command = [str(ROOT / f'scripts/upload-cloud-{sender}.sh'), '/usr/bin/curl']
                    status_path = directory / f'private/cloud-{sender}-status.json'
                    if sender == 'proposal':
                        subprocess.run([str(ROOT / 'scripts/upload-cloud-assessment.sh'), '/usr/bin/curl'],
                                       env=env, check=True, capture_output=True, timeout=90)
                        self.assertEqual(json.loads((directory / 'private/cloud-assessment-status.json').read_bytes())['status'], 'completed')
                        env['GITHUB_EVENT_NAME'] = 'workflow_run'
                    chosen = policy_response(('raw_source',) if audit else ('raw_source', 'audit_metadata'))
                if mutate:
                    mutate(env)
                selected[0] = initial if initial is not None else chosen
                offset = len(recorder.records())
                originals = {path: path.read_bytes() for path in directory.rglob('*.json')
                             if path != recorder.ledger and 'status' not in path.name}
                statuses = []
                for _ in range(attempts):
                    result = subprocess.run(command, env=env, capture_output=True, timeout=90)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    for secret in [CANARY, *CANARIES.values(), 'SQL_CONTENT_CANARY', EGRESS_TOKEN,
                                   env.get('CLOUD_UPLOAD_TOKEN', ''), env.get('CLOUD_ASSESSMENT_TOKEN', ''),
                                   env.get('CLOUD_PROPOSAL_TOKEN', '')]:
                        if secret:
                            self.assertNotIn(secret.encode(), result.stdout + result.stderr)
                    statuses.append(json.loads(status_path.read_bytes()))
                for path, original in originals.items():
                    self.assertEqual(path.read_bytes(), original)
                rows = recorder.records()[offset:]
                for status in statuses:
                    self.assertEqual(status['status'], 'skipped' if expected_code == 'egress.category_disabled' else 'failed')
                    self.assertEqual(status['reason_code' if sender == 'result' else 'code'], expected_code)
                for row in rows:
                    visible = row['path'].encode() + base64.b64decode(row['body_base64'])
                    for canary in [CANARY, *CANARIES.values()]:
                        self.assertNotIn(canary.encode(), visible)
                return rows, statuses, env

    def test_proposal_and_result_send_exact_closed_notices_with_own_write_credentials(self):
        for sender, operation, credential in (
            ('proposal', 'proposal_command', 'CLOUD_PROPOSAL_TOKEN'),
            ('result', 'external_work.result_submit', 'CLOUD_UPLOAD_TOKEN'),
        ):
            with self.subTest(sender=sender):
                rows, _, env = self.run_sender(sender)
                self.assertEqual([row['method'] for row in rows], ['GET', 'GET', 'POST'])
                workspace = RESULT_WORKSPACE if sender == 'result' else WORKSPACE
                repository = RESULT_REPOSITORY if sender == 'result' else REPOSITORY
                upload_url = env['CLOUD_UPLOAD_URL' if sender == 'result' else 'CLOUD_PROPOSAL_URL']
                origin = 'https://' + urlsplit(upload_url).netloc
                body = {
                    'notice_id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'agentdoc:egress-status:' + json.dumps(
                        [origin, workspace, repository, operation, env['ADOC_INVOCATION_ID']],
                        separators=(',', ':')))),
                    'operation': operation, 'repository_id': repository, 'code': 'egress.category_disabled',
                }
                if sender == 'result':
                    body['verifier_id'] = env['CLOUD_VERIFIER_ID']
                self.assertEqual(rows[-1]['path'], f'/api/v1/workspaces/{workspace}/egress-status')
                self.assertEqual(base64.b64decode(rows[-1]['body_base64']),
                                 json.dumps(body, sort_keys=True, separators=(',', ':')).encode())
                for row in rows[:2]:
                    url = urlsplit(row['path'])
                    self.assertEqual(url.path, f'/api/v1/workspaces/{workspace}/egress-policies')
                    self.assertEqual(parse_qs(url.query), {
                        'repository_id': [repository], 'source_provider': ['github'],
                        'external_repository_id': ['42' if sender == 'result' else '99'],
                    })
                    self.assertEqual(dict((k.lower(), v) for k, v in row['headers'])['authorization'],
                                     'Bearer ' + EGRESS_TOKEN)
                headers = dict((k.lower(), v) for k, v in rows[-1]['headers'])
                self.assertEqual(headers['authorization'], 'Bearer ' + env[credential])
                self.assertEqual(headers['content-type'], 'application/json')
                self.assertNotIn('idempotency-key', headers)

    def test_audit_disabled_never_posts_for_any_sender_or_retry(self):
        for sender in ('assessment', 'proposal', 'result'):
            with self.subTest(sender=sender):
                rows, statuses, _ = self.run_sender(sender, audit=False, attempts=2)
                self.assertEqual([row['method'] for row in rows], ['GET'] * 4)
                self.assertEqual(statuses[0], statuses[1])

    def test_notice_refusals_preserve_skipped_status_and_stable_retry_identity(self):
        for sender in ('assessment', 'proposal', 'result'):
            for response in (401, 403, 429, 503, 302):
                with self.subTest(sender=sender, response=response):
                    rows, statuses, _ = self.run_sender(sender, notice_status=response, attempts=2)
                    self.assertEqual([row['method'] for row in rows], ['GET', 'GET', 'POST'] * 2)
                    self.assertEqual(rows[2]['path'], rows[5]['path'])
                    self.assertEqual(rows[2]['body_base64'], rows[5]['body_base64'])
                    self.assertEqual(statuses[0], statuses[1])

    def test_audit_permission_is_fetched_again_and_failures_never_post(self):
        for sender in ('assessment', 'proposal', 'result'):
            for followup in ((401, {}, b'{}'), (403, {}, b'{}'), (503, {}, b'{}'),
                             (200, {}, b'{}'), (200, {'x-agentdoc-egress-policy-digest': 'sha256:' + '0' * 64}, b'{}')):
                with self.subTest(sender=sender, followup=followup):
                    rows, _, _ = self.run_sender(sender, followup=followup)
                    self.assertEqual([row['method'] for row in rows], ['GET', 'GET'])

    def test_initial_missing_or_malformed_policy_never_invokes_notice(self):
        for sender in ('assessment', 'proposal', 'result'):
            for response, code in (((503, {}, b'{}'), 'egress.policy_unavailable'),
                                   ((200, {}, b'{'), 'egress.policy_unavailable'),
                                   ((401, {}, b'{}'), 'api.unauthenticated'),
                                   ((403, {}, b'{}'), 'workspace.cross_tenant_denied')):
                with self.subTest(sender=sender, response=response):
                    rows, _, _ = self.run_sender(sender, initial=response, expected_code=code)
                    self.assertEqual([row['method'] for row in rows], ['GET'])

    def test_read_token_never_authorizes_notice_and_external_selector_is_optional(self):
        for sender, credential in (('assessment', 'CLOUD_ASSESSMENT_TOKEN'),
                                   ('proposal', 'CLOUD_PROPOSAL_TOKEN'), ('result', 'CLOUD_UPLOAD_TOKEN')):
            with self.subTest(sender=sender):
                rows, _, _ = self.run_sender(sender, mutate=lambda env: env.update({credential: EGRESS_TOKEN}))
                self.assertEqual([row['method'] for row in rows], ['GET'])
        for selector in ('', 'bad-verifier', '50000000-0000-0000-0000-00000000040A'):
            rows, _, _ = self.run_sender('result', mutate=lambda env: env.update(CLOUD_VERIFIER_ID=selector))
            self.assertEqual([row['method'] for row in rows], ['GET'])

    def test_composites_forward_only_existing_write_tokens_and_optional_verifier_selector(self):
        root = (ROOT / 'action.yml').read_text()
        self.assertIn('  cloud-verifier-id:', root)
        self.assertIn('CLOUD_VERIFIER_ID: ${{ inputs.cloud-verifier-id }}', root)
        self.assertIn('CLOUD_VERIFIER_ID="$CLOUD_VERIFIER_ID"', root)
        for source, token in ((root, 'CLOUD_UPLOAD_TOKEN'),
                              ((ROOT / 'cloud-assessment/action.yml').read_text(), 'CLOUD_ASSESSMENT_TOKEN'),
                              ((ROOT / 'cloud-assessment/action.yml').read_text(), 'CLOUD_PROPOSAL_TOKEN')):
            self.assertIn(f'{token}="${token}"', source)
            self.assertIn('CLOUD_EGRESS_TOKEN="$CLOUD_EGRESS_TOKEN"', source)
            self.assertIn('ADOC_INVOCATION_ID="$ADOC_INVOCATION_ID"', source)

    def test_assessment_disabled_payload_sends_only_exact_notice_with_write_token(self):
        paths = {}
        def respond(row):
            if row['method'] == 'GET':
                return policy_response(('raw_source',))
            return 202, {}, b'{}'
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            with HttpsRecorder(directory, respond) as recorder:
                env, paths = fixture(directory, recorder.origin, recorder.ca_file)
                result = subprocess.run([str(ROOT / 'scripts/upload-cloud-assessment.sh'), '/usr/bin/curl'],
                                        env=env, capture_output=True, timeout=90)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                status = json.loads((directory / 'private/cloud-assessment-status.json').read_bytes())
                self.assertEqual((status['status'], status['code']), ('skipped', 'egress.category_disabled'))
                rows = recorder.records()
                self.assertEqual([row['method'] for row in rows], ['GET', 'GET', 'POST'])
                expected = {
                    'notice_id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'agentdoc:egress-status:' + json.dumps(
                        [recorder.origin, WORKSPACE, REPOSITORY, 'assessment_submission', env['ADOC_INVOCATION_ID']],
                        separators=(',', ':')))),
                    'operation': 'assessment_submission', 'repository_id': REPOSITORY,
                    'code': 'egress.category_disabled',
                }
                self.assertEqual(rows[-1]['path'], f'/api/v1/workspaces/{WORKSPACE}/egress-status')
                self.assertEqual(base64.b64decode(rows[-1]['body_base64']),
                                 json.dumps(expected, sort_keys=True, separators=(',', ':')).encode())
                for row in rows[:2]:
                    self.assertEqual(parse_qs(urlsplit(row['path']).query), {
                        'repository_id': [REPOSITORY], 'source_provider': ['github'],
                        'external_repository_id': ['99'],
                    })
                    self.assertEqual(dict((k.lower(), v) for k, v in row['headers'])['authorization'],
                                     'Bearer ' + EGRESS_TOKEN)
                self.assertEqual(dict((k.lower(), v) for k, v in rows[-1]['headers'])['authorization'],
                                 'Bearer ' + env['CLOUD_ASSESSMENT_TOKEN'])
                for canary in CANARIES.values():
                    self.assertNotIn(canary.encode(), base64.b64decode(rows[-1]['body_base64']))
                    self.assertNotIn(canary.encode(), result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
