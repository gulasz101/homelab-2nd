#!/usr/bin/env python3
"""Tests for scripts/agent-session-archive/agent_archive.py (H2-45).

Run:
    python3 -m unittest discover -s scripts/agent-session-archive/tests -v

Everything here is stdlib-only and uses synthetic fixtures, so it runs on the
worker (Linux), on the Mac, and in CI. The SigV4 tests use the official AWS
Signature Version 4 test-suite vector `get-vanilla` (Apache-2.0, from
awslabs/aws-sig-v4-test-suite), which is an independent oracle for the exact
signing code path the MinIO upload uses.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "agent_archive.py"
RUNBOOK_PATH = Path(__file__).resolve().parents[1] / "run-on-mac.sh"


def _load_module():
    spec = importlib.util.spec_from_file_location("agent_archive", MODULE_PATH)
    if spec is None or spec.loader is None:  # pragma: no cover - defensive
        raise AssertionError(f"cannot load {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --------------------------------------------------------------------------
# AWS SigV4 `get-vanilla` official test vector.
# https://github.com/awslabs/aws-sig-v4-test-suite (Apache-2.0)
# --------------------------------------------------------------------------
VECTOR_ACCESS_KEY = "AKIDEXAMPLE"
VECTOR_SECRET_KEY = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
VECTOR_AMZ_DATE = "20150830T123600Z"
VECTOR_DATE_STAMP = "20150830"
VECTOR_REGION = "us-east-1"
VECTOR_SERVICE = "service"
VECTOR_HOST = "example.amazonaws.com"
VECTOR_EMPTY_SHA256 = (
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
)
VECTOR_CANONICAL_REQUEST = "\n".join(
    [
        "GET",
        "/",
        "",
        f"host:{VECTOR_HOST}",
        f"x-amz-date:{VECTOR_AMZ_DATE}",
        "",
        "host;x-amz-date",
        VECTOR_EMPTY_SHA256,
    ]
)
VECTOR_STRING_TO_SIGN = "\n".join(
    [
        "AWS4-HMAC-SHA256",
        VECTOR_AMZ_DATE,
        f"{VECTOR_DATE_STAMP}/{VECTOR_REGION}/{VECTOR_SERVICE}/aws4_request",
        "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63",
    ]
)
VECTOR_SIGNATURE = (
    "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
)
VECTOR_AUTHORIZATION = (
    "AWS4-HMAC-SHA256 "
    f"Credential={VECTOR_ACCESS_KEY}/{VECTOR_DATE_STAMP}/{VECTOR_REGION}/"
    f"{VECTOR_SERVICE}/aws4_request, "
    "SignedHeaders=host;x-amz-date, "
    f"Signature={VECTOR_SIGNATURE}"
)

# Accepted as-is; the Manifest/V erify suites below test everything else.
DEFAULT_EXCLUDES = ("__pycache__", "*.pyc", ".DS_Store", "*.tmp", "*-wal", "*-shm")


class FixtureMixin:
    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="h2-45-test-")
        self.addCleanup(shutil.rmtree, self._tmp, ignore_errors=True)

    def path(self, *parts):
        return Path(self._tmp, *parts)

    def write(self, rel, data, root=None):
        root = Path(root) if root else Path(self._tmp)
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(data, str):
            data = data.encode("utf-8")
        target.write_bytes(data)
        return target

    def tree(self, root, files):
        """files: {relpath: bytes|str}"""
        for rel, data in files.items():
            self.write(rel, data, root=root)


# --------------------------------------------------------------------------
class ManifestTests(FixtureMixin, unittest.TestCase):
    def test_lines_are_sha256_size_relpath_sorted(self):
        aa = _load_module()
        self.tree(
            self._tmp,
            {
                "b/second.jsonl": "two\n",
                "a/first.jsonl": "one\n",
                "root.jsonl": "root\n",
            },
        )
        lines = aa.build_manifest(self._tmp)
        self.assertEqual([line.split("  ", 2)[2] for line in lines], [
            "a/first.jsonl",
            "b/second.jsonl",
            "root.jsonl",
        ])
        sha, size, rel = lines[1].split("  ", 2)
        self.assertEqual(len(sha), 64)
        self.assertEqual(rel, "b/second.jsonl")
        self.assertEqual(int(size), len(b"two\n"))
        self.assertEqual(sha, hashlib.sha256(b"two\n").hexdigest())

    def test_manifest_is_byte_for_byte_deterministic(self):
        aa = _load_module()
        self.tree(self._tmp, {"x/a": "a", "x/b": "b", "y/c": "c"})
        first = aa.render_manifest(aa.build_manifest(self._tmp))
        second = aa.render_manifest(aa.build_manifest(self._tmp))
        self.assertEqual(first, second)

    def test_manifest_excludes_noise(self):
        aa = _load_module()
        self.tree(
            self._tmp,
            {
                "keep.jsonl": "keep",
                ".DS_Store": "junk",
                "session.tmp": "junk",
                "opencode.db-wal": "junk",
                "opencode.db-shm": "junk",
                "sub/__pycache__/x.pyc": "junk",
            },
        )
        rels = [line.split("  ", 2)[2] for line in aa.build_manifest(self._tmp)]
        self.assertEqual(rels, ["keep.jsonl"])

    def test_one_byte_change_changes_the_hash(self):
        aa = _load_module()
        self.tree(self._tmp, {"s/a.jsonl": "AAAA"})
        before = aa.build_manifest(self._tmp)
        self.write("s/a.jsonl", "AAAB")
        after = aa.build_manifest(self._tmp)
        self.assertNotEqual(before, after)
        self.assertEqual(before[0].split("  ")[1], after[0].split("  ")[1])

    def test_empty_tree_yields_empty_manifest(self):
        aa = _load_module()
        self.assertEqual(aa.build_manifest(self._tmp), [])

    def test_symlinks_are_reported_not_followed(self):
        aa = _load_module()
        self.tree(self._tmp, {"real.jsonl": "real"})
        os.symlink(self.path("real.jsonl"), self.path("link.jsonl"))
        warnings = []
        lines = aa.build_manifest(self._tmp, warn=warnings.append)
        self.assertEqual([line.split("  ", 2)[2] for line in lines], ["real.jsonl"])
        self.assertEqual(len(warnings), 1)
        self.assertIn("link.jsonl", warnings[0])


# --------------------------------------------------------------------------
class VerifyTests(FixtureMixin, unittest.TestCase):
    def _manifests(self, source_files, dest_files):
        src_root = self.path("src")
        dst_root = self.path("dst")
        src_root.mkdir(parents=True, exist_ok=True)
        dst_root.mkdir(parents=True, exist_ok=True)
        self.tree(src_root, source_files)
        self.tree(dst_root, dest_files)
        aa = _load_module()
        return (
            aa,
            aa.parse_manifest_lines(aa.build_manifest(src_root)),
            aa.parse_manifest_lines(aa.build_manifest(dst_root)),
        )

    def test_identical_trees_produce_no_differences(self):
        aa, src, dst = self._manifests({"a/one": "1", "b/two": "2"}, {"a/one": "1", "b/two": "2"})
        self.assertEqual(aa.compare_manifests(src, dst), [])

    def test_missing_destination_file_is_a_difference(self):
        aa, src, dst = self._manifests({"a/one": "1", "b/two": "2"}, {"a/one": "1"})
        diffs = aa.compare_manifests(src, dst)
        self.assertEqual(len(diffs), 1)
        self.assertTrue(diffs[0].startswith("MISSING"))
        self.assertIn("b/two", diffs[0])

    def test_extra_destination_file_is_a_difference(self):
        aa, src, dst = self._manifests({"a/one": "1"}, {"a/one": "1", "a/ghost": "x"})
        diffs = aa.compare_manifests(src, dst)
        self.assertEqual(len(diffs), 1)
        self.assertTrue(diffs[0].startswith("EXTRA"))
        self.assertIn("a/ghost", diffs[0])

    def test_size_difference_is_a_difference(self):
        aa, src, dst = self._manifests({"a/one": "1234"}, {"a/one": "12345"})
        diffs = aa.compare_manifests(src, dst)
        self.assertEqual(len(diffs), 1)
        self.assertTrue(diffs[0].startswith("SIZE"))

    def test_same_size_different_content_is_a_hash_difference(self):
        aa, src, dst = self._manifests({"a/one": "1234"}, {"a/one": "1235"})
        diffs = aa.compare_manifests(src, dst)
        self.assertEqual(len(diffs), 1)
        self.assertTrue(diffs[0].startswith("HASH"))

    def test_summary_counts_files_and_bytes(self):
        aa, src, dst = self._manifests({"a/one": "1234"}, {"a/one": "1234"})
        summary = aa.summarize(src, dst, aa.compare_manifests(src, dst))
        self.assertEqual(summary["source_files"], 1)
        self.assertEqual(summary["destination_files"], 1)
        self.assertEqual(summary["source_bytes"], 4)
        self.assertEqual(summary["differences"], 0)


# --------------------------------------------------------------------------
class SigV4Tests(unittest.TestCase):
    def test_canonical_request_matches_aws_get_vanilla(self):
        aa = _load_module()
        creq = aa.canonical_request(
            "GET",
            "/",
            "",
            {"host": VECTOR_HOST, "x-amz-date": VECTOR_AMZ_DATE},
            ["host", "x-amz-date"],
            VECTOR_EMPTY_SHA256,
        )
        self.assertEqual(creq.rstrip("\n"), VECTOR_CANONICAL_REQUEST)

    def test_string_to_sign_matches_aws_get_vanilla(self):
        aa = _load_module()
        sts = aa.string_to_sign(
            VECTOR_AMZ_DATE,
            VECTOR_DATE_STAMP,
            VECTOR_REGION,
            VECTOR_SERVICE,
            VECTOR_CANONICAL_REQUEST,
        )
        self.assertEqual(sts, VECTOR_STRING_TO_SIGN)

    def test_signature_matches_aws_get_vanilla(self):
        aa = _load_module()
        sig = aa.signature(
            VECTOR_SECRET_KEY,
            VECTOR_DATE_STAMP,
            VECTOR_REGION,
            VECTOR_SERVICE,
            VECTOR_STRING_TO_SIGN,
        )
        self.assertEqual(sig, VECTOR_SIGNATURE)

    def test_authorization_header_matches_aws_get_vanilla(self):
        aa = _load_module()
        header = aa.authorization_header(
            VECTOR_ACCESS_KEY,
            VECTOR_DATE_STAMP,
            VECTOR_REGION,
            VECTOR_SERVICE,
            "host;x-amz-date",
            VECTOR_SIGNATURE,
        )
        self.assertEqual(header, VECTOR_AUTHORIZATION)

    def test_signed_put_object_headers(self):
        aa = _load_module()
        headers = aa.sign_request(
            method="PUT",
            url="http://openmediavault.local:9000/agent-session-archive/opencode/opencode.tar.zst",
            payload_sha256=VECTOR_EMPTY_SHA256,
            content_length=0,
            access_key=VECTOR_ACCESS_KEY,
            secret_key=VECTOR_SECRET_KEY,
            amz_date=VECTOR_AMZ_DATE,
        )
        self.assertEqual(headers["host"], "openmediavault.local:9000")
        self.assertEqual(headers["x-amz-content-sha256"], VECTOR_EMPTY_SHA256)
        self.assertEqual(headers["x-amz-date"], VECTOR_AMZ_DATE)
        self.assertIn("content-length", headers["authorization"].lower())
        self.assertTrue(headers["authorization"].startswith("AWS4-HMAC-SHA256 "))
        self.assertIn("SignedHeaders=content-length;host;x-amz-content-sha256;x-amz-date",
                      headers["authorization"])


# --------------------------------------------------------------------------
class CliTests(FixtureMixin, unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, str(MODULE_PATH), *args],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_manifest_then_verify_roundtrip_exits_zero(self):
        src = self.path("src")
        dst = self.path("dst")
        self.tree(src, {"a/one": "1", "b/two": "22"})
        self.tree(dst, {"a/one": "1", "b/two": "22"})
        src_manifest = self.path("src.manifest")
        dst_manifest = self.path("dst.manifest")
        r1 = self.run_cli("manifest", str(src), "-o", str(src_manifest))
        r2 = self.run_cli("manifest", str(dst), "-o", str(dst_manifest))
        self.assertEqual(r1.returncode, 0, r1.stderr)
        self.assertEqual(r2.returncode, 0, r2.stderr)
        r3 = self.run_cli("verify", str(src_manifest), str(dst_manifest))
        self.assertEqual(r3.returncode, 0, r3.stdout + r3.stderr)
        self.assertIn("differences=0", r3.stdout)

    def test_verify_exits_one_on_any_difference(self):
        src_manifest = self.path("s.manifest")
        dst_manifest = self.path("d.manifest")
        src_manifest.write_text(
            f"{'a' * 64}  4  a/one\n{'b' * 64}  5  b/two\n", encoding="utf-8"
        )
        dst_manifest.write_text(f"{'a' * 64}  4  a/one\n", encoding="utf-8")
        r = self.run_cli("verify", str(src_manifest), str(dst_manifest))
        self.assertEqual(r.returncode, 1)
        self.assertIn("MISSING", r.stdout)
        self.assertIn("b/two", r.stdout)

    def test_verify_json_mode(self):
        src_manifest = self.path("s.manifest")
        dst_manifest = self.path("d.manifest")
        src_manifest.write_text(f"{'a' * 64}  4  a/one\n", encoding="utf-8")
        dst_manifest.write_text(f"{'a' * 64}  4  a/one\n", encoding="utf-8")
        r = self.run_cli("verify", str(src_manifest), str(dst_manifest), "--json")
        self.assertEqual(r.returncode, 0)
        payload = json.loads(r.stdout)
        self.assertEqual(payload["differences"], 0)

    def test_minio_put_dry_run_needs_no_credentials(self):
        target = self.path("payload.tar.gz")
        target.write_bytes(b"x" * 16)
        env = {k: v for k, v in os.environ.items()
               if k not in ("MINIO_ACCESS_KEY", "MINIO_SECRET_KEY",
                            "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")}
        r = subprocess.run(
            [
                sys.executable, str(MODULE_PATH), "minio-put",
                "--endpoint", "http://openmediavault.local:9000",
                "--bucket", "agent-session-archive",
                "--key", "claude-code/claude-code.tar.gz",
                "--file", str(target),
                "--create-bucket", "--dry-run",
            ],
            capture_output=True, text=True, check=False, env=env,
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("DRY-RUN PUT http://openmediavault.local:9000/agent-session-archive", r.stdout)
        self.assertIn("claude-code/claude-code.tar.gz", r.stdout)

    def test_usage_error_exits_two(self):
        r = self.run_cli("manifest")
        self.assertEqual(r.returncode, 2)


# --------------------------------------------------------------------------
class SqliteSnapshotTests(FixtureMixin, unittest.TestCase):
    def test_snapshot_of_a_wal_database_is_consistent(self):
        aa = _load_module()
        db = self.path("live.db")
        conn = sqlite3.connect(db)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE sessions (id INTEGER PRIMARY KEY, body TEXT)")
        conn.execute("INSERT INTO sessions (body) VALUES ('before-checkpoint')")
        conn.commit()
        # Keep a writer open and a WAL present: a plain file copy here is torn.
        conn.execute("INSERT INTO sessions (body) VALUES ('in-wal')")
        conn.commit()
        out = self.path("snapshot.db")
        aa.sqlite_snapshot(str(db), str(out))
        conn.close()
        snap = sqlite3.connect(out)
        try:
            rows = [r[0] for r in snap.execute("SELECT body FROM sessions ORDER BY id")]
        finally:
            snap.close()
        self.assertEqual(rows, ["before-checkpoint", "in-wal"])


# --------------------------------------------------------------------------
class RunbookGuardTests(unittest.TestCase):
    """AC 4: the mechanical path must not be able to delete anything."""

    def test_runbook_exists_and_never_deletes(self):
        self.assertTrue(RUNBOOK_PATH.exists(), f"{RUNBOOK_PATH} is missing")
        text = RUNBOOK_PATH.read_text(encoding="utf-8")
        self.assertNotIn("--delete", text)
        self.assertNotIn("--remove-source-files", text)
        for line in text.splitlines():
            code = line.split("#", 1)[0]
            self.assertNotRegex(code, r"\brm\s", f"deletion in runbook: {line!r}")
            self.assertNotRegex(code, r"\bunlink\b")
            self.assertNotRegex(code, r"\bshred\b")


if __name__ == "__main__":
    unittest.main(verbosity=2)
