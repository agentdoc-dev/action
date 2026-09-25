"""adoc.git_proposal_references.v0 renderer/parser contract tests."""
import copy
import importlib.util
import json
import pathlib
import random
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "proposal-references.py"
FIXTURES = ROOT / "test" / "fixtures-proposal-references"
spec = importlib.util.spec_from_file_location("proposal_references", SCRIPT)
refs_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refs_mod)
Invalid = refs_mod.Invalid
OPEN, CLOSE = refs_mod.OPEN, refs_mod.CLOSE

GOLDEN_ARGS = [
    "--source-pr-repository-id", "123456789", "--source-pr-number", "42",
    "--source-head", "0123456789abcdef0123456789abcdef01234567",
    "--receipt-sha256", "sha256:" + "3" * 64,
    "--affected-objects", str(FIXTURES / "v0.affected-objects.json"),
    "--proposal-set-sha256", "sha256:" + "4" * 64,
]


def cli(*args, stdin=b""):
    return subprocess.run([sys.executable, "-B", str(SCRIPT), *args],
                          input=stdin, capture_output=True, check=False)


def valid(rng):
    def digest():
        return "sha256:" + "".join(rng.choice("0123456789abcdef") for _ in range(64))
    def segment():
        inner = "".join(rng.choice("abz09-") for _ in range(rng.randint(0, 6)))
        return rng.choice("az09") + (inner + rng.choice("az09") if inner else "")
    ids = sorted({".".join(segment() for _ in range(rng.randint(2, 4)))
                  for _ in range(rng.randint(1, 12))})
    return {
        "schema_version": refs_mod.SCHEMA,
        "source_pr": {"repository_id": str(rng.randint(1, 10**12)),
                      "number": rng.randint(1, 10**6)},
        "source_head_sha": "".join(rng.choice("0123456789abcdef") for _ in range(40)),
        "assessment_receipt_digest": digest(),
        "affected_objects": [{"object_id": i, "content_hash": digest()} for i in ids],
        "proposal_set_digest": digest(),
    }


def block_of(refs):
    """Hand-build block bytes, bypassing the renderer's validation."""
    return f"{OPEN}\n{json.dumps(refs, separators=(',', ':'), ensure_ascii=False)}\n{CLOSE}"


# Every leaf path of the block and one invalid value for it.
CORRUPTIONS = {
    ("schema_version",): "adoc.git_proposal_references.v99",
    ("source_pr", "repository_id"): 123,
    ("source_pr", "number"): "42",
    ("source_head_sha",): "A" * 40,
    ("assessment_receipt_digest",): "sha256:" + "g" * 64,
    ("affected_objects", 0, "object_id"): "",
    ("affected_objects", 0, "content_hash"): "sha1:" + "0" * 40,
    ("proposal_set_digest",): "0" * 64,
}


def mutate(refs, path, value=None, delete=False):
    out = copy.deepcopy(refs)
    parent = out
    for key in path[:-1]:
        parent = parent[key]
    if delete:
        del parent[path[-1]]
    else:
        parent[path[-1]] = value
    return out


class GoldenTest(unittest.TestCase):
    def test_golden_round_trip_is_byte_identical(self):
        golden = (FIXTURES / "v0.block.txt").read_bytes()
        rendered = cli("render", *GOLDEN_ARGS)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        self.assertEqual(rendered.stdout, golden)
        self.assertFalse(golden.endswith(b"\n"))
        parsed = cli("parse", stdin=b"PR text\n\n" + golden + b"\n\nfooter\n")
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        self.assertEqual(parsed.stdout, golden.split(b"\n")[1] + b"\n")

    def test_v99_fixture_is_rejected(self):
        result = cli("parse", str(FIXTURES / "v99.block.txt"))
        self.assertEqual(result.returncode, 65)
        self.assertIn(b"unsupported", result.stderr)
        refs = json.loads((FIXTURES / "v0.block.txt").read_text().split("\n")[1])
        refs["schema_version"] = "adoc.git_proposal_references.v99"
        with self.assertRaisesRegex(Invalid, "schema_version"):
            refs_mod.parse(block_of(refs))


class PropertyTest(unittest.TestCase):
    def test_render_parse_round_trip_and_single_field_damage(self):
        rng = random.Random(20260925)
        for _ in range(200):
            refs = valid(rng)
            block = refs_mod.render(refs)
            self.assertEqual(refs_mod.parse("body\n" + block + "\n"), refs)
            self.assertEqual(refs_mod.attach(refs_mod.attach("x", block), block),
                             "x\n\n" + block + "\n")
            for path, bad in CORRUPTIONS.items():
                for damaged in (mutate(refs, path, delete=True), mutate(refs, path, bad)):
                    with self.assertRaises(Invalid, msg=str(path)):
                        refs_mod.render(damaged)
                    with self.assertRaises(Invalid, msg=str(path)):
                        refs_mod.parse(block_of(damaged))


