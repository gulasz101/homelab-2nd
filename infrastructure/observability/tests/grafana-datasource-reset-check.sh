#!/usr/bin/env bash
# Static check for the Grafana datasource-reset work order (GUL-1693, red stage
# GUL-1700). Grafana refuses to provision a datasource whose uid is pinned and
# already exists ("datasource with same uid already exists"), so the provisioning
# document must first delete the four provisioned datasources by name, then
# re-create them with the uids the dashboards hard-code.
#
# No cluster, no network, no PyYAML, no yq: the HelmRelease is read as text by the
# same small indentation parser the OTel checks use, and AC-3 reads git.
#
# What the acceptance criteria mean here (GUL-1693 spec):
#   AC-1 spec.values.datasources["datasources.yaml"] carries a top-level
#        deleteDatasources list - a sibling of apiVersion and datasources -
#        naming exactly Prometheus, Loki, Tempo and InfluxDB, each with orgId: 1
#   AC-2 the pinned uids still read PBFA97CFB590B2093 (Prometheus),
#        P8E80F9AEF21F6940 (Loki) and tempo (Tempo), and every name in
#        deleteDatasources is also a provisioned datasource (otherwise Grafana
#        deletes a name it never recreates and the datasource disappears)
#   AC-3 against the base commit the diff of the Grafana HelmRelease adds the
#        deleteDatasources block and removes no line, so the chart pin 12.7.1 and
#        every existing datasource entry survive
#
# AC-3 tolerates one thing the spec's wording does not spell out: a base
# datasource that had NO uid may gain one (InfluxDB carries none today), because
# pinning it touches no existing line. A uid that existed in the base commit must
# come back unchanged, and any removal at all is a FAIL.
#
# Fixtures for the parser and the git diff are generated at run time by
# `fixture_text()` - `--self-test` runs AC-1/AC-2/AC-3 over a green fixture and
# several broken ones, so a broken parser cannot masquerade as a red stage. The
# plain command (what the spec's `check` runs) prints AC lines only.
#
# Protocol (agents/factory/CONTRACT.md point 2): one `AC-n: PASS|FAIL <reason>`
# line per acceptance criterion, exit 0 only when all three pass.
#
# Usage: bash infrastructure/observability/tests/grafana-datasource-reset-check.sh
#        bash infrastructure/observability/tests/grafana-datasource-reset-check.sh --self-test
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
MANIFEST_REL="infrastructure/observability/grafana-helm-release.yaml"
# The commit the work order's branch was cut from (GUL-1693 ledger baseSha).
# GUL1693_BASE_SHA overrides it; when neither resolves, the check resolves the
# cut point with `git merge-base HEAD origin/main` and fails honestly if it cannot.
BASE_SHA_DEFAULT="06636e63fb03fb75d155316c65369e6c51b4f303"

python3 -I - "$ROOT" "$MANIFEST_REL" "$BASE_SHA_DEFAULT" "$@" <<'PY'
import os
import re
import subprocess
import sys
import tempfile
import shutil

ROOT = sys.argv[1]
MANIFEST_REL = sys.argv[2]
BASE_SHA = os.environ.get("GUL1693_BASE_SHA") or sys.argv[3]
ARGS = sys.argv[4:]

MANIFEST = os.path.join(ROOT, MANIFEST_REL)
RESET_NAMES = ["Prometheus", "Loki", "Tempo", "InfluxDB"]
PINNED_UIDS = {
    "Prometheus": "PBFA97CFB590B2093",
    "Loki": "P8E80F9AEF21F6940",
    "Tempo": "tempo",
}
CHART_PIN = "12.7.1"
MISSING = object()


class YamlError(Exception):
    pass


# ------------------------------------------------------- stdlib-only YAML subset
# Same parser shape as infrastructure/observability/tests/signal-correlation-check.sh:
# block maps, block sequences, flow lists/maps, block scalars. Enough for the
# HelmRelease documents in this repo and for the fixtures below.

def strip_comment(line):
    out = []
    quote = None
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
            out.append(ch)
        elif ch == "#" and (not out or out[-1] in " \t"):
            break
        else:
            out.append(ch)
    return "".join(out).rstrip()


