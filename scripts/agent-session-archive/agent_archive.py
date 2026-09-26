#!/usr/bin/env python3
"""Manifest, verification and cold-copy helper for the agent session archive (H2-45).

Why this exists
---------------
Historical AI-agent session transcripts are being consolidated from the M1 Max
onto OMV. The hard rule is: **nothing is deleted from the Mac until the copy is
verified**. "Verified" means a per-file manifest — path, byte size and sha256 —
with a zero diff between source and destination. That is this tool.

Design constraints
------------------
* stdlib only, so it runs unchanged on macOS (`/usr/bin/python3`), on the
  worker pod and in CI. No pip, no homebrew, no `aws` CLI.
* deterministic: the same tree always renders the same manifest bytes, so two
  runs can be diffed with `diff`/`cmp` as well as by this tool.
* non-destructive: there is no delete/remove/prune code path here at all. The
  only writes are the manifest files and, for `minio-put`, new S3 objects.

Subcommands
-----------
    manifest ROOT -o OUT [--exclude PATTERN]...
    verify SOURCE_MANIFEST DESTINATION_MANIFEST [--json]
    sqlite-snapshot --src LIVE_DB --out SNAPSHOT_DB
    minio-put --endpoint URL --bucket B --key K --file F
              [--create-bucket] [--dry-run] [--region REGION]
              [--access-key-env NAME] [--secret-key-env NAME]

Exit codes
----------
    0  success / manifests identical
    1  manifests differ (unverified copy)
    2  usage, I/O or authentication error
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import hmac
import http.client
import json
import os
import sqlite3
import sys
import urllib.parse
from datetime import datetime, timezone

# --------------------------------------------------------------------------
# Manifest generation
# --------------------------------------------------------------------------

#: Noise that must never enter a session manifest. `*-wal` / `*-shm` are the
#: SQLite sidecars: the live OpenCode DB is snapshotted with the online-backup
#: API first (`sqlite-snapshot`), so archiving the WAL is both useless and a
#: source of torn copies.
DEFAULT_EXCLUDES: tuple[str, ...] = (
    "__pycache__",
    "*.pyc",
    ".DS_Store",
    "*.tmp",
    "*.temp",
    "*-wal",
    "*-shm",
    ".cache",
    "node_modules",
    ".Trashes",
    ".Spotlight-V100",
    ".fseventsd",
)

CHUNK = 1024 * 1024


def _is_excluded(relpath: str, name: str, patterns: tuple[str, ...]) -> bool:
    return any(
        fnmatch.fnmatch(name, pattern) or fnmatch.fnmatch(relpath, pattern)
        for pattern in patterns
    )


def hash_file(path: str) -> tuple[str, int]:
    """Return (sha256 hex, byte count) for a regular file, in one pass."""
    digest = hashlib.sha256()
    size = 0
    with open(path, "rb") as handle:
        while True:
            block = handle.read(CHUNK)
            if not block:
                break
            size += len(block)
            digest.update(block)
    return digest.hexdigest(), size


def build_manifest(
    root: str,
    excludes: tuple[str, ...] = DEFAULT_EXCLUDES,
    warn=None,
) -> list[str]:
    """Render a sorted manifest for *root*.

    Each line is ``<sha256><2 spaces><bytes><2 spaces><relpath>`` with the
    relative path using '/' separators. Directories, symlinks and other
    non-regular files are skipped; a warning string is passed to *warn* for
    each symlink so a caller can insist on a human decision instead of
    silently ignoring one.
    """
    lines: list[str] = []
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        raise FileNotFoundError(f"not a directory: {root}")
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        keep: list[str] = []
        for name in sorted(dirnames):
            rel = name if rel_dir == "." else f"{rel_dir}/{name}"
            if _is_excluded(rel, name, excludes):
                continue
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                if warn:
                    warn(f"symlink directory skipped: {rel} -> {os.readlink(full)}")
                continue
            keep.append(name)
        dirnames[:] = keep
        for name in sorted(filenames):
            rel = name if rel_dir == "." else f"{rel_dir}/{name}"
            if _is_excluded(rel, name, excludes):
                continue
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                if warn:
                    warn(f"symlink skipped (not followed): {rel} -> {os.readlink(full)}")
                continue
            if not os.path.isfile(full):
                if warn:
                    warn(f"non-regular file skipped: {rel}")
                continue
            sha, size = hash_file(full)
            lines.append(f"{sha}  {size}  {rel}")
    lines.sort(key=lambda line: line.split("  ", 2)[2])
    return lines


def render_manifest(lines: list[str]) -> str:
    return "".join(f"{line}\n" for line in lines)


def parse_manifest_lines(
    lines, origin: str = "<manifest>"
) -> dict[str, tuple[str, int]]:
    """Turn rendered manifest lines into ``{relpath: (sha256, bytes)}``."""
    entries: dict[str, tuple[str, int]] = {}
    for lineno, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        if not line:
            continue
        parts = line.split("  ", 2)
        if len(parts) != 3 or len(parts[0]) != 64:
            raise ValueError(f"{origin}:{lineno}: malformed manifest line: {line!r}")
        sha, size, rel = parts
        try:
            entries[rel] = (sha, int(size))
        except ValueError as exc:
            raise ValueError(f"{origin}:{lineno}: bad size {size!r}") from exc
    return entries


def read_manifest(path: str) -> dict[str, tuple[str, int]]:
    with open(path, "r", encoding="utf-8") as handle:
        return parse_manifest_lines(handle, origin=path)


def compare_manifests(
    source: dict[str, tuple[str, int]],
    destination: dict[str, tuple[str, int]],
) -> list[str]:
    """Return one human-readable line per difference. Empty list == verified."""
    differences: list[str] = []
    for rel in sorted(source):
        if rel not in destination:
            differences.append(f"MISSING  {rel}")
            continue
        src_sha, src_size = source[rel]
        dst_sha, dst_size = destination[rel]
        if src_size != dst_size:
            differences.append(
                f"SIZE     {rel}  source={src_size} destination={dst_size}"
            )
        elif src_sha != dst_sha:
            differences.append(f"HASH     {rel}  {src_sha} -> {dst_sha}")
    for rel in sorted(destination):
        if rel not in source:
            differences.append(f"EXTRA    {rel}")
    return differences


def summarize(
    source: dict[str, tuple[str, int]],
    destination: dict[str, tuple[str, int]],
    differences: list[str],
) -> dict[str, object]:
    return {
        "source_files": len(source),
        "destination_files": len(destination),
        "source_bytes": sum(size for _, size in source.values()),
        "destination_bytes": sum(size for _, size in destination.values()),
        "differences": len(differences),
        "verified": not differences,
    }


# --------------------------------------------------------------------------
# SQLite snapshot (live DB -> consistent archive artefact)
# --------------------------------------------------------------------------


def sqlite_snapshot(src_path: str, out_path: str) -> None:
    """Write a transactionally consistent copy of *src_path* to *out_path*.

    A plain file copy of a WAL-mode database can capture a torn state; this uses
    SQLite's own online backup API so the snapshot is a valid database at a
    single point in time.
    """
    try:
        source = sqlite3.connect(f"file:{urllib.parse.quote(src_path)}?mode=ro", uri=True)
    except sqlite3.OperationalError:
        source = sqlite3.connect(src_path)
    try:
        destination = sqlite3.connect(out_path)
        try:
            source.backup(destination)
            destination.commit()
        finally:
            destination.close()
    finally:
        source.close()


# --------------------------------------------------------------------------
# AWS Signature Version 4 (S3 / MinIO)
# --------------------------------------------------------------------------


def _sha256_hex(data) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def _hmac(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def canonical_request(
    method: str,
    uri_path: str,
    query: str,
    headers: dict[str, str],
    signed_header_names: list[str],
    payload_sha256: str,
) -> str:
    canonical_headers = "".join(
        f"{name}:{headers[name]}\n" for name in signed_header_names
    )
    return "\n".join(
        [
            method,
            uri_path,
            query,
            canonical_headers,
            ";".join(signed_header_names),
            payload_sha256,
        ]
    )


def string_to_sign(
    amz_date: str,
    date_stamp: str,
    region: str,
    service: str,
    canonical: str,
) -> str:
    scope = f"{date_stamp}/{region}/{service}/aws4_request"
    return "\n".join(
        ["AWS4-HMAC-SHA256", amz_date, scope, _sha256_hex(canonical)]
    )


def signing_key(secret_key: str, date_stamp: str, region: str, service: str) -> bytes:
    key = _hmac(("AWS4" + secret_key).encode("utf-8"), date_stamp)
    key = _hmac(key, region)
    key = _hmac(key, service)
    return _hmac(key, "aws4_request")


def signature(
    secret_key: str,
    date_stamp: str,
    region: str,
    service: str,
    string_to_sign_value: str,
) -> str:
    return hmac.new(
        signing_key(secret_key, date_stamp, region, service),
        string_to_sign_value.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()


def authorization_header(
    access_key: str,
    date_stamp: str,
    region: str,
    service: str,
    signed_headers: str,
    signature_value: str,
) -> str:
    scope = f"{date_stamp}/{region}/{service}/aws4_request"
    return (
        "AWS4-HMAC-SHA256 "
        f"Credential={access_key}/{scope}, "
        f"SignedHeaders={signed_headers}, "
        f"Signature={signature_value}"
    )


def sign_request(
    method: str,
    url: str,
    payload_sha256: str,
    access_key: str,
    secret_key: str,
    content_length: int | None = None,
    region: str = "us-east-1",
    service: str = "s3",
    amz_date: str | None = None,
) -> dict[str, str]:
    """Return the headers (including Authorization) for a signed S3 request."""
    if amz_date is None:
        amz_date = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    date_stamp = amz_date[:8]
    parts = urllib.parse.urlsplit(url)
    headers = {
        "host": parts.netloc,
        "x-amz-content-sha256": payload_sha256,
        "x-amz-date": amz_date,
    }
    if content_length is not None:
        headers["content-length"] = str(content_length)
    signed = sorted(headers)
    creq = canonical_request(
        method,
        urllib.parse.quote(parts.path, safe="/-_.~"),
        parts.query,
        headers,
        signed,
        payload_sha256,
    )
    sts = string_to_sign(amz_date, date_stamp, region, service, creq)
    sig = signature(secret_key, date_stamp, region, service, sts)
    headers["authorization"] = authorization_header(
        access_key, date_stamp, region, service, ";".join(signed), sig
    )
    return headers


class MinioError(RuntimeError):
    pass


def _send(
    method: str,
    url: str,
    headers: dict[str, str],
    body=None,
    content_length: int | None = None,
) -> tuple[int, bytes]:
    parts = urllib.parse.urlsplit(url)
    if parts.scheme == "https":
        conn = http.client.HTTPSConnection(parts.netloc, timeout=300)
    else:
        conn = http.client.HTTPConnection(parts.netloc, timeout=300)
    path = parts.path or "/"
    if parts.query:
        path = f"{path}?{parts.query}"
    try:
        conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        for name in sorted(headers):
            conn.putheader(name, headers[name])
        if content_length is not None:
            conn.putheader("content-length", str(content_length))
            conn.endheaders()
            if body is not None and content_length:
                remaining = content_length
                while remaining > 0:
                    block = body.read(min(CHUNK, remaining))
                    if not block:
                        break
                    conn.send(block)
                    remaining -= len(block)
        else:
            conn.endheaders()
        response = conn.getresponse()
        return response.status, response.read()
    finally:
        conn.close()


def minio_put(
    endpoint: str,
    bucket: str,
    key: str,
    file_path: str,
    access_key: str,
    secret_key: str,
    create_bucket: bool = False,
    dry_run: bool = False,
    region: str = "us-east-1",
) -> int:
    endpoint = endpoint.rstrip("/")
    bucket_url = f"{endpoint}/{bucket}"
    object_url = f"{endpoint}/{bucket}/{urllib.parse.quote(key, safe='/')}"

    if dry_run:
        if create_bucket:
            print(f"DRY-RUN PUT {bucket_url}  (create bucket if absent)")
        print(f"DRY-RUN PUT {object_url}")
        print(f"DRY-RUN source file: {file_path}")
        print(f"DRY-RUN region: {region}")
        return 0

    if not access_key or not secret_key:
        raise MinioError(
            "no credentials supplied (set MINIO_ACCESS_KEY / MINIO_SECRET_KEY "
            "or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)"
        )

    if create_bucket:
        empty = _sha256_hex(b"")
        headers = sign_request(
            "PUT", bucket_url, empty, access_key, secret_key,
            content_length=0, region=region,
        )
        status, body = _send("PUT", bucket_url, headers, content_length=0)
        # 409 = BucketAlreadyOwnedByYou, which is exactly the desired end state.
        if status not in (200, 204, 409):
            raise MinioError(
                f"create bucket {bucket}: HTTP {status} {body[:400].decode('utf-8', 'replace')}"
            )
        print(f"bucket ready: {bucket} (HTTP {status})")

    size = os.path.getsize(file_path)
    payload_sha256, _ = hash_file(file_path)
    headers = sign_request(
        "PUT", object_url, payload_sha256, access_key, secret_key,
        content_length=size, region=region,
    )
    with open(file_path, "rb") as handle:
        status, body = _send(
            "PUT", object_url, headers, body=handle, content_length=size
        )
    if status not in (200, 204):
        raise MinioError(
            f"upload {key}: HTTP {status} {body[:400].decode('utf-8', 'replace')}"
        )
    print(f"uploaded {file_path} -> s3://{bucket}/{key} ({size} bytes, HTTP {status})")
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def _cmd_manifest(args) -> int:
    excludes = tuple(args.exclude) if args.exclude else DEFAULT_EXCLUDES

    def warn(message: str) -> None:
        print(f"WARN {message}", file=sys.stderr)

    lines = build_manifest(args.root, excludes=excludes, warn=warn)
    rendered = render_manifest(lines)
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(rendered)
    total_bytes = sum(int(line.split("  ", 2)[1]) for line in lines)
    print(f"manifest: {len(lines)} files, {total_bytes} bytes -> {args.output}")
    return 0


def _cmd_verify(args) -> int:
    source = read_manifest(args.source_manifest)
    destination = read_manifest(args.destination_manifest)
    differences = compare_manifests(source, destination)
    summary = summarize(source, destination, differences)
    if args.json:
        print(json.dumps({"differences_detail": differences, **summary}, indent=2))
    else:
        for line in differences:
            print(line)
        print(
            "summary: source_files={source_files} destination_files={destination_files} "
            "source_bytes={source_bytes} destination_bytes={destination_bytes} "
            "differences={differences}".format(**summary)
        )
    return 1 if differences else 0


def _cmd_sqlite_snapshot(args) -> int:
    sqlite_snapshot(args.src, args.out)
    sha, size = hash_file(args.out)
    print(f"snapshot: {args.src} -> {args.out} ({size} bytes, sha256 {sha})")
    return 0


def _env_lookup(names: list[str]) -> str:
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return ""


def _cmd_minio_put(args) -> int:
    access_key = ""
    secret_key = ""
    if not args.dry_run:
        access_key = _env_lookup([args.access_key_env, "MINIO_ACCESS_KEY", "AWS_ACCESS_KEY_ID"])
        secret_key = _env_lookup([args.secret_key_env, "MINIO_SECRET_KEY", "AWS_SECRET_ACCESS_KEY"])
    try:
        return minio_put(
            endpoint=args.endpoint,
            bucket=args.bucket,
            key=args.key,
            file_path=args.file,
            access_key=access_key,
            secret_key=secret_key,
            create_bucket=args.create_bucket,
            dry_run=args.dry_run,
            region=args.region,
        )
    except MinioError as exc:
        print(f"ERROR {exc}", file=sys.stderr)
        return 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="agent_archive.py",
        description="Manifest, verify and cold-copy helper for the agent session archive.",
    )
    sub = parser.add_subparsers(dest="command")

    p_manifest = sub.add_parser("manifest", help="render a sha256/size manifest for a directory")
    p_manifest.add_argument("root")
    p_manifest.add_argument("-o", "--output", required=True)
    p_manifest.add_argument(
        "--exclude", action="append", default=None,
        help="extra fnmatch pattern to exclude (repeatable)",
    )
    p_manifest.set_defaults(func=_cmd_manifest)

    p_verify = sub.add_parser("verify", help="compare two manifests; exit 1 on any difference")
    p_verify.add_argument("source_manifest")
    p_verify.add_argument("destination_manifest")
    p_verify.add_argument("--json", action="store_true")
    p_verify.set_defaults(func=_cmd_verify)

    p_snap = sub.add_parser("sqlite-snapshot", help="consistent copy of a live SQLite DB")
    p_snap.add_argument("--src", required=True)
    p_snap.add_argument("--out", required=True)
    p_snap.set_defaults(func=_cmd_sqlite_snapshot)

    p_put = sub.add_parser("minio-put", help="create bucket if asked and upload one file (SigV4)")
    p_put.add_argument("--endpoint", required=True)
    p_put.add_argument("--bucket", required=True)
    p_put.add_argument("--key", required=True)
    p_put.add_argument("--file", required=True)
    p_put.add_argument("--create-bucket", action="store_true")
    p_put.add_argument("--dry-run", action="store_true")
    p_put.add_argument("--region", default="us-east-1")
    p_put.add_argument("--access-key-env", default="MINIO_ACCESS_KEY")
    p_put.add_argument("--secret-key-env", default="MINIO_SECRET_KEY")
    p_put.set_defaults(func=_cmd_minio_put)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_usage(sys.stderr)
        return 2
    try:
        return args.func(args)
    except (FileNotFoundError, ValueError, OSError) as exc:
        print(f"ERROR {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
