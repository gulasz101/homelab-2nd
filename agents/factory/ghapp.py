#!/usr/bin/env python3
"""GitHub App token for the factory engine (GUL-2037 phase 4, decision 7).

The engine merges as the GitHub App `gulasz101-factory`, not as the owner's own
account, so a ruleset on `main` can tell the two apart. Standard library only:
the JWT is signed with `openssl`, because this host has no `cryptography`.

Where the key lives (never in the repo):
- the macOS keychain, generic password, service `factory-github-app`, account
  `<appId>`, value = the PEM file base64-encoded on one line;
- or `FACTORY_GH_APP_KEY_FILE` (a PEM file, tests only).

`installation_token(cfg, repo, state_dir)` returns a token scoped to that ONE
repository with contents + pull_requests write, or raises `AppError` with one
plain sentence. A missing key is `AppError` too: the caller treats every error
as "no auto-merge", never as a stall.
"""

import base64
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

KEYCHAIN_SERVICE = "factory-github-app"
TOKEN_PERMISSIONS = {"contents": "write", "pull_requests": "write"}


class AppError(Exception):
    pass


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def load_key(app_id) -> str:
    path = os.environ.get("FACTORY_GH_APP_KEY_FILE")
    if path:
        try:
            with open(path, "r", encoding="ascii") as fh:
                return fh.read()
        except OSError as exc:
            raise AppError("GitHub App key file unreadable: %s" % exc)
    service = os.environ.get("FACTORY_GH_APP_KEYCHAIN_SERVICE", KEYCHAIN_SERVICE)
    proc = subprocess.run(["security", "find-generic-password", "-s", service,
                           "-a", str(app_id), "-w"],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        raise AppError("no GitHub App key in the keychain (service %s, account %s)"
                       % (service, app_id))
    try:
        return base64.b64decode(proc.stdout.strip()).decode("ascii")
    except ValueError:
        raise AppError("the GitHub App key in the keychain is not base64")


def make_jwt(app_id, pem: str, now=None) -> str:
    now = int(now if now is not None else time.time())
    header = _b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
    # iat 60 s in the past against clock drift; GitHub allows at most 10 minutes
    payload = _b64url(json.dumps({"iat": now - 60, "exp": now + 540, "iss": str(app_id)},
                                 separators=(",", ":")).encode())
    signing_input = ("%s.%s" % (header, payload)).encode("ascii")
    tmp = tempfile.mkdtemp(prefix="ghapp-")
    try:
        os.chmod(tmp, 0o700)
        key_path = os.path.join(tmp, "k.pem")
        fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(pem)
        proc = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                              input=signing_input, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if proc.returncode != 0 or not proc.stdout:
        raise AppError("openssl could not sign the App JWT (exit %d)" % proc.returncode)
    return "%s.%s" % (signing_input.decode("ascii"), _b64url(proc.stdout))


def _api(method: str, path: str, bearer: str, body=None) -> dict:
    base = os.environ.get("FACTORY_GITHUB_API", "https://api.github.com").rstrip("/")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method, headers={
        "Authorization": "Bearer " + bearer, "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "factory-engine"})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        raise AppError("GitHub %s %s answered HTTP %d" % (method, path, exc.code))
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise AppError("GitHub %s %s failed: %s" % (method, path, exc))


def installation_token(cfg: dict, repo: str, state_dir: str) -> str:
    app = cfg.get("githubApp") or {}
    app_id = app.get("appId")
    if not app_id:
        raise AppError("engine.json has no githubApp.appId")
    cache = os.path.join(state_dir, "ghapp-token.json")
    try:
        with open(cache) as fh:
            cached = json.load(fh)
        if cached.get("repo") == repo and float(cached.get("expires", 0)) - time.time() > 300:
            return cached["token"]
    except (OSError, ValueError, KeyError):
        pass
    jwt = make_jwt(app_id, load_key(app_id))
    inst = _api("GET", "/repos/%s/installation" % repo, jwt)
    if not inst.get("id"):
        raise AppError("the GitHub App is not installed on %s" % repo)
    owner_repo = repo.split("/", 1)
    body = {"repositories": [owner_repo[1]], "permissions": TOKEN_PERMISSIONS}
    tok = _api("POST", "/app/installations/%s/access_tokens" % inst["id"], jwt, body)
    token = tok.get("token")
    if not token:
        raise AppError("GitHub returned no installation token")
    expires = time.time() + 3000  # GitHub gives 60 minutes; keep a margin
    os.makedirs(state_dir, exist_ok=True)
    fd = os.open(cache + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump({"repo": repo, "token": token, "expires": expires}, fh)
    os.replace(cache + ".tmp", cache)
    return token