def split_kv(text):
    """Split `key: value` on the first colon followed by space or end of line."""
    quote = None
    for idx, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
        elif ch == ":" and (idx + 1 == len(text) or text[idx + 1] == " "):
            return text[:idx].strip(), text[idx + 1:].strip()
    return None, None


def unquote(text):
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        return text[1:-1]
    return text


def split_flow(text):
    parts = []
    depth = 0
    quote = None
    cur = []
    for ch in text:
        if quote:
            cur.append(ch)
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
            cur.append(ch)
        elif ch in "[{":
            depth += 1
            cur.append(ch)
        elif ch in "]}":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        parts.append("".join(cur).strip())
    return parts


def scalar(text):
    t = text.strip()
    if t.startswith("[") and t.endswith("]"):
        inner = t[1:-1].strip()
        return [] if not inner else [scalar(x) for x in split_flow(inner)]
    if t.startswith("{") and t.endswith("}"):
        inner = t[1:-1].strip()
        if not inner:
            return {}
        out = {}
        for part in split_flow(inner):
            k, v = split_kv(part)
            if k is None:
                out[scalar(part)] = None
            else:
                out[unquote(k)] = None if v == "" else scalar(v)
        return out
    if t in ("true", "True", "yes", "on"):
        return True
    if t in ("false", "False", "no", "off"):
        return False
    if t in ("null", "Null", "~", ""):
        return None
    if re.fullmatch(r"-?[0-9]+", t):
        return int(t)
    return unquote(t)


def tokenize(text):
    toks = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip("\r")
        if line.strip() in ("---", "..."):
            continue
        stripped = strip_comment(line)
        if not stripped.strip():
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        toks.append((indent, stripped.strip(), lineno))
    return toks


def parse_block(toks, i, indent):
    if i >= len(toks):
        return None, i
    if toks[i][1] == "-" or toks[i][1].startswith("- "):
        return parse_seq(toks, i, indent)
    return parse_map(toks, i, indent)


def parse_map(toks, i, indent):
    out = {}
    while i < len(toks):
        col, text, lineno = toks[i]
        if col < indent:
            break
        if col > indent:
            raise YamlError("line %d: unexpected indent in %r" % (lineno, text))
        if text == "-" or text.startswith("- "):
            break
        key, val = split_kv(text)
        if key is None:
            raise YamlError("line %d: expected `key: value`, got %r" % (lineno, text))
        key = unquote(key)
        i += 1
        if val == "":
            if i < len(toks) and toks[i][0] > indent:
                out[key], i = parse_block(toks, i, toks[i][0])
            elif i < len(toks) and toks[i][0] == indent and (toks[i][1] == "-" or toks[i][1].startswith("- ")):
                out[key], i = parse_seq(toks, i, indent)
            else:
                out[key] = None
        elif val in ("|", ">", "|-", ">-", "|+", ">+"):
            parts = []
            while i < len(toks) and toks[i][0] > indent:
                parts.append(toks[i][1])
                i += 1
            out[key] = "\n".join(parts)
        else:
            out[key] = scalar(val)
    return out, i


def parse_seq(toks, i, indent):
    out = []
    while i < len(toks):
        col, text, lineno = toks[i]
        if col != indent or not (text == "-" or text.startswith("- ")):
            break
        rest = text[1:].strip()
        i += 1
        if rest == "":
            if i < len(toks) and toks[i][0] > indent:
                val, i = parse_block(toks, i, toks[i][0])
            else:
                val = None
            out.append(val)
            continue
        key, val = split_kv(rest)
        if key is None:
            out.append(scalar(rest))
            continue
        item = {}
        if val == "":
            if i < len(toks) and toks[i][0] > indent:
                item[unquote(key)], i = parse_block(toks, i, toks[i][0])
            else:
                item[unquote(key)] = None
        else:
            item[unquote(key)] = scalar(val)
        while i < len(toks) and toks[i][0] > indent:
            more, i = parse_map(toks, i, toks[i][0])
            if not isinstance(more, dict):
                break
            item.update(more)
        out.append(item)
    return out, i


def load_text(text, label="document"):
    toks = tokenize(text)
    if not toks:
        raise YamlError("%s is empty" % label)
    doc, _ = parse_block(toks, 0, toks[0][0])
    if not isinstance(doc, dict):
        raise YamlError("%s does not start with a mapping" % label)
    return doc


