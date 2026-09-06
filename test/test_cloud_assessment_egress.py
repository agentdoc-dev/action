"""Real uploader category-union tests: python3 -B test/test_cloud_assessment_egress.py -v."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

from https_recorder import HttpsRecorder
from test_cloud_egress import ROOT, EGRESS_TOKEN, CATEGORIES, digest, raw_policy_response

WORKSPACE = '10000000-0000-0000-0000-000000000801'
REPOSITORY = '60000000-0000-0000-0000-000000000801'
INVOCATION = 'inv_801_2_agentdoc_0123456789abcdef0123456789abcdef'
DETERMINISTIC = ('audit_metadata', 'compiled_objects', 'source_excerpts')
SEMANTIC = DETERMINISTIC + ('pr_diffs', 'semantic_assessments')
CANARIES = {category: 'E66_CANARY_' + category.upper() for category in CATEGORIES}


def policy_response(disabled=()):
    return raw_policy_response(json.dumps({
        'schema_version': 'agentdoc.cloud.egress_policy.v0',
        'payload': {'scope': {'workspace_id': WORKSPACE,
                             'resource': {'kind': 'repository', 'id': REPOSITORY}},
                    'categories': {key: key not in disabled for key in CATEGORIES}},
    }, indent=2).encode())


def fixture(directory, origin, ca_file, bundle=True):
    retained = directory / 'outputs'
    run = directory / 'private'
    retained.mkdir(); run.mkdir()
    env = {
        'PATH': os.environ['PATH'], 'CASE_DIR': str(directory),
        'ADOC_RUN_DIR': str(run), 'ADOC_RETAINED_DIR': str(retained),
        'ADOC_INVOCATION_ID': INVOCATION, 'ADOC_REQUESTED_BASE': 'a' * 40,
        'ADOC_HEAD': 'b' * 40, 'ADOC_PR_NUMBER': '801', 'ADOC_PROPOSE_ELIGIBLE': 'true',
        'ADOC_ISOLATED_ASSESSMENT': 'true', 'GITHUB_EVENT_NAME': 'pull_request',
        'GITHUB_REPOSITORY': 'agentdoc/test', 'GITHUB_RUN_ID': '202',
        'GITHUB_RUN_ATTEMPT': '3', 'GITHUB_JOB': 'cloud_ingest',
        'GITHUB_ACTOR': CANARIES['audit_metadata'], 'GITHUB_ACTOR_ID': '42',
        'GITHUB_TRIGGERING_ACTOR': 'alice',
        'GITHUB_WORKFLOW_REF': 'agentdoc/test/.github/workflows/cloud-ingestion.yml@refs/heads/main',
        'GITHUB_WORKFLOW_SHA': '7' * 40,
        'CLOUD_ASSESSMENT_URL': origin + f'/api/v1/workspaces/{WORKSPACE}/assessment-submissions',
        'CLOUD_ASSESSMENT_REPOSITORY_ID': REPOSITORY,
        'CLOUD_ASSESSMENT_TOKEN': 'synthetic-assessment-upload-token-801',
        'CLOUD_PROPOSAL_URL': origin + f'/api/v1/workspaces/{WORKSPACE}/proposal-commands',
        'CLOUD_PROPOSAL_TOKEN': 'synthetic-proposal-upload-token-801',
        'CLOUD_EGRESS_TOKEN': EGRESS_TOKEN, 'CURL_CA_BUNDLE': str(ca_file), 'NO_PROXY': '*',
    }
    # Deliberately no GITHUB_REPOSITORY_ID: the protected receipt owns source binding.
    subprocess.run(['bash', str(ROOT / 'test/assessment-fixture.sh')], env=env,
                   check=True, capture_output=True, timeout=15)
    paths = {name: retained / f'{name}-{INVOCATION}.json' for name in (
        'assessment', 'receipt', 'knowledge-graph', 'semantic-context',
        'semantic-assessment', 'semantic-executor', 'semantic-executor-request', 'proposal-record')}
    def read(name):
        return json.loads(paths[name].read_bytes())
    def write(name, value):
        paths[name].write_text(json.dumps(value, separators=(',', ':')) + '\n')
        return digest(paths[name].read_bytes())
    graph = read('knowledge-graph')
    graph['nodes'] = [{'type': 'knowledge_object', 'id': 'internal.synthetic.claim',
                      'body': CANARIES['compiled_objects'], 'source_span': {'path': 'docs/internal.adoc', 'line': 1, 'column': 1}}]
    graph_digest = write('knowledge-graph', graph)
    assessment = read('assessment')
    assessment['knowledge_snapshot']['graph_sha256'] = graph_digest
    assessment['objects'] = {'status': 'available', 'value': [{'id': 'internal.synthetic.claim',
                              'kind': 'claim', 'owner': CANARIES['compiled_objects']}]}
    assessment['diagnostics'] = [{'code': 'schema.test', 'severity': 'warning',
                                 'message': 'Invalid authored value: ' + CANARIES['source_excerpts']}]
    assessment_digest = write('assessment', assessment)
    context = read('semantic-context')
    context['basis']['assessment_digest'] = assessment_digest
    context['basis']['knowledge_basis']['digest'] = graph_digest
    context['items'][0]['content'] = {'diff': '+ ' + CANARIES['pr_diffs']}
    context['items'].append({'handle_id': 'object-1', 'handle': {'kind': 'knowledge_object', 'object_id': 'internal.synthetic.claim'},
                             'content': {'body': CANARIES['compiled_objects'] + ' ' + CANARIES['source_excerpts']}})
    write('semantic-context', context)
    semantic = read('semantic-assessment')
    semantic['findings'][0]['explanation'] = CANARIES['semantic_assessments']
    semantic_digest = write('semantic-assessment', semantic)
    request = read('semantic-executor-request')
    request['context'] = context
    request_digest = write('semantic-executor-request', request)
    executor = read('semantic-executor')
    executor.update(request_digest=request_digest, assessment_digest=semantic_digest)
    executor_digest = write('semantic-executor', executor)
    receipt = read('receipt')
    receipt['assessment']['sha256'] = assessment_digest
    receipt['knowledge_snapshot']['graph_sha256'] = graph_digest
    receipt['semantic_assessment']['assessment_sha256'] = semantic_digest
    receipt['ci']['actor'] = CANARIES['audit_metadata']
    proposal = read('proposal-record')
    proposal['bindings'].update(assessment_digest=assessment_digest, semantic_assessment_digest=semantic_digest)
    patch = proposal['patches'][0]['patch']
    patch['changes']['body'] = '\n'.join(CANARIES[key] for key in SEMANTIC if key != 'audit_metadata')
    patch['proposer']['id'] = CANARIES['audit_metadata']
    patch['reason'] = 'AgentDoc assessment ' + assessment_digest + ' finding finding-001.'
    patch_bytes = subprocess.run(['jq', '-cS', '.'], input=json.dumps(patch).encode(),
                                check=True, capture_output=True).stdout
    proposal['patches'][0]['patch_digest'] = digest(patch_bytes)
    proposal['proposal_set_digest'] = digest((json.dumps([digest(patch_bytes)], separators=(',', ':')) + '\n').encode())
    proposal_digest = write('proposal-record', proposal)
    receipt['proposals']['sha256'] = proposal['proposal_set_digest']
    receipt_digest = write('receipt', receipt)
    (run / 'assessment-path').write_text(str(paths['assessment']) + '\n')
    for name, value in [('assessment-sha256', assessment_digest), ('receipt-sha256', receipt_digest),
                        ('proposal-record-sha256', proposal_digest)]:
        (run / name).write_text(value + '\n')
    if bundle:
        (run / 'semantic-executor-receipt-sha256').write_text(executor_digest + '\n')
        (run / 'semantic-executor-request-digest').write_text(request_digest + '\n')
    else:
        for name in ('knowledge-graph', 'semantic-context', 'semantic-assessment', 'semantic-executor', 'semantic-executor-request'):
            paths[name].unlink()
    for category in ('raw_source', 'embeddings'):
        paths[category] = retained / (category + '-not-selected.txt')
        paths[category].write_text(CANARIES[category])
    return env, paths


def response_for_upload(row, paths):
    payload = json.loads(base64.b64decode(row['body_base64']))['payload']
    result = {'disposition': 'accepted', 'code': None, 'complete': True,
              'original_request_id': '40000000-0000-0000-0000-000000000801',
              'request_id': '40000000-0000-0000-0000-000000000802', 'replayed': False}
    if row['path'].endswith('/proposal-commands'):
        result.update(proposal_record_id='70000000-0000-0000-0000-000000000801',
                      proposal_version_id='71000000-0000-0000-0000-000000000801',
                      proposal_set_digest=payload['proposal_set_digest'], supersedes=None,
                      record_digest=digest(paths['proposal-record'].read_bytes()))
    else:
        result.update(ingestion_id='70000000-0000-0000-0000-000000000801',
                      assessment_digest=payload['assessment']['digest'], receipt_digest=payload['receipt']['digest'])
    return 202, {}, json.dumps({'schema_version': 'agentdoc.cloud.ingestion_result.v0', 'payload': result}).encode()


def decoded_bytes(row):
    """Inspect JSON strings and nested base64 transport copies, retaining raw bytes too."""
    def visit(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key == 'bytes_base64' and isinstance(child, str):
                    yield from decode(base64.b64decode(child, validate=True))
                else:
                    yield from visit(child)
        elif isinstance(value, list):
            for child in value:
                yield from visit(child)
        elif isinstance(value, str):
            yield value.encode()
    def decode(body):
        yield body
        try:
            value = json.loads(body)
        except (ValueError, UnicodeDecodeError):
            return
        yield from visit(value)
    return b'\n'.join([row['path'].encode(), json.dumps(row['headers']).encode(),
                       *decode(base64.b64decode(row['body_base64']))])


class AssessmentEgressTests(unittest.TestCase):
    def run_sender(self, sender, policies, *, attempts=1, bundle=True, mutate=None):
        selected = [policy_response()]
        gets = []
        paths = {}
        def respond(row):
            if row['method'] == 'GET':
                gets.append(row)
                return selected[0][min(len(gets)-1, len(selected[0])-1)]
            if row['path'].endswith('/egress-status'):
                return 202, {}, b'{}'
            return response_for_upload(row, paths)
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            with HttpsRecorder(directory, respond) as recorder:
                env, paths = fixture(directory, recorder.origin, recorder.ca_file, bundle)
                def invoke(kind):
                    command = [str(ROOT / f'scripts/upload-cloud-{kind}.sh'), '/usr/bin/curl']
                    result = subprocess.run(command, env=env, capture_output=True, timeout=45)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    return json.loads((directory / f'private/cloud-{kind}-status.json').read_text())
                if sender == 'proposal':
                    selected[0] = [policy_response()]
                    self.assertEqual(invoke('assessment')['status'], 'completed')
                    env['GITHUB_EVENT_NAME'] = 'workflow_run'
                offset = len(recorder.records()); gets.clear(); selected[0] = policies
                if mutate:
                    mutate(env, paths, directory)
                originals = {path: path.read_bytes() for path in paths.values() if path.exists()}
                statuses = [invoke(sender) for _ in range(attempts)]
                self.assertEqual({path: path.read_bytes() for path in originals}, originals)
                return recorder.records()[offset:], statuses

    def assert_gets(self, rows, count):
        gets = [row for row in rows if row['method'] == 'GET']
        self.assertEqual(len(gets), count)
        for row in gets:
            url = urlsplit(row['path'])
            self.assertEqual(url.path, f'/api/v1/workspaces/{WORKSPACE}/egress-policies')
            self.assertEqual(parse_qs(url.query), {'repository_id': [REPOSITORY],
                            'source_provider': ['github'], 'external_repository_id': ['99']})
            self.assertEqual(base64.b64decode(row['body_base64']), b'')
            self.assertEqual(dict((k.lower(), v) for k, v in row['headers'])['authorization'], 'Bearer ' + EGRESS_TOKEN)

    def assert_suppressed(self, rows, statuses, category):
        for row in rows:
            self.assertFalse(CANARIES[category].encode() in decoded_bytes(row),
                             f'{category} escaped in request {row["sequence"]}, including embedded copies')
        # Only the new closed, content-free notice may replace the suppressed payload.
        notices = [row for row in rows if row['method'] != 'GET']
        self.assertEqual(len(notices), 0 if category == 'audit_metadata' else len(statuses))
        for row in notices:
            self.assertEqual(row['method'], 'POST')
            self.assertEqual(row['path'], f'/api/v1/workspaces/{WORKSPACE}/egress-status')
            body = json.loads(base64.b64decode(row['body_base64']))
            self.assertEqual(set(body), {'notice_id', 'operation', 'repository_id', 'code'})
            self.assertEqual(body['repository_id'], REPOSITORY)
            self.assertEqual(body['code'], 'egress.category_disabled')
            self.assertIn(body['operation'], ('assessment_submission', 'proposal_command'))
            for canary in CANARIES.values():
                self.assertNotIn(canary.encode(), decoded_bytes(row))
        for status in statuses:
            self.assertNotEqual(status['status'], 'completed')
            self.assertEqual(status['code'], 'egress.category_disabled')

    def test_disabled_audit_suppresses_actual_assessment_and_proposal(self):
        for sender in ('assessment', 'proposal'):
            with self.subTest(sender=sender):
                rows, statuses = self.run_sender(sender, [policy_response(('audit_metadata',))], bundle=False if sender == 'assessment' else True)
                self.assert_suppressed(rows, statuses, 'audit_metadata')
                self.assert_gets(rows, 2)

    def test_each_category_suppresses_unknown_origin_request_and_retry(self):
        for sender, bundle in (('assessment', False), ('assessment', True), ('proposal', True)):
            for category in CATEGORIES:
                with self.subTest(sender=sender, bundle=bundle, category=category):
                    rows, statuses = self.run_sender(sender, [policy_response((category,))],
                                                     bundle=bundle, attempts=2)
                    self.assert_suppressed(rows, statuses, category)
                    self.assert_gets(rows, 4)

    def test_all_categories_allowed_preserves_exact_bytes_and_unselected_artifacts(self):
        baselines = json.loads((ROOT / 'test/fixture-cloud-assessment-upload-digests.json').read_text())
        for name, sender, bundle in (('deterministic', 'assessment', False),
                                 ('semantic', 'assessment', True), ('proposal', 'proposal', True)):
            required = DETERMINISTIC if name == 'deterministic' else SEMANTIC
            with self.subTest(sender=name):
                rows, statuses = self.run_sender(sender, [policy_response()],
                                                 bundle=bundle, attempts=2)
                self.assert_gets(rows, 2)
                self.assertEqual([row['method'] for row in rows], ['GET', 'POST', 'GET', 'POST'])
                bodies = [base64.b64decode(row['body_base64']) for row in rows if row['method'] == 'POST']
                self.assertEqual(bodies[0], bodies[1])
                self.assertEqual({'digest': digest(bodies[0]), 'bytes': len(bodies[0])}, baselines[name])
                for status in statuses:
                    self.assertEqual(status['status'], 'completed')
                for row in rows:
                    visible = decoded_bytes(row)
                    for category in ('raw_source', 'embeddings'):
                        self.assertFalse(CANARIES[category].encode() in visible)
                    if row['method'] == 'POST':
                        for category in required:
                            self.assertTrue(CANARIES[category].encode() in visible, category)
                if bundle and sender == 'assessment':
                    payload = json.loads(bodies[0])['payload']
                    context = json.loads(base64.b64decode(payload['evidence']['semantic_context']['bytes_base64']))
                    request = json.loads(base64.b64decode(payload['evidence']['semantic_executor_request']['bytes_base64']))
                    self.assertEqual(context, request['context'])
                    self.assertIn(CANARIES['pr_diffs'], context['items'][0]['content']['diff'])

    def test_retry_after_policy_revocation_never_reuses_allow(self):
        for sender in ('assessment', 'proposal'):
            with self.subTest(sender=sender):
                rows, statuses = self.run_sender(sender, [policy_response(), policy_response(('pr_diffs',))], attempts=2)
                self.assert_gets(rows, 3)
                self.assertEqual([row['method'] for row in rows], ['GET', 'POST', 'GET', 'GET', 'POST'])
                self.assert_suppressed(rows[2:], statuses[1:], 'pr_diffs')

    def test_proposal_refuses_other_origin_workspace_or_tampered_assessment_binding(self):
        def mutate_origin(env, paths, directory):
            env['CLOUD_PROPOSAL_URL'] = env['CLOUD_PROPOSAL_URL'].replace('127.0.0.1', 'localhost')
        def mutate_workspace(env, paths, directory):
            env['CLOUD_PROPOSAL_URL'] = env['CLOUD_PROPOSAL_URL'].replace(WORKSPACE, WORKSPACE[:-1] + '2')
        def mutate_digest(env, paths, directory):
            status = json.loads((directory / 'private/cloud-assessment-status.json').read_text())
            submission = Path(status['submission_path'])
            changed = json.loads(submission.read_bytes())
            changed['payload']['repository_id'] = REPOSITORY[:-1] + '2'
            submission.write_text(json.dumps(changed))  # Status digest deliberately stays original.
        for mutate in (mutate_origin, mutate_workspace, mutate_digest):
            with self.subTest(mutation=mutate.__name__):
                rows, statuses = self.run_sender('proposal', [policy_response()], mutate=mutate)
                self.assertEqual(rows, [], 'Refuse mismatched binding before any GET or POST')
                self.assertNotEqual(statuses[0]['status'], 'completed')


if __name__ == '__main__':
    unittest.main()
