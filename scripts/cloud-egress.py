#!/usr/bin/env python3
"""Check a fresh, source-bound Cloud policy before sending an immutable payload.

Arguments: curl, upload URL, Cloud workspace UUID, Cloud repository UUID,
trusted GitHub repository ID, required categories. Allowed stdout is the exact
verified policy digest. Exit zero only when allowed;
otherwise stdout contains a fixed public reason code, never response content.
--notice uses the same destination/source arguments followed by the operation;
it sends only optional sender-reported metadata and never changes local status.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import stat
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
    # These are the existing upload routes; no arbitrary origin/path input.
    if url.path not in {
        f"/api/workspaces/{workspace}/external-work-results",
        f"/api/v1/workspaces/{workspace}/assessment-submissions",
        f"/api/v1/workspaces/{workspace}/proposal-commands",
        f"/api/v1/workspaces/{workspace}/proposal-deliveries",
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
        return UNAVAILABLE, None

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
            return "api.unauthenticated", None
        if status == b"403":
            return "workspace.cross_tenant_denied", None
        if response.returncode != 0 or status != b"200":
            return UNAVAILABLE, None
        # Use the final HTTP header block (after any proxy/interim response),
        # never a digest in trailers or a duplicate digest header.
        blocks = [block for block in re.split(rb"\r?\n\r?\n", headers_file.read_bytes())
                  if block.startswith(b"HTTP/")]
        if not blocks or not re.fullmatch(rb"HTTP/\S+ 200(?: [^\r\n]*)?", blocks[-1].splitlines()[0]):
            return UNAVAILABLE, None
        digests = [line.split(b":", 1)[1].strip().decode("ascii")
                   for line in blocks[-1].splitlines()[1:]
                   if line.split(b":", 1)[0].lower() == b"x-agentdoc-egress-policy-digest"]
        if len(digests) != 1:
            return UNAVAILABLE, None
        with body_file.open("rb") as stream:
            categories = validate_policy(stream.read(MAX_BYTES + 1), digests[0], workspace, repository)
    return ("", digests[0]) if all(categories[category] for category in required) else ("egress.category_disabled", None)



DIGEST = r"sha256:[0-9a-f]{64}"
OPERATIONS = {"assessment_submission", "proposal_command", "proposal_delivery", "external_work.result_submit", "egress_status"}


def attempt_directory():
    root = Path(os.environ["ADOC_RUN_DIR"])
    if root.is_symlink() or not root.is_dir() or root.stat().st_uid != os.getuid():
        raise ValueError()
    directory = root / "cloud-egress-attempts"
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError()
    return directory


def private_read(path, limit):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError()
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError()
    return data


def prepare_attempt(operation, workspace, repository, policy_digest, body_path):
    if (operation not in OPERATIONS or not re.fullmatch(UUID, workspace)
            or not re.fullmatch(UUID, repository) or not re.fullmatch(DIGEST, policy_digest)):
        raise ValueError()
    # Streaming hash observes the exact retained HTTP body, not a reserialized envelope.
    body_hash = hashlib.sha256()
    with open(body_path, "rb") as body:
        for chunk in iter(lambda: body.read(65536), b""):
            body_hash.update(chunk)
    directory = attempt_directory()
    request_id = str(uuid.uuid4())
    record = {"operation": operation, "workspace_id": workspace, "repository_id": repository,
              "request_id": request_id, "body_digest": "sha256:" + body_hash.hexdigest(),
              "checked_policy_digest": policy_digest, "transport": "unconfirmed",
              "curl_code": None, "http_status": None, "receiving": "unconfirmed",
              "business_status": None, "business_disposition": None}
    for suffix, data in ((".json", json.dumps(record, sort_keys=True).encode() + b"\n"), (".headers", b"")):
        with os.fdopen(os.open(directory / (request_id + suffix), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb") as stream:
            stream.write(data)
    return request_id


def receiving_ack(headers, status, request_id, policy_digest):
    blocks = [block for block in re.split(rb"\r?\n\r?\n", headers) if block.startswith(b"HTTP/")]
    if not blocks or not re.fullmatch(rb"HTTP/\S+ " + str(status).encode() + rb"(?: [^\r\n]*)?", blocks[-1].splitlines()[0]):
        return False
    if any(not line or line[:1] in (b" ", b"\t") or b":" not in line for line in blocks[-1].splitlines()[1:]):
        return False
    for name, expected in ((b"x-request-id", request_id), (b"x-agentdoc-egress-policy-digest", policy_digest)):
        values = [line.split(b":", 1)[1].strip() for line in blocks[-1].splitlines()[1:]
                  if line.split(b":", 1)[0].lower() == name]
        if values != [expected.encode("ascii")]:
            return False
    return True


def finish_attempt(request_id, curl_code, http_status, status_path=""):
    if not re.fullmatch(UUID, request_id):
        raise ValueError()
    directory = attempt_directory()
    path = directory / (request_id + ".json")
    record = json.loads(private_read(path, 8192))
    # Finishing a previous attempt again cannot rewrite its observed result.
    if record["curl_code"] is not None:
        raise ValueError()
    code = int(curl_code)
    if not 0 <= code <= 255:
        raise ValueError()
    status = int(http_status) if re.fullmatch(r"[1-5][0-9]{2}", http_status) else None
    record.update(curl_code=code, http_status=status,
                  transport="http_response" if code == 0 and status else "unconfirmed")
    headers_path = directory / (request_id + ".headers")
    try:
        headers = private_read(headers_path, 65536)
        if code == 0 and status and receiving_ack(headers, status, request_id, record["checked_policy_digest"]):
            record["receiving"] = "confirmed"
    except (OSError, ValueError):
        pass
    finally:
        headers_path.unlink(missing_ok=True)
    # Copy only closed outcome enums; never raw response, payload, or remediation.
    if status_path:
        try:
            with open(status_path, "rb") as stream:
                business = json.loads(stream.read(8192))
            if business.get("status") in {"completed", "failed", "skipped"}:
                record["business_status"] = business["status"]
            if business.get("disposition") in {"accepted", "duplicate", "stale", "partial"}:
                record["business_disposition"] = business["disposition"]
        except (OSError, ValueError):
            pass
    fd, temporary = tempfile.mkstemp(prefix=request_id + ".", dir=directory)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(record, stream, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)

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
    reason, policy_digest = check(curl, upload_url, workspace, repository, external_id, "audit_metadata")
    if reason:
        return
    with tempfile.TemporaryDirectory(prefix="adoc-egress-notice-") as directory:
        body_file = Path(directory) / "notice.json"
        body_file.write_bytes(json.dumps(body, sort_keys=True, separators=(",", ":")).encode())
        attempt_id = prepare_attempt("egress_status", workspace, repository, policy_digest, body_file)
        headers = attempt_directory() / (attempt_id + ".headers")
        response = None
        try:
            response = subprocess.run([
                curl, "-q", "--config", "-", "--silent", "--globoff", "--proto", "=https",
                "--connect-timeout", "10", "--max-time", "30", "--max-filesize", str(MAX_BYTES),
                "--request", "POST", "--header", "Content-Type: application/json",
                "--data-binary", "@" + str(body_file), "--output", os.devnull,
                "--dump-header", str(headers), "--write-out", "%{http_code}",
                origin + f"/api/v1/workspaces/{workspace}/egress-status",
            ], input=(f'header = "Authorization: Bearer {token}"\n'
                      f'header = "X-Agentdoc-Egress-Policy-Digest: {policy_digest}"\n'
                      f'header = "X-Request-ID: {attempt_id}"\n').encode(),
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=35)
        finally:
            finish_attempt(attempt_id, str(response.returncode) if response else "255",
                           response.stdout.decode("ascii") if response else "000")


if __name__ == "__main__":
    mode = sys.argv[1:2]
    try:
        if mode == ["--notice"]:
            notice(*sys.argv[2:])
        elif mode == ["--prepare-attempt"]:
            print(prepare_attempt(*sys.argv[2:]))
        elif mode == ["--finish-attempt"]:
            finish_attempt(*sys.argv[2:])
        else:
            reason, policy_digest = check(*sys.argv[1:])
            if reason:
                print(reason)
                sys.exit(1)
            print(policy_digest)
    except (OSError, ValueError, TypeError, KeyError, IndexError, RecursionError, subprocess.SubprocessError):
        if mode not in (["--notice"], ["--prepare-attempt"], ["--finish-attempt"]):
            print(UNAVAILABLE)
        sys.exit(1)