def load_file(path):
    with open(path, encoding="utf-8") as fh:
        return load_text(fh.read(), os.path.basename(path))


def dig(node, *keys):
    cur = node
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            return MISSING
        cur = cur[key]
    return cur


def fmt(value):
    if value is MISSING:
        return "<missing>"
    return repr(value)


def provision_block(doc):
    """spec.values.datasources["datasources.yaml"] - the Grafana provisioning document."""
    values = dig(doc, "spec", "values")
    if values is MISSING or not isinstance(values, dict):
        raise YamlError("%s has no spec.values mapping" % MANIFEST_REL)
    return dig(values, "datasources", "datasources.yaml")


def datasource_entries(block):
    """The provisioned datasources as a list of mappings, keyed by name."""
    listed = dig(block, "datasources")
    if not isinstance(listed, list):
        return []
    return [entry for entry in listed if isinstance(entry, dict)]


# ---------------------------------------------------------------- AC-1
def ac1(block):
    problems = []
    if block is MISSING:
        return ["no provisioning document at spec.values.datasources['datasources.yaml']"]
    if not isinstance(block, dict):
        return ["spec.values.datasources['datasources.yaml'] is %s, not a mapping" % fmt(block)]
    if "apiVersion" not in block:
        problems.append("the provisioning document has no apiVersion next to deleteDatasources")
    if not isinstance(dig(block, "datasources"), list):
        problems.append("the provisioning document has no datasources list next to deleteDatasources")

    deleted = dig(block, "deleteDatasources")
    if deleted is MISSING:
        return problems + [
            "no top-level deleteDatasources list beside apiVersion and datasources, "
            "so Grafana keeps the existing datasource and aborts the pinned-uid provisioning"
        ]
    if not isinstance(deleted, list):
        return problems + ["deleteDatasources is %s, not a list of {name, orgId}" % fmt(deleted)]

    names = []
    for idx, entry in enumerate(deleted):
        if not isinstance(entry, dict):
            problems.append("deleteDatasources[%d] is %s, not a {name, orgId} mapping" % (idx, fmt(entry)))
            continue
        name = entry.get("name", MISSING)
        if not isinstance(name, str) or not name:
            problems.append("deleteDatasources[%d] has name %s" % (idx, fmt(name)))
            continue
        names.append(name)
        org = entry.get("orgId", MISSING)
        if org != 1:
            problems.append("deleteDatasources[%d] (%s) has orgId %s, want 1"
                            % (idx, name, fmt(org)))

    missing = [name for name in RESET_NAMES if name not in names]
    extra = [name for name in names if name not in RESET_NAMES]
    dupes = sorted(name for name in set(names) if names.count(name) > 1)
    if missing:
        problems.append("deleteDatasources does not name %s" % ", ".join(missing))
    if extra:
        problems.append("deleteDatasources names %s, which is not one of the four provisioned "
                        "datasources" % ", ".join(extra))
    if dupes:
        problems.append("deleteDatasources names %s more than once" % ", ".join(dupes))
    if not deleted:
        problems.append("deleteDatasources is an empty list, so nothing is reset before re-provisioning")
    return problems


# ---------------------------------------------------------------- AC-2
def ac2(block):
    problems = []
    if block is MISSING or not isinstance(block, dict):
        return ["no provisioning document, so no datasource uid is pinned at all"]
    entries = datasource_entries(block)
    by_name = {}
    for entry in entries:
        name = entry.get("name")
        if isinstance(name, str) and name:
            by_name.setdefault(name, entry)

    for name in RESET_NAMES:
        if name not in PINNED_UIDS:
            continue
        want = PINNED_UIDS[name]
        entry = by_name.get(name)
        if entry is None:
            problems.append("no provisioned datasource named %s, so the pinned uid %s the dashboards "
                            "query has nowhere to come from" % (name, want))
            continue
        uid = entry.get("uid", MISSING)
        if uid != want:
            problems.append("%s uid is %s, want %s - every dashboard panel hard-codes it"
                            % (name, fmt(uid), repr(want)))

    deleted = dig(block, "deleteDatasources")
    if not isinstance(deleted, list) or not deleted:
        return problems + [
            "no deleteDatasources list, so nothing reconciles the pinned uids against the "
            "datasources Grafana already holds"
        ]
    for idx, entry in enumerate(deleted):
        name = entry.get("name", MISSING) if isinstance(entry, dict) else MISSING
        if not isinstance(name, str) or not name:
            problems.append("deleteDatasources[%d] has no name to match against a provisioned datasource" % idx)
            continue
        if name not in by_name:
            problems.append("deleteDatasources names %r but no provisioned datasource has that name, "
                            "so Grafana would delete a datasource it never recreates" % name)
    return problems


