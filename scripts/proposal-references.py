#!/usr/bin/env python3
"""Render, parse and attach the adoc.git_proposal_references.v0 block.

The renderer is the only byte form: parse re-renders what it read and
rejects anything that is not byte-identical. Exit 65 (EX_DATAERR) on any
invalid input, with the reason on stderr.
"""
import argparse
import json
import re
import sys

SCHEMA = "adoc.git_proposal_references.v0"
OPEN = "<!-- AgentDoc-Proposal-References:v0 -->"
CLOSE = "<!-- /AgentDoc-Proposal-References:v0 -->"
ANY_MARKER = re.compile(r"<!-- /?AgentDoc-Proposal-References:")
MAX_BYTES = 65536
KEYS = ("schema_version", "source_pr", "source_head_sha",
        "assessment_receipt_digest", "affected_objects", "proposal_set_digest")
HEAD = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
REPOSITORY_ID = re.compile(r"[1-9][0-9]*\Z")
# Adoc V0 ObjectId grammar (adoc-core domain/identity.rs). ASCII-only, so
# code-point order equals the UTF-16 order Cloud sorts by.
OBJECT_ID = re.compile(
    r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\Z")


class Invalid(ValueError):
    pass


def _no_duplicates(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise Invalid(f"duplicate key {key}")
        out[key] = value
    return out


def _exact(value, keys, where):
    if not isinstance(value, dict):
        raise Invalid(f"{where} is not an object")
    missing = [k for k in keys if k not in value]
    unknown = [k for k in value if k not in keys]
    if missing:
        raise Invalid(f"{where} missing {missing[0]}")
    if unknown:
        raise Invalid(f"{where} unknown key {unknown[0]}")


def _match(pattern, value, where):
    if not isinstance(value, str) or not pattern.match(value):
        raise Invalid(f"invalid {where}")


def canonical(refs):
    """Validate refs and return the ordered object the renderer emits."""
    _exact(refs, KEYS, "block")
    if refs["schema_version"] != SCHEMA:
        raise Invalid("unsupported schema_version")
    pr = refs["source_pr"]
    _exact(pr, ("repository_id", "number"), "source_pr")
    _match(REPOSITORY_ID, pr["repository_id"], "source_pr.repository_id")
    number = pr["number"]
    if type(number) is not int or number < 1:
        raise Invalid("invalid source_pr.number")
    _match(HEAD, refs["source_head_sha"], "source_head_sha")
    _match(DIGEST, refs["assessment_receipt_digest"], "assessment_receipt_digest")
    _match(DIGEST, refs["proposal_set_digest"], "proposal_set_digest")
    objects = refs["affected_objects"]
    if not isinstance(objects, list) or not objects:
        raise Invalid("affected_objects must be a non-empty array")
    ordered_objects = []
    previous = None
    for item in objects:
        _exact(item, ("object_id", "content_hash"), "affected_objects[]")
        _match(OBJECT_ID, item["object_id"], "affected_objects[].object_id")
        _match(DIGEST, item["content_hash"], "affected_objects[].content_hash")
        if previous is not None and item["object_id"] <= previous:
            raise Invalid("affected_objects must be sorted by object_id and unique")
        previous = item["object_id"]
        ordered_objects.append({"object_id": item["object_id"],
                                "content_hash": item["content_hash"]})
    return {
        "schema_version": SCHEMA,
        "source_pr": {"repository_id": pr["repository_id"], "number": number},
        "source_head_sha": refs["source_head_sha"],
        "assessment_receipt_digest": refs["assessment_receipt_digest"],
        "affected_objects": ordered_objects,
        "proposal_set_digest": refs["proposal_set_digest"],
    }


def _json(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def render(refs):
    block = f"{OPEN}\n{_json(canonical(refs))}\n{CLOSE}"
    if len(block.encode("utf-8")) > MAX_BYTES:
        raise Invalid("block exceeds 64 KiB")
    return block


def _span(body):
    """Return (start, end) of the single block in body, or None when absent."""
    opens, closes = body.count(OPEN), body.count(CLOSE)
    if len(ANY_MARKER.findall(body)) != opens + closes:
        raise Invalid("unsupported reference block version")
    if opens == 0 and closes == 0:
        return None
    if opens != 1 or closes != 1:
        raise Invalid("expected exactly one reference block")
    start, close = body.index(OPEN), body.index(CLOSE)
    if close < start:
        raise Invalid("reference block markers out of order")
    return start, close + len(CLOSE)


def _reject_constant(name):
    raise Invalid(f"invalid JSON constant {name}")


def _lf(body):
    # GitHub may store edited bodies with CRLF; the block itself is always LF.
    return body.replace("\r\n", "\n")


def parse(body):
    body = _lf(body)
    span = _span(body)
    if span is None:
        raise Invalid("reference block missing")
    block = body[span[0]:span[1]]
    if len(block.encode("utf-8")) > MAX_BYTES:
        raise Invalid("block exceeds 64 KiB")
    inner = block[len(OPEN):-len(CLOSE)]
    if not (inner.startswith("\n") and inner.endswith("\n")):
        raise Invalid("block is not newline-delimited")
    try:
        refs = json.loads(inner[1:-1], object_pairs_hook=_no_duplicates,
                          parse_constant=_reject_constant)
    except json.JSONDecodeError as error:
        raise Invalid(f"invalid JSON: {error.msg}") from None
    if render(refs) != block:
        raise Invalid("block bytes are not canonical")
    return canonical(refs)


def attach(body, block):
    """Replace the single existing block in body, or append one."""
    parse(block)
    body = _lf(body)
    span = _span(body)
    if span is not None:
        return body[:span[0]] + block + body[span[1]:]
    return body.rstrip("\n") + "\n\n" + block + "\n"


def _read(path):
    if path in (None, "-"):
        return sys.stdin.buffer.read().decode("utf-8")
    with open(path, "rb") as handle:
        return handle.read().decode("utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="proposal-references.py")
    commands = parser.add_subparsers(dest="command", required=True)
    r = commands.add_parser("render")
    r.add_argument("--source-pr-repository-id", required=True)
    r.add_argument("--source-pr-number", required=True)
    r.add_argument("--source-head", required=True)
    r.add_argument("--receipt-sha256", required=True)
    r.add_argument("--affected-objects", required=True)
    r.add_argument("--proposal-set-sha256", required=True)
    p = commands.add_parser("parse")
    p.add_argument("body", nargs="?")
    a = commands.add_parser("attach")
    a.add_argument("block")
    a.add_argument("body", nargs="?")
    args = parser.parse_args(argv)
    try:
        if args.command == "render":
            if not re.fullmatch(r"[1-9][0-9]*", args.source_pr_number):
                raise Invalid("invalid source_pr.number")
            objects = json.loads(_read(args.affected_objects),
                                 object_pairs_hook=_no_duplicates,
                                 parse_constant=_reject_constant)
            sys.stdout.write(render({
                "schema_version": SCHEMA,
                "source_pr": {"repository_id": args.source_pr_repository_id,
                              "number": int(args.source_pr_number)},
                "source_head_sha": args.source_head,
                "assessment_receipt_digest": args.receipt_sha256,
                "affected_objects": objects,
                "proposal_set_digest": args.proposal_set_sha256,
            }))
        elif args.command == "parse":
            sys.stdout.write(_json(parse(_read(args.body))) + "\n")
        else:
            sys.stdout.write(attach(_read(args.body), _read(args.block)))
    except (Invalid, ValueError, OSError) as error:
        print(f"proposal-references: {error}", file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    sys.exit(main())