class RejectionTest(unittest.TestCase):
    def setUp(self):
        self.refs = valid(random.Random(7))
        self.refs["affected_objects"] = [
            {"object_id": "a.one", "content_hash": "sha256:" + "1" * 64},
            {"object_id": "b.two", "content_hash": "sha256:" + "2" * 64}]
        self.block = refs_mod.render(self.refs)

    def reject(self, body, reason):
        with self.assertRaisesRegex(Invalid, reason):
            refs_mod.parse(body)

    def test_missing_block(self):
        self.reject("no references here", "missing")

    def test_unknown_key(self):
        self.reject(block_of({**self.refs, "extra": 1}), "unknown key extra")
        pr = mutate(self.refs, ("source_pr", "fork"), "x")
        self.reject(block_of(pr), "unknown key fork")

    def test_duplicate_key(self):
        body = self.block.replace('"proposal_set_digest"',
                                  '"proposal_set_digest":"x","proposal_set_digest"')
        self.reject(body, "duplicate key")

    def test_second_marker_pair(self):
        self.reject(self.block + "\n" + self.block, "exactly one")
        self.reject(self.block + "\n" + OPEN, "exactly one")

    def test_empty_duplicate_unsorted_objects(self):
        for objects, reason in (
                ([], "non-empty"),
                ([self.refs["affected_objects"][0]] * 2, "sorted"),
                (list(reversed(self.refs["affected_objects"])), "sorted")):
            self.reject(block_of({**self.refs, "affected_objects": objects}), reason)

    def test_bad_hex_and_digest_shapes(self):
        for path, value in (
                (("source_head_sha",), "0" * 39),
                (("source_head_sha",), "0" * 64),
                (("assessment_receipt_digest",), "SHA256:" + "0" * 64),
                (("proposal_set_digest",), "sha256:" + "0" * 63),
                (("source_pr", "repository_id"), "0123"),
                (("source_pr", "number"), 0),
                (("source_pr", "number"), True)):
            self.reject(block_of(mutate(self.refs, path, value)), "invalid")

    def test_object_id_follows_adoc_grammar(self):
        for object_id in ("a-->b", "<script>", "a\nb", "Task.example", "task.Example",
                          "task\u2028.example", "task.\u200bexample", "task",
                          "task..example", "-task.example", "task.example-",
                          "task.ex_ample", "task.example."):
            objects = [{"object_id": object_id, "content_hash": "sha256:" + "1" * 64}]
            self.reject(block_of({**self.refs, "affected_objects": objects}), "object_id")

    def test_oversized_block(self):
        objects = [{"object_id": f"o.{i:06d}", "content_hash": "sha256:" + "1" * 64}
                   for i in range(1000)]
        with self.assertRaisesRegex(Invalid, "64 KiB"):
            refs_mod.render({**self.refs, "affected_objects": objects})
        self.reject(block_of({**self.refs, "affected_objects": objects}), "64 KiB")

    def test_non_canonical_bytes(self):
        pretty = f"{OPEN}\n{json.dumps(self.refs)}\n{CLOSE}"
        self.reject(pretty, "not canonical")
        reordered = dict(reversed(list(self.refs.items())))
        self.reject(block_of(reordered), "not canonical")
        self.reject(self.block.replace("\n", "\n\n", 1), "not canonical|invalid")
        self.reject(self.block.replace(OPEN + "\n", OPEN), "newline")

    def test_crlf_body_parses_and_attach_replaces(self):
        golden = (FIXTURES / "v0.block.txt").read_text()
        crlf = (FIXTURES / "v0.body-crlf.txt").read_bytes()
        self.assertIn(b"\r\n", crlf)
        parsed = cli("parse", str(FIXTURES / "v0.body-crlf.txt"))
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        self.assertEqual(parsed.stdout.decode(), golden.split("\n")[1] + "\n")
        self.assertEqual(refs_mod.render(refs_mod.parse(crlf.decode())), golden)
        attached = refs_mod.attach(crlf.decode(), self.block)
        self.assertEqual(attached.count(OPEN), 1)
        self.assertEqual(refs_mod.parse(attached), refs_mod.parse(self.block))
        self.reject(self.block.replace("\n", "\r", 1), "newline|not canonical")
        self.reject(self.block.replace('"source_pr"', '"source_pr"\r'), "not canonical|invalid")

    def test_attach_replaces_never_duplicates(self):
        other = refs_mod.render({**self.refs, "proposal_set_digest": "sha256:" + "9" * 64})
        body = "head\n\n" + other + "\n\ntail\n"
        self.assertEqual(refs_mod.attach(body, self.block),
                         "head\n\n" + self.block + "\n\ntail\n")
        with self.assertRaises(Invalid):
            refs_mod.attach(other + other, self.block)

    def test_cli_render_rejects_bad_number_and_objects(self):
        bad = list(GOLDEN_ARGS)
        bad[3] = "4x"
        self.assertEqual(cli("render", *bad).returncode, 65)
        self.assertEqual(cli("parse", stdin=b"nothing").returncode, 65)


if __name__ == "__main__":
    unittest.main()