# ---------------------------------------------------------------- AC-3
def git(repo, *args):
    proc = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


def resolve_base(repo, sha):
    if sha:
        rc, out, _ = git(repo, "rev-parse", "--verify", "--quiet", sha + "^{commit}")
        if rc == 0 and out.strip():
            return out.strip(), None
    for candidate in ("origin/main", "main"):
        rc, out, _ = git(repo, "merge-base", "HEAD", candidate)
        if rc == 0 and out.strip():
            return out.strip(), None
    return None, ("cannot resolve the base commit: %r is not in this checkout and neither "
                  "origin/main nor main has a merge base with HEAD" % sha)


def diff_lines(diff_text):
    added, removed = [], []
    for line in diff_text.splitlines():
        if line.startswith("---") or line.startswith("+++"):
            continue
        if line.startswith("-"):
            removed.append(line[1:])
            continue
        if line.startswith("+"):
            added.append(line[1:])
            continue
    return added, removed


def ac3(repo, base, rel):
    base, base_error = resolve_base(repo, base)
    if base is None:
        return [base_error]
    problems = []

    rc, diff_text, err = git(repo, "diff", "--unified=0", base, "--", rel)
    if rc != 0:
        return ["git diff against %s failed for %s: %s" % (base[:12], rel, (err or "").strip() or "no output")]
    added, removed = diff_lines(diff_text)

    if not any(line.strip().startswith("deleteDatasources:") for line in added):
        problems.append("the diff against %s adds no deleteDatasources line to %s"
                        % (base[:12], rel))
    added_text = "\n".join(added)
    for name in RESET_NAMES:
        if not re.search(r"name:\s*['\"]?" + re.escape(name) + r"['\"]?\s*(,|$)", added_text, re.MULTILINE):
            problems.append("the diff against %s does not add a deleteDatasources entry for %s"
                            % (base[:12], name))
    if removed:
        problems.append("the diff against %s removes %d line(s) of %s, first %r - existing "
                        "datasource entries and the chart pin must stay"
                        % (base[:12], len(removed), rel, removed[0].strip()))

    path = os.path.join(repo, rel)
    try:
        head_doc = load_file(path)
    except (YamlError, OSError) as exc:
        return problems + ["cannot read the new %s: %s" % (rel, exc)]
    version = dig(head_doc, "spec", "chart", "spec", "version")
    if str(version) != CHART_PIN:
        problems.append("chart pin is %s, want %r" % (fmt(version), CHART_PIN))

    rc, base_text, err = git(repo, "show", "%s:%s" % (base, rel))
    if rc != 0:
        return problems + ["cannot read %s at %s: %s"
                           % (rel, base[:12], (err or "").strip() or "no output")]
    try:
        base_doc = load_text(base_text, "%s at %s" % (rel, base[:12]))
    except YamlError as exc:
        return problems + ["cannot parse %s at %s: %s" % (rel, base[:12], exc)]

    base_block = provision_block(base_doc)
    head_block = provision_block(head_doc)
    base_by_name = {}
    for entry in datasource_entries(base_block):
        name = entry.get("name")
        if isinstance(name, str) and name:
            base_by_name[name] = entry
    head_by_name = {}
    for entry in datasource_entries(head_block):
        name = entry.get("name")
        if isinstance(name, str) and name:
            head_by_name[name] = entry

    for name in sorted(base_by_name):
        old = base_by_name[name]
        new = head_by_name.get(name)
        if new is None:
            problems.append("base datasource %r is gone from the new %s" % (name, rel))
            continue
        for key in ("type", "url"):
            if old.get(key, MISSING) != new.get(key, MISSING):
                problems.append("%s %s changed from %s to %s"
                                % (name, key, fmt(old.get(key, MISSING)), fmt(new.get(key, MISSING))))
        old_uid = old.get("uid", MISSING)
        if old_uid is not MISSING and old_uid != new.get("uid", MISSING):
            problems.append("%s uid changed from %s to %s, which blinds every dashboard panel "
                            "that hard-codes it" % (name, fmt(old_uid), fmt(new.get("uid", MISSING))))
    return problems


