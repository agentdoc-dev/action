"""Focused real-HTTPS egress tracer: python3 -B test/test_cloud_egress.py -v."""

import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid
from urllib.parse import parse_qs, urlsplit

from https_recorder import HttpsRecorder


ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = "10000000-0000-0000-0000-000000000401"
REPOSITORY = "30000000-0000-0000-0000-000000000401"
CANARY = "E66_AUDIT_METADATA_CANARY_401"
EGRESS_TOKEN = "synthetic-egress-policy-read-token-401"
CATEGORIES = (
    "raw_source", "source_excerpts", "pr_diffs", "compiled_objects",
    "embeddings", "semantic_assessments", "audit_metadata",
)


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def result_fixture(directory, origin, ca_file):
    """Same source_ci fixture as cloud-handoff.sh, with an audit subject canary."""
    run = directory / "private"
    retained = directory / "retained"
    run.mkdir()
    retained.mkdir()
    assessment = retained / "assessment.json"
    shutil.copyfile(ROOT / "test/fixture-assessment.json", assessment)
    (run / "assessment-path").write_text(str(assessment) + "\n")
    (run / "assessment-sha256").write_text(digest(assessment.read_bytes()) + "\n")
    request = {
        "schema_version": "adoc.work_request.v0",
        "request_id": "request-001", "nonce": "request-nonce-001",
        "workspace_id": WORKSPACE, "repository_id": REPOSITORY,
        "source": {"provider": "github", "external_repository_id": "42"},
        "revision": {"system": "git", "value": "a" * 40},
        "change_request": {"system": "github_pull_request", "id": "165"},
        "contracts": [{"schema_version": "adoc.work_result.v0"}],
        "capabilities": [{"name": "code_change_assessment", "version": "1"}],
        "expires_at": "2099-08-26T12:00:00Z",
        "workload": {
            "principal_id": "20000000-0000-0000-0000-000000000401",
            "subject": "repo:agentdoc-dev/adoc:environment:" + CANARY,
            "audience": "https://cloud.agentdoc.dev/work-results",
        },
    }
    canonical = json.dumps(request, sort_keys=True, separators=(",", ":")).encode()
    request["request_digest"] = digest(canonical)
    request_path = directory / "work-request.json"
    request_path.write_text(json.dumps(request))
    # Do not inherit developer credentials, proxy settings, or trusted-phase state.
    env = {
        "PATH": os.environ["PATH"],
        "ADOC_RUN_DIR": str(run), "ADOC_RETAINED_DIR": str(retained),
        "ADOC_INVOCATION_ID": "inv_401_1_external_0123456789abcdef0123456789abcdef",
        "ADOC_HEAD": "a" * 40, "ADOC_PR_NUMBER": "165",
        "GITHUB_REPOSITORY": "agentdoc-dev/adoc", "GITHUB_REPOSITORY_ID": "42",
        "ADOC_PROPOSE_ELIGIBLE": "true",
        "CLOUD_WORK_REQUEST": str(request_path),
        "CLOUD_UPLOAD_URL": origin + f"/api/workspaces/{WORKSPACE}/external-work-results",
        "CLOUD_UPLOAD_TOKEN": "synthetic-workspace-upload-token-401",
        "CLOUD_EGRESS_TOKEN": EGRESS_TOKEN,
        "CURL_CA_BUNDLE": str(ca_file), "NO_PROXY": "*",
    }
    return [str(ROOT / "scripts/upload-cloud-result.sh"), "/usr/bin/curl"], env


def policy_document(enabled=True):
    return {
        "schema_version": "agentdoc.cloud.egress_policy.v0",
        "payload": {
            "scope": {"workspace_id": WORKSPACE,
                      "resource": {"kind": "repository", "id": REPOSITORY}},
            "categories": dict.fromkeys(CATEGORIES, enabled),
        },
    }


def raw_policy_response(body):
    return 200, {"x-agentdoc-egress-policy-digest": digest(body), "Cache-Control": "no-store"}, body


