#!/usr/bin/env python3
"""Check a fresh, source-bound Cloud policy before sending an immutable payload.

Arguments: curl, upload URL, Cloud workspace UUID, Cloud repository UUID,
trusted GitHub repository ID, required categories. Exit zero only when allowed;
otherwise stdout contains a fixed public reason code, never response content.
--notice uses the same destination/source arguments followed by the operation;
it sends only optional sender-reported metadata and never changes local status.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid
from urllib.parse import urlencode, urlsplit


CATEGORIES = {
    "raw_source", "source_excerpts", "pr_diffs", "compiled_objects",
    "embeddings", "semantic_assessments", "audit_metadata",
}
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
MAX_BYTES = 1048576
UNAVAILABLE = "egress.policy_unavailable"


def policy_url(upload_url, workspace, repository, external_id):
    if not (re.fullmatch(UUID, workspace) and re.fullmatch(UUID, repository)
            and re.fullmatch(r"[1-9][0-9]*", external_id)):
        raise ValueError()
    # Validate before urlsplit, which otherwise strips some control characters.
    if not re.fullmatch(r"https://[!-~]+", upload_url) or any(
        char in upload_url for char in "?#\\"
    ):
        raise ValueError()
    url = urlsplit(upload_url)
    if not re.fullmatch(
        r"(?:[a-z0-9]+(?:[.-][a-z0-9]+)*|\[[0-9a-f:]+\])(?::[1-9][0-9]{0,4})?",
        url.netloc,
    ) or url.port == 0:
        raise ValueError()
    # These are the three existing upload routes; no arbitrary origin/path input.
    if url.path not in {
        f"/api/workspaces/{workspace}/external-work-results",
        f"/api/v1/workspaces/{workspace}/assessment-submissions",
        f"/api/v1/workspaces/{workspace}/proposal-commands",
    }:
        raise ValueError()
    query = urlencode({
        "repository_id": repository,
        "source_provider": "github",
        "external_repository_id": external_id,
    })
    return f"https://{url.netloc}/api/v1/workspaces/{workspace}/egress-policies?{query}"


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def invalid_constant(_value):
    raise ValueError()


def has_keys(value, keys):
    return isinstance(value, dict) and value.keys() == keys


def validate_policy(body, digest, workspace, repository):
    if not body or len(body) > MAX_BYTES or digest != "sha256:" + hashlib.sha256(body).hexdigest():
        raise ValueError()
    policy = json.loads(body.decode("utf-8"), object_pairs_hook=unique_object,
                        parse_constant=invalid_constant)
    if not has_keys(policy, {"schema_version", "payload"}) or policy["schema_version"] != "agentdoc.cloud.egress_policy.v0":
        raise ValueError()
    payload = policy["payload"]
    if not has_keys(payload, {"scope", "categories"}) or payload["scope"] != {
        "workspace_id": workspace,
        "resource": {"kind": "repository", "id": repository},
    }:
        raise ValueError()
    categories = payload["categories"]
    if not has_keys(categories, CATEGORIES) or any(type(value) is not bool for value in categories.values()):
        raise ValueError()
    return categories


def check(curl, upload_url, workspace, repository, external_id, *required):
    url = policy_url(upload_url, workspace, repository, external_id)
    token = os.environ.get("CLOUD_EGRESS_TOKEN", "")
    if (not os.path.isabs(curl) or not os.access(curl, os.X_OK)
            or not re.fullmatch(r"[A-Za-z0-9._~-]{16,512}", token)
            or token in [os.environ.get(name) for name in (
                "GH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
            )]
            or not required or not set(required) <= CATEGORIES):
        return UNAVAILABLE

    # curl uses the same TLS configuration as the payload sender. The token is
    # passed through stdin, never argv; no redirects, retries, or cached policy.
    with tempfile.TemporaryDirectory(prefix="adoc-egress-") as directory:
        body_file = Path(directory) / "body"
        headers_file = Path(directory) / "headers"
        response = subprocess.run([
            curl, "-q", "--config", "-", "--silent", "--globoff",
            "--proto", "=https", "--connect-timeout", "10", "--max-time", "30",
            "--max-filesize", str(MAX_BYTES), "--request", "GET",
            "--header", "Accept: application/json", "--output", str(body_file),
            "--dump-header", str(headers_file), "--write-out", "%{http_code}", url,
        ], input=f'header = "Authorization: Bearer {token}"\n'.encode(),
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=35)
        status = response.stdout
        if status == b"401":
            return "api.unauthenticated"
        if status == b"403":
            return "workspace.cross_tenant_denied"
        if response.returncode != 0 or status != b"200":
            return UNAVAILABLE
        # Use the final HTTP header block (after any proxy/interim response),
        # never a digest in trailers or a duplicate digest header.
        blocks = [block for block in re.split(rb"\r?\n\r?\n", headers_file.read_bytes())
                  if block.startswith(b"HTTP/")]
        if not blocks or not re.fullmatch(rb"HTTP/\S+ 200(?: [^\r\n]*)?", blocks[-1].splitlines()[0]):
            return UNAVAILABLE
        digests = [line.split(b":", 1)[1].strip().decode("ascii")
                   for line in blocks[-1].splitlines()[1:]
                   if line.split(b":", 1)[0].lower() == b"x-agentdoc-egress-policy-digest"]
        if len(digests) != 1:
            return UNAVAILABLE
        with body_file.open("rb") as stream:
            categories = validate_policy(stream.read(MAX_BYTES + 1), digests[0], workspace, repository)
    return "" if all(categories[category] for category in required) else "egress.category_disabled"


def notice(curl, upload_url, workspace, repository, external_id, operation):
    """Best-effort sender-reported metadata, never a receipt or execution proof."""
    credentials = {
        "assessment_submission": ("assessment-submissions", "CLOUD_ASSESSMENT_TOKEN"),
        "proposal_command": ("proposal-commands", "CLOUD_PROPOSAL_TOKEN"),
        "external_work.result_submit": ("external-work-results", "CLOUD_UPLOAD_TOKEN"),
    }
    suffix, credential = credentials[operation]
    url = policy_url(upload_url, workspace, repository, external_id)
    if not upload_url.endswith("/" + suffix):
        return
    token = os.environ.get(credential, "")
    invocation = os.environ.get("ADOC_INVOCATION_ID", "")
    if (not re.fullmatch(r"[A-Za-z0-9._~-]{16,512}", token)
            or token in [os.environ.get(name) for name in (
                "CLOUD_EGRESS_TOKEN", "GH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
            )] or not re.fullmatch(r"inv_[A-Za-z0-9_-]+", invocation)):
        return
    origin = "https://" + urlsplit(url).netloc
    body = {
        "notice_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "agentdoc:egress-status:" + json.dumps(
            [origin, workspace, repository, operation, invocation], separators=(",", ":")))),
        "operation": operation, "repository_id": repository, "code": "egress.category_disabled",
    }
    if operation == "external_work.result_submit":
        verifier = os.environ.get("CLOUD_VERIFIER_ID", "")
        if not re.fullmatch(UUID, verifier):
            return
        body["verifier_id"] = verifier
    if check(curl, upload_url, workspace, repository, external_id, "audit_metadata"):
        return
    with tempfile.TemporaryDirectory(prefix="adoc-egress-notice-") as directory:
        body_file = Path(directory) / "notice.json"
        body_file.write_bytes(json.dumps(body, sort_keys=True, separators=(",", ":")).encode())
        subprocess.run([
            curl, "-q", "--config", "-", "--silent", "--globoff", "--proto", "=https",
            "--connect-timeout", "10", "--max-time", "30", "--max-filesize", str(MAX_BYTES),
            "--request", "POST", "--header", "Content-Type: application/json",
            "--data-binary", "@" + str(body_file), "--output", os.devnull,
            origin + f"/api/v1/workspaces/{workspace}/egress-status",
        ], input=f'header = "Authorization: Bearer {token}"\n'.encode(),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=35)


if __name__ == "__main__":
    sending_notice = sys.argv[1:2] == ["--notice"]
    try:
        reason = notice(*sys.argv[2:]) if sending_notice else check(*sys.argv[1:])
    except (OSError, ValueError, TypeError, KeyError, IndexError, RecursionError, subprocess.SubprocessError):
        reason = None if sending_notice else UNAVAILABLE
    if reason:
        print(reason)
        sys.exit(1)