# ---------------------------------------------------------------- fixtures
def fixture_text(with_delete=True, delete_names=None, delete_org_id=1,
                 prom_uid=PINNED_UIDS["Prometheus"], loki_uid=PINNED_UIDS["Loki"],
                 tempo_uid=PINNED_UIDS["Tempo"], chart=CHART_PIN, influx_uid=None):
    """One HelmRelease document in the shape the real file has.

    Generated here instead of committed: every broken variation the self-test
    needs comes from the same builder.
    """
    names = RESET_NAMES if delete_names is None else delete_names
    lines = [
        "---",
        "apiVersion: helm.toolkit.fluxcd.io/v2",
        "kind: HelmRelease",
        "metadata:",
        "  name: grafana",
        "  namespace: observability",
        "spec:",
        "  interval: 1h",
        "  chart:",
        "    spec:",
        "      chart: grafana",
        '      version: "%s"' % chart,
        "      sourceRef:",
        "        kind: HelmRepository",
        "        name: grafana-community",
        "        namespace: flux-system",
        "  values:",
        "    # comment inside values, ignored by the parser",
        "    datasources:",
        "      datasources.yaml:",
        "        apiVersion: 1",
    ]
    if with_delete:
        lines.append("        deleteDatasources:")
        for name in names:
            lines.append("          - name: %s" % name)
            lines.append("            orgId: %d" % delete_org_id)
    lines += [
        "        datasources:",
        "          - name: Prometheus",
        "            type: prometheus",
        "            uid: %s" % prom_uid,
        "            url: http://prometheus:9090",
        "            access: proxy",
        "            isDefault: true",
        "          - name: Loki",
        "            type: loki",
        "            uid: %s" % loki_uid,
        "            url: http://loki:80",
        "            access: proxy",
        "          - name: Tempo",
        "            type: tempo",
        "            uid: %s" % tempo_uid,
        "            url: http://tempo:3200",
        "            access: proxy",
        "          - name: InfluxDB",
        "            type: influxdb",
        "            url: http://influxdb:80",
        "            access: proxy",
        "            jsonData:",
        "              version: Flux",
    ]
    if influx_uid:
        lines.append("            uid: %s" % influx_uid)
    return "\n".join(lines) + "\n"


def block_of(text):
    return provision_block(load_text(text, "fixture"))