def policy_response(policy=None):
    return raw_policy_response(json.dumps(policy if policy is not None else policy_document(), indent=2).encode())


def attempt_snapshots(directory):
    folder = directory / 'private/cloud-egress-attempts'
    snapshots = {}
    if folder.exists():
        assert folder.stat().st_mode & 0o777 == 0o700
        for path in folder.glob('*.json'):
            assert path.stat().st_mode & 0o777 == 0o600
            snapshots[path.stem] = json.loads(path.read_bytes())
        assert not list(folder.glob('*.headers')), 'raw receiving headers must be removed'
    return snapshots


def acknowledgment(row):
    headers = {k.lower(): v for k, v in row['headers']}
    return {key: headers[key] for key in ('x-request-id', 'x-agentdoc-egress-policy-digest') if key in headers}


class CloudEgressTests(unittest.TestCase):
    def test_actual_upload_carries_exact_checked_policy_and_attempt_identity(self):
        policy = policy_response()
        rows, statuses = self.run_result([policy], attempts=2)
        posts = [row for row in rows if row['method'] == 'POST']
        headers = [dict((k.lower(), v) for k, v in row['headers']) for row in posts]
        for header in headers:
            self.assertEqual(header.get('x-agentdoc-egress-policy-digest'), digest(policy[2]))
            self.assertRegex(header.get('x-request-id', ''),
                             r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
        self.assertNotEqual(headers[0]['x-request-id'], headers[1]['x-request-id'])
        self.assertEqual(posts[0]['body_base64'], posts[1]['body_base64'])
        self.assertEqual(statuses[0], statuses[1])

    def test_attempt_receipts_bind_fresh_policy_and_preserve_prior_retry(self):
        first = policy_response()
        second = raw_policy_response(json.dumps(policy_document(), separators=(',', ':')).encode())
        rows, statuses = self.run_result([first, second], attempts=2, ack=acknowledgment)
        posts = [row for row in rows if row['method'] == 'POST']
        self.assertNotEqual(digest(first[2]), digest(second[2]))
        for index, post in enumerate(posts):
            headers = acknowledgment(post)
            attempt = self.attempt_history[-1][headers['x-request-id']]
            self.assertEqual(str(uuid.UUID(attempt['request_id'])), attempt['request_id'])
            self.assertEqual(attempt['checked_policy_digest'], digest((first, second)[index][2]))
            self.assertEqual(attempt['body_digest'], digest(base64.b64decode(post['body_base64'])))
            self.assertEqual((attempt['transport'], attempt['receiving'], attempt['business_status']),
                             ('http_response', 'confirmed', 'completed'))
        self.assertEqual(len(self.attempt_history[0]), 1)
        self.assertEqual(len(self.attempt_history[1]), 2)
        self.assertEqual(posts[0]['body_base64'], posts[1]['body_base64'])
        self.assertEqual(statuses[0], statuses[1])

    def test_business_success_does_not_fabricate_receiving_acknowledgment(self):
        for ack in (None, lambda row: {'x-request-id': acknowledgment(row)['x-request-id']},
                    lambda row: {**acknowledgment(row), 'x-agentdoc-egress-policy-digest': 'sha256:' + '0' * 64},
                    lambda row: {**acknowledgment(row), 'x-request-id': str(uuid.uuid4())},
                    lambda row: {**acknowledgment(row), 'X-Request-ID': acknowledgment(row)['x-request-id']},
                    lambda row: {**acknowledgment(row), 'X-Padding': 'x' * 66000},
                    lambda row: {**acknowledgment(row), 'X-Folded': 'value\r\n continuation'}):
            with self.subTest(ack=ack):
                _, statuses = self.run_result([policy_response()], ack=ack)
                attempt = next(iter(self.attempt_history[-1].values()))
                self.assertEqual(attempt['receiving'], 'unconfirmed')
                self.assertEqual(statuses[0]['status'], 'completed')

    def test_lost_response_retains_unconfirmed_attempt_and_exact_retry(self):
        rows, statuses = self.run_result([policy_response()], attempts=2,
                                        post_statuses=(None, 201), ack=acknowledgment)
        posts = [row for row in rows if row['method'] == 'POST']
        first = self.attempt_history[-1][acknowledgment(posts[0])['x-request-id']]
        second = self.attempt_history[-1][acknowledgment(posts[1])['x-request-id']]
        self.assertEqual([row['method'] for row in rows], ['GET', 'POST', 'GET', 'POST'])
        self.assertEqual(posts[0]['body_base64'], posts[1]['body_base64'])
        self.assertEqual((first['transport'], first['receiving'], first['business_status']),
                         ('unconfirmed', 'unconfirmed', 'failed'))
        self.assertNotEqual(first['curl_code'], 0)
        self.assertEqual(second['receiving'], 'confirmed')
        self.assertEqual([status['status'] for status in statuses], ['failed', 'completed'])

    def test_receiving_confirmation_with_malformed_business_body_still_fails(self):
        _, statuses = self.run_result([policy_response()], ack=acknowledgment,
                                      post_error={'code': 'api.internal_error', 'detail': CANARY})
        record = next(iter(self.attempt_history[-1].values()))
        self.assertEqual(record['receiving'], 'confirmed')
        self.assertEqual(record['business_status'], 'failed')
        self.assertEqual(statuses[0]['status'], 'failed')

    def test_http_refusals_and_redirects_never_become_receiving_or_business_success(self):
        for status in (401, 403, 429, 503, 302):
            with self.subTest(status=status):
                rows, statuses = self.run_result([policy_response()], post_statuses=(status,),
                                                post_error={'code': 'api.internal_error', 'details': CANARY})
                self.assertEqual([row['method'] for row in rows], ['GET', 'POST'])
                attempt = next(iter(self.attempt_history[-1].values()))
                self.assertEqual(attempt['transport'], 'http_response')
                self.assertEqual(attempt['receiving'], 'unconfirmed')
                self.assertEqual(attempt['business_status'], 'failed')
                self.assertEqual(statuses[0]['status'], 'failed')

    def test_policy_changes_between_real_get_and_post_then_retry_suppresses(self):
        policy_a = policy_response()
        policy_b = policy_response(policy_document(False))
        current = [None]
        def changed_after_get(_count):
            current[0] = digest(policy_b[2])
        def refuse_old(row):
            self.assertEqual(acknowledgment(row)['x-agentdoc-egress-policy-digest'], digest(policy_a[2]))
            self.assertNotEqual(acknowledgment(row)['x-agentdoc-egress-policy-digest'], current[0])
            return {}
        rows, statuses = self.run_result([policy_a, policy_b], attempts=2, ack=refuse_old,
                                        after_get=changed_after_get, post_statuses=(409,),
                                        post_error={'code': 'egress.policy_unavailable'})
        self.assertEqual([row['method'] for row in rows], ['GET', 'POST', 'GET'])
        self.assertEqual([status['status'] for status in statuses], ['failed', 'skipped'])
        self.assertEqual(len(self.attempt_history[-1]), 1)
        self.assertEqual(next(iter(self.attempt_history[-1].values()))['receiving'], 'unconfirmed')

    def test_private_attempt_directory_isolation_refuses_before_payload(self):
        for kind in ('symlink', 'permissions'):
            with self.subTest(kind=kind):
                def mutate(_env, directory):
                    path = directory / 'private/cloud-egress-attempts'
                    if kind == 'symlink':
                        target = directory / 'outside'; target.mkdir(mode=0o700)
                        path.symlink_to(target, target_is_directory=True)
                    else:
                        path.mkdir(mode=0o755)
                # Directory rejection is checked separately from the receipt reader.
                with tempfile.TemporaryDirectory() as temp:
                    directory = Path(temp)
                    with HttpsRecorder(directory, lambda row: policy_response()) as recorder:
                        command, env = result_fixture(directory, recorder.origin, recorder.ca_file)
                        mutate(env, directory)
                        result = subprocess.run(command, env=env, capture_output=True, timeout=45)
                        self.assertEqual(result.returncode, 0)
                        self.assertEqual([row['method'] for row in recorder.records()], ['GET'])
                        self.assertEqual(json.loads((directory / 'private/cloud-sync-status.json').read_bytes())['status'], 'failed')

    def test_recorder_retains_every_real_curl_retry(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            with HttpsRecorder(directory, lambda record: (
                503 if record["sequence"] == 1 else 201, {}, b"{}"
            )) as recorder:
                body = b'{"outer":{"bytes_base64":"' + base64.b64encode(CANARY.encode()) + b'"}}\n'
                result = subprocess.run([
                    "/usr/bin/curl", "-q", "--silent", "--show-error",
                    "--noproxy", "*", "--cacert", str(recorder.ca_file),
                    "--max-time", "5", "--retry", "1", "--retry-delay", "1",
                    "--data-binary", "@-", recorder.origin + "/retry",
                ], input=body, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                records = recorder.records()
                self.assertEqual([row["sequence"] for row in records], [1, 2])
                self.assertEqual([row["method"] for row in records], ["POST", "POST"])
                self.assertEqual([row["path"] for row in records], ["/retry", "/retry"])
                self.assertEqual([base64.b64decode(row["body_base64"]) for row in records], [body, body])
                self.assertTrue(all(row["headers"] for row in records))

    def run_result(self, policies, *, attempts=1, token=EGRESS_TOKEN, post_statuses=(201,), post_error=None, mutate=None, ack=None, after_get=None):
        gets = []
        posts = []

        def respond(record):
            if record["method"] == "GET":
                gets.append(record)
                response = policies[min(len(gets) - 1, len(policies) - 1)]
                if after_get:
                    after_get(len(gets))
                return response
            posts.append(record)
            status = post_statuses[min(len(posts) - 1, len(post_statuses) - 1)]
            headers = ack(record) if ack else {}
            if post_error is not None:
                return status, headers, json.dumps({"error": post_error}).encode()
            envelope = json.loads(base64.b64decode(record["body_base64"]))
            return status, headers, json.dumps({
                "recorded": True, "result_digest": envelope["result"]["result_digest"],
            }).encode()

        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            with HttpsRecorder(directory, respond) as recorder:
                command, env = result_fixture(directory, recorder.origin, recorder.ca_file)
                env["CLOUD_EGRESS_TOKEN"] = token
                if mutate:
                    mutate(env, directory)
                statuses = []
                self.attempt_history = []
                prior_attempt_bytes = {}
                source_paths = [directory / "work-request.json", directory / "retained/assessment.json"]
                originals = [path.read_bytes() for path in source_paths]
                for _ in range(attempts):
                    result = subprocess.run(command, env=env, capture_output=True, timeout=45)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertNotIn(CANARY.encode(), result.stdout + result.stderr)
                    if token:
                        self.assertNotIn(token.encode(), result.stdout + result.stderr)
                    statuses.append(json.loads((directory / "private/cloud-sync-status.json").read_text()))
                    for path, previous in prior_attempt_bytes.items():
                        self.assertEqual(path.read_bytes(), previous)
                    prior_attempt_bytes = {path: path.read_bytes() for path in
                                           (directory / 'private/cloud-egress-attempts').glob('*.json')}
                    snapshot = attempt_snapshots(directory)
                    for record in snapshot.values():
                        self.assertNotIn(CANARY, json.dumps(record))
                        if token:
                            self.assertNotIn(token, json.dumps(record))
                    if self.attempt_history:
                        for key, record in self.attempt_history[-1].items():
                            self.assertEqual(snapshot[key], record)
                    self.attempt_history.append(snapshot)
                self.assertEqual([path.read_bytes() for path in source_paths], originals)
                return recorder.records(), statuses

    def assert_policy_gets(self, records, count):
        gets = [row for row in records if row["method"] == "GET"]
        self.assertEqual(len(gets), count, "Each attempt must fetch policy before any payload POST")
        for row in gets:
            url = urlsplit(row["path"])
            self.assertEqual(url.path, f"/api/v1/workspaces/{WORKSPACE}/egress-policies")
            self.assertEqual(parse_qs(url.query, keep_blank_values=True), {
                "repository_id": [REPOSITORY], "source_provider": ["github"],
                "external_repository_id": ["42"],
            }, "Never downgrade to a query without the trusted source expectation")
            self.assertEqual(base64.b64decode(row["body_base64"]), b"")
            headers = {key.lower(): value for key, value in row["headers"]}
            self.assertEqual(headers.get("authorization"), "Bearer " + EGRESS_TOKEN)
            self.assertNotIn(CANARY, row["path"] + json.dumps(row["headers"]))

    def assert_suppressed(self, records, statuses, code):
        # Check the entire network ledger, including all embedded envelope bytes.
        for row in records:
            visible = (row["path"] + json.dumps(row["headers"])).encode()
            body = base64.b64decode(row["body_base64"])
            self.assertFalse(CANARY.encode() in visible + body,
                             f"Disabled audit canary escaped in request {row['sequence']}")
        self.assertEqual([row["method"] for row in records if row["method"] != "GET"], [],
                         "Suppress the entire immutable upload; do not redact it")
        for status in statuses:
            self.assertNotEqual(status["status"], "completed")
            self.assertEqual(status["reason_code"], code)

    def test_all_enabled_policy_preserves_exact_upload_and_success_shape(self):
        records, statuses = self.run_result([policy_response()])
        self.assert_policy_gets(records, 1)
        self.assertEqual([row["method"] for row in records], ["GET", "POST"])
        baseline = (ROOT / "test/fixture-cloud-result-upload.json").read_bytes()
        self.assertEqual(base64.b64decode(records[1]["body_base64"]), baseline)
        self.assertEqual(statuses, [{
            "status": "completed", "reason": "uploaded", "reason_code": None,
            "result_digest": json.loads(baseline)["result"]["result_digest"],
            "remediation": None,
        }])

    def test_audit_only_policy_refuses_unverified_work_request(self):
        policy = policy_document(False)
        policy["payload"]["categories"]["audit_metadata"] = True
        records, statuses = self.run_result([policy_response(policy)])
        self.assert_suppressed(records, statuses, "egress.category_disabled")
        self.assert_policy_gets(records, 1)

    def test_each_category_disabled_suppresses_unverified_result_and_retry(self):
        for category in CATEGORIES:
            with self.subTest(category=category):
                policy = policy_document()
                policy["payload"]["categories"][category] = False
                records, statuses = self.run_result([policy_response(policy)], attempts=2)
                self.assert_suppressed(records, statuses, "egress.category_disabled")
                self.assert_policy_gets(records, 2)

    def test_disabled_audit_suppresses_full_upload_and_reinvocation(self):
        policy = policy_document()
        policy["payload"]["categories"]["audit_metadata"] = False
        records, statuses = self.run_result([policy_response(policy)], attempts=2)
        self.assert_suppressed(records, statuses, "egress.category_disabled")
        self.assert_policy_gets(records, 2)

    def test_empty_or_invalid_token_never_posts(self):
        for token in ("", "bad token"):
            with self.subTest(token=token):
                records, statuses = self.run_result([policy_response()], token=token)
                self.assert_suppressed(records, statuses, "egress.policy_unavailable")
                self.assertEqual(records, [], "Invalid credentials must fail before any HTTP request")

    def test_missing_or_invalid_policy_never_posts(self):
        valid = policy_response()
        wrong_repo = policy_document()
        wrong_repo["payload"]["scope"]["resource"]["id"] = "30000000-0000-0000-0000-000000000402"
        wrong_workspace = policy_document()
        wrong_workspace["payload"]["scope"]["workspace_id"] = "10000000-0000-0000-0000-000000000402"
        unknown = policy_document()
        unknown["payload"]["categories"]["future_category"] = True
        missing = policy_document()
        del missing["payload"]["categories"]["raw_source"]
        nonboolean = policy_document()
        nonboolean["payload"]["categories"]["audit_metadata"] = "true"
        cases = {
            "missing_policy": (404, {}, b"null"),
            "empty_policy": (200, {}, b""),
            "missing_digest": (200, {}, valid[2]),
            "invalid_digest": (200, {"x-agentdoc-egress-policy-digest": "sha256:invalid"}, valid[2]),
            "digest_mismatch": (200, {"x-agentdoc-egress-policy-digest": "sha256:" + "0" * 64}, valid[2]),
            "wrong_repository": policy_response(wrong_repo),
            "wrong_workspace": policy_response(wrong_workspace),
            "unknown_category": policy_response(unknown),
            "missing_category": policy_response(missing),
            "nonboolean_category": policy_response(nonboolean),
            "malformed_json": raw_policy_response(b"{"),
            "duplicate_json_key": raw_policy_response(valid[2].replace(
                b'"audit_metadata": true', b'"audit_metadata": false, "audit_metadata": true')),
            "oversize": raw_policy_response(valid[2] + b" " * 1048576),
            "invalid_utf8": raw_policy_response(valid[2] + b"\xff"),
            "http_503": (503, {}, b'{"error":{"code":"egress.policy_unavailable"}}'),
            "redirect": (302, {"Location": "/unexpected-policy-downgrade"}, b"{}"),
        }
        for name, response in cases.items():
            with self.subTest(case=name):
                records, statuses = self.run_result([response])
                self.assert_suppressed(records, statuses, "egress.policy_unavailable")
                self.assert_policy_gets(records, 1)

    def test_policy_401_and_403_remain_visible_without_downgrade(self):
        for status, code in ((401, "api.unauthenticated"), (403, "workspace.cross_tenant_denied")):
            with self.subTest(status=status):
                response = status, {}, json.dumps({"error": {"code": code}}).encode()
                records, statuses = self.run_result([response])
                self.assert_suppressed(records, statuses, code)
                self.assert_policy_gets(records, 1)

    def test_explicit_retry_refetches_enabled_policy_and_preserves_exact_bytes(self):
        records, statuses = self.run_result([policy_response()], attempts=2, post_statuses=(503, 201))
        self.assert_policy_gets(records, 2)
        self.assertEqual([row["method"] for row in records], ["GET", "POST", "GET", "POST"])
        baseline = (ROOT / "test/fixture-cloud-result-upload.json").read_bytes()
        self.assertEqual([base64.b64decode(row["body_base64"]) for row in records if row["method"] == "POST"],
                         [baseline, baseline])
        self.assertNotEqual(statuses[0]["status"], "completed")
        self.assertEqual(statuses[1]["status"], "completed")

    def test_result_preserves_only_allowlisted_egress_rejection(self):
        for server_code, expected_code, expected_reason in (
            ("egress.payload_rejected", "egress.payload_rejected", "egress_payload_rejected"),
            ("egress.payload_rejected." + CANARY, "action.cloud_sync_failed", "upload_failed"),
        ):
            with self.subTest(server_code=server_code):
                rows, statuses = self.run_result(
                    [policy_response()], post_statuses=(403,),
                    post_error={"code": server_code, "message": CANARY, "remediation": CANARY})
                self.assert_policy_gets(rows, 1)
                self.assertEqual([row["method"] for row in rows], ["GET", "POST"])
                baseline = (ROOT / "test/fixture-cloud-result-upload.json").read_bytes()
                self.assertEqual(base64.b64decode(rows[1]["body_base64"]), baseline)
                self.assertEqual(statuses[0]["status"], "failed")
                self.assertEqual(statuses[0]["reason_code"], expected_code)
                self.assertEqual(statuses[0]["reason"], expected_reason)
                self.assertEqual(statuses[0]["result_digest"], json.loads(baseline)["result"]["result_digest"])
                self.assertNotIn(CANARY, json.dumps(statuses))

    def test_explicit_retry_refetches_policy_without_cached_allow(self):
        policy = policy_document()
        policy["payload"]["categories"]["audit_metadata"] = False
        for response, code in (
            (policy_response(policy), "egress.category_disabled"),
            ((503, {}, b"{}"), "egress.policy_unavailable"),
        ):
            with self.subTest(retry_policy=code):
                records, statuses = self.run_result([policy_response(), response],
                                                   attempts=2, post_statuses=(503,))
                self.assert_policy_gets(records, 2)
                self.assertEqual([row["method"] for row in records], ["GET", "POST", "GET"])
                self.assert_suppressed(records[2:], statuses[1:], code)

    def test_untrusted_work_request_source_in_subject_is_not_authorized_metadata(self):
        source_canary = "E66_PRIVATE_SOURCE_CANARY const customerSecret = 'synthetic';"
        def mutate(env, directory):
            path = Path(env['CLOUD_WORK_REQUEST'])
            request = json.loads(path.read_bytes())
            request['workload']['subject'] = source_canary
            del request['request_digest']
            request['request_digest'] = digest(json.dumps(request, sort_keys=True, separators=(',', ':')).encode())
            path.write_text(json.dumps(request))
        policy = policy_document(False)
        policy['payload']['categories']['audit_metadata'] = True
        rows, statuses = self.run_result([policy_response(policy)], mutate=mutate)
        posts = [row for row in rows if row['method'] == 'POST']
        counts = [base64.b64decode(row['body_base64']).count(source_canary.encode()) for row in posts]
        self.assertEqual(len(posts), 0,
                         f'Untrusted source text laundered as metadata; canary copies per POST={counts}')
        self.assertNotEqual(statuses[0]['status'], 'completed')

    def test_stale_trusted_head_or_expired_authority_never_gets_or_posts(self):
        for stale in ('head', 'authority'):
            with self.subTest(stale=stale):
                def mutate(env, directory):
                    request = directory / 'trusted-request.json'
                    request.write_text(json.dumps({
                        'base_repository': 'agentdoc-dev/adoc', 'head_repository': 'agentdoc-dev/adoc',
                        'pull_request': 165, 'base_ref': 'main', 'base_revision': 'c' * 40,
                        'head_revision': env['ADOC_HEAD'],
                    }))
                    run = Path(env['ADOC_RUN_DIR'])
                    (run / 'trusted-phase-status.json').write_text('{"state":"authorized"}')
                    env.update(ADOC_TRUSTED_PHASE='true', ADOC_TRUSTED_CHANGE_REQUEST_PATH=str(request),
                               ADOC_TRUSTED_AUTHORIZATION_EXPIRES_AT=('2000-01-01T00:00:00Z' if stale == 'authority' else '2099-08-26T12:00:00Z'),
                               ADOC_TRUSTED_ASSESSMENT_DIGEST=(run / 'assessment-sha256').read_text().strip(),
                               GITHUB_ENV=str(directory / 'github-env'))
                    bindir = directory / 'bin'; bindir.mkdir()
                    gh = bindir / 'gh'
                    response = json.dumps({'state': 'open',
                                           'base': {'sha': 'c' * 40, 'ref': 'main', 'repo': {'full_name': 'agentdoc-dev/adoc'}},
                                           'head': {'sha': 'b' * 40, 'repo': {'full_name': 'agentdoc-dev/adoc'}}})
                    gh.write_text("#!/bin/sh\ncat <<'JSON'\n" + response + "\nJSON\n")
                    gh.chmod(0o755)
                    env['PATH'] = str(bindir) + ':' + env['PATH']
                rows, statuses = self.run_result([policy_response()], mutate=mutate)
                self.assertEqual(rows, [], 'Stale trusted authority must fail before policy GET as well as POST')
                self.assertEqual(statuses[0]['reason'], 'stale_head')


if __name__ == "__main__":
    unittest.main()