def self_test():
    """Assert AC-1/AC-2/AC-3 accept the green shape and reject the broken ones."""
    failures = []
    checks = []

    def case(label, problems, want_problems):
        ok = bool(problems) == want_problems
        checks.append((label, ok, problems))
        if not ok:
            failures.append(label)

    case("green fixture passes AC-1", ac1(block_of(fixture_text())), False)
    case("green fixture passes AC-2", ac2(block_of(fixture_text())), False)
    case("no deleteDatasources fails AC-1", ac1(block_of(fixture_text(with_delete=False))), True)
    case("no deleteDatasources fails AC-2", ac2(block_of(fixture_text(with_delete=False))), True)
    case("orgId 2 fails AC-1",
         ac1(block_of(fixture_text(delete_org_id=2))), True)
    case("missing InfluxDB in deleteDatasources fails AC-1",
         ac1(block_of(fixture_text(delete_names=["Prometheus", "Loki", "Tempo"]))), True)
    case("an unknown name in deleteDatasources fails AC-1",
         ac1(block_of(fixture_text(delete_names=RESET_NAMES + ["Grafana"]))), True)
    case("empty deleteDatasources fails AC-1",
         ac1(block_of(fixture_text(delete_names=[]))), True)
    case("repointed Prometheus uid fails AC-2",
         ac2(block_of(fixture_text(prom_uid="auto-generated"))), True)
    case("unpinned Loki uid fails AC-2",
         ac2(block_of(fixture_text(loki_uid=None))), True)
    case("deleteDatasources naming a missing datasource fails AC-2",
         ac2(block_of(fixture_text(delete_names=["Prometheus", "Loki", "Tempo", "InfluxDB", "Mimir"]))), True)

    # AC-3 needs git: a throwaway repo with a base commit and a modified head.
    repo = tempfile.mkdtemp(prefix="gul1693-")
    try:
        rel = MANIFEST_REL
        os.makedirs(os.path.join(repo, os.path.dirname(rel)), exist_ok=True)
        path = os.path.join(repo, rel)

        def commit(message):
            rc, out, err = git(repo, "-c", "user.email=selftest@example.invalid",
                               "-c", "user.name=selftest", "add", "-A")
            if rc != 0:
                raise RuntimeError("git add failed: %s" % err.strip())
            rc, out, err = git(repo, "-c", "user.email=selftest@example.invalid",
                               "-c", "user.name=selftest", "commit", "-qm", message)
            if rc != 0:
                raise RuntimeError("git commit failed: %s" % err.strip())
            rc, out, err = git(repo, "rev-parse", "HEAD")
            if rc != 0:
                raise RuntimeError("git rev-parse failed: %s" % err.strip())
            return out.strip()

        rc, _, err = git(repo, "init", "-q", "-b", "main")
        if rc != 0:
            raise RuntimeError("git init failed: %s" % err.strip())

        with open(path, "w", encoding="utf-8") as fh:
            fh.write(fixture_text(with_delete=False))
        base_sha = commit("base")

        with open(path, "w", encoding="utf-8") as fh:
            fh.write(fixture_text())
        commit("green: add deleteDatasources")
        case("green diff passes AC-3", ac3(repo, base_sha, rel), False)

        with open(path, "w", encoding="utf-8") as fh:
            fh.write(fixture_text(with_delete=False))
        commit("revert deleteDatasources")
        case("diff without deleteDatasources fails AC-3", ac3(repo, base_sha, rel), True)

        with open(path, "w", encoding="utf-8") as fh:
            fh.write(fixture_text(chart="12.6.0"))
        commit("green block but chart pin downgraded")
        case("downgraded chart pin fails AC-3", ac3(repo, base_sha, rel), True)

        with open(path, "w", encoding="utf-8") as fh:
            fh.write(fixture_text(loki_uid="auto-generated"))
        commit("green block but repointed Loki uid")
        case("repointed Loki uid in the diff fails AC-3", ac3(repo, base_sha, rel), True)
    except (RuntimeError, OSError) as exc:
        failures.append("ac3 fixtures: %s" % exc)
        checks.append(("ac3 fixtures", False, [str(exc)]))
    finally:
        shutil.rmtree(repo, ignore_errors=True)

    for label, ok, problems in checks:
        if ok:
            print("self-test: ok   %s" % label)
        else:
            print("self-test: FAIL %s -> %s" % (label, "; ".join(problems) or "no problem reported"))
    if failures:
        print("self-test: %d case(s) failed" % len(failures))
        return 1
    print("self-test: all %d cases ok" % len(checks))
    return 0


# ---------------------------------------------------------------- main
if ARGS and ARGS[0] == "--self-test":
    sys.exit(self_test())

try:
    block = provision_block(load_file(MANIFEST))
    manifest_error = None
except (YamlError, OSError) as exc:
    block = MISSING
    manifest_error = "cannot read %s: %s" % (MANIFEST_REL, exc)

if manifest_error:
    results = [("1", [manifest_error]), ("2", [manifest_error]), ("3", [manifest_error])]
else:
    results = []
    for ac, check in (("1", lambda: ac1(block)), ("2", lambda: ac2(block)),
                      ("3", lambda: ac3(ROOT, BASE_SHA, MANIFEST_REL))):
        try:
            results.append((ac, check()))
        except (YamlError, OSError) as exc:
            results.append((ac, ["cannot read %s: %s" % (MANIFEST_REL, exc)]))

failed = 0
for ac, problems in results:
    if problems:
        failed += 1
        print("AC-%s: FAIL %s" % (ac, "; ".join(problems)))
    else:
        print("AC-%s: PASS" % ac)

sys.exit(1 if failed else 0)
PY
