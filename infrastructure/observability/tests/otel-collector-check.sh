#!/usr/bin/env bash
# Static check for the OpenTelemetry hardening work order (GUL-1593 WO-1,
# GUL-1595). No cluster, no network, no PyYAML: it reads the two HelmRelease
# files and the app manifests as text and asserts the properties that Flux
# would otherwise only prove at runtime.
#
# The YAML is read by a small indentation parser (the subset these two files
# use: block maps, block sequences, flow lists/maps, block scalars). PyYAML is
# not installed on the Air or in CI, and yq is not a hard dependency of every
# runner, so neither is used.
#
# Protocol (agents/factory/CONTRACT.md point 2): one `AC-n: PASS|FAIL <reason>`
# line per acceptance criterion, exit 0 only when all of them pass.
#
# Usage: bash infrastructure/observability/tests/otel-collector-check.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

python3 -I - "$ROOT" <<'PY'
import os
import re
import sys

ROOT = sys.argv[1]
COLLECTOR = os.path.join(ROOT, "infrastructure/observability/opentelemetry-collector-helm-release.yaml")
PROMETHEUS = os.path.join(ROOT, "infrastructure/observability/prometheus-stack-helm-release.yaml")
OTLP_URL = "http://prometheus-stack-kube-prom-prometheus.observability.svc.cluster.local:9090/api/v1/otlp"
WANT_PROCESSORS = ["memory_limiter", "k8sattributes", "batch"]
PIPELINES = ["logs", "traces", "metrics"]
WANT_EXPORTERS = ["otlphttp/loki", "otlp/tempo", "otlphttp/prometheus"]

MISSING = object()


class YamlError(Exception):
    pass


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


def tokenize(path):
    toks = []
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
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


def load(path):
    toks = tokenize(path)
    if not toks:
        raise YamlError("%s is empty" % os.path.basename(path))
    doc, _ = parse_block(toks, 0, toks[0][0])
    if not isinstance(doc, dict):
        raise YamlError("%s does not start with a mapping" % os.path.basename(path))
    return doc


def values_of(path):
    doc = load(path)
    vals = doc.get("spec")
    if not isinstance(vals, dict) or not isinstance(vals.get("values"), dict):
        raise YamlError("%s has no spec.values mapping" % os.path.basename(path))
    return vals["values"]


def dig(node, *keys):
    cur = node
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            return MISSING
        cur = cur[key]
    return cur


def text_of(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def fmt(value):
    if value is MISSING:
        return "<missing>"
    return repr(value)


# ---------------------------------------------------------------- AC-1
def check_ac1():
    problems = []
    vals = values_of(COLLECTOR)
    cfg = dig(vals, "config")
    if cfg is MISSING:
        return ["no config: block in the collector values"]
    processors = dig(cfg, "processors")
    limiter = dig(processors, "memory_limiter")
    if limiter is MISSING:
        problems.append("config.processors.memory_limiter is not defined")
    elif not isinstance(limiter, dict) or not limiter:
        problems.append("config.processors.memory_limiter is empty, want check_interval/limit_percentage/spike_limit_percentage")
    pipelines = dig(cfg, "service", "pipelines")
    if not isinstance(pipelines, dict) or not pipelines:
        problems.append("config.service.pipelines is missing or empty")
    else:
        for name in PIPELINES:
            pipe = dig(pipelines, name)
            if pipe is MISSING:
                problems.append("no %s pipeline" % name)
                continue
            got = dig(pipe, "processors")
            if got != WANT_PROCESSORS:
                problems.append("%s processors are %s, want exactly %s in that order"
                                % (name, fmt(got), WANT_PROCESSORS))
    return problems


# ---------------------------------------------------------------- AC-2
def check_ac2():
    problems = []
    vals = values_of(COLLECTOR)
    cfg = dig(vals, "config")
    if cfg is MISSING:
        return ["no config: block in the collector values"]
    exporters = dig(cfg, "exporters")
    if isinstance(exporters, dict) and "debug" in exporters:
        problems.append("config.exporters still defines the debug exporter")
    pipelines = dig(cfg, "service", "pipelines")
    if isinstance(pipelines, dict):
        for name, pipe in pipelines.items():
            if not isinstance(pipe, dict):
                continue
            for field in ("exporters", "processors"):
                listed = dig(pipe, field)
                if isinstance(listed, list) and "debug" in listed:
                    problems.append("%s pipeline still lists debug in %s" % (name, field))
    return problems


# ---------------------------------------------------------------- AC-3
def check_ac3():
    problems = []
    raw = text_of(COLLECTOR)
    if "prometheusremotewrite" in raw:
        problems.append("the file still names prometheusremotewrite (remote write is gone)")
    if "prometheus-stack-prometheus." in raw:
        problems.append("the file still points at prometheus-stack-prometheus. (no such Service)")
    vals = values_of(COLLECTOR)
    cfg = dig(vals, "config")
    if cfg is MISSING:
        return problems + ["no config: block in the collector values"]
    pipelines = dig(cfg, "service", "pipelines")
    metrics = dig(pipelines, "metrics")
    if metrics is MISSING:
        problems.append("no metrics pipeline")
    else:
        got = dig(metrics, "exporters")
        if not isinstance(got, list) or "otlphttp/prometheus" not in got:
            problems.append("metrics pipeline exports %s, want otlphttp/prometheus" % fmt(got))
    exporter = dig(cfg, "exporters", "otlphttp/prometheus")
    if exporter is MISSING:
        problems.append("config.exporters.otlphttp/prometheus is not defined")
    else:
        endpoint = dig(exporter, "endpoint")
        if endpoint != OTLP_URL:
            problems.append("otlphttp/prometheus endpoint is %s, want %s" % (fmt(endpoint), OTLP_URL))
        if dig(exporter, "tls", "insecure") is not True:
            problems.append("otlphttp/prometheus tls.insecure is not true")
    return problems


# ---------------------------------------------------------------- AC-4
def check_ac4():
    problems = []
    vals = values_of(COLLECTOR)
    cfg = dig(vals, "config")
    if cfg is MISSING:
        return ["no config: block in the collector values"]
    for name in WANT_EXPORTERS:
        exporter = dig(cfg, "exporters", name)
        if exporter is MISSING:
            problems.append("exporter %s is not defined" % name)
            continue
        if dig(exporter, "sending_queue", "enabled") is not True:
            problems.append("exporter %s has no sending_queue.enabled: true" % name)
        if dig(exporter, "retry_on_failure", "enabled") is not True:
            problems.append("exporter %s has no retry_on_failure.enabled: true" % name)
    return problems


# ---------------------------------------------------------------- AC-5
def check_ac5():
    problems = []
    vals = values_of(COLLECTOR)

    metrics_port = False
    for candidate in (dig(vals, "ports", "metrics"), dig(vals, "service", "ports", "metrics")):
        if dig(candidate, "enabled") is True:
            metrics_port = True
    if not metrics_port:
        problems.append("no ports.metrics.enabled: true (the collector serves no metrics port)")

    podmonitor = dig(vals, "podMonitor")
    if podmonitor is MISSING:
        problems.append("no podMonitor block in the collector values")
    else:
        if dig(podmonitor, "enabled") is not True:
            problems.append("podMonitor.enabled is not true")
        release = dig(podmonitor, "extraLabels", "release")
        if release != "prometheus-stack":
            problems.append("podMonitor.extraLabels.release is %s, want prometheus-stack" % fmt(release))

    policy = dig(vals, "service", "internalTrafficPolicy")
    if policy != "Local":
        problems.append("service.internalTrafficPolicy is %s, want Local" % fmt(policy))
    return problems


# ---------------------------------------------------------------- AC-6
def check_ac6():
    problems = []
    vals = values_of(PROMETHEUS)
    spec = dig(vals, "prometheus", "prometheusSpec")
    if spec is MISSING:
        return ["prometheus.prometheusSpec is missing from the Prometheus values"]
    if dig(spec, "enableOTLPReceiver") is not True:
        problems.append("prometheusSpec.enableOTLPReceiver is not true")
    attrs = dig(spec, "otlp", "promoteResourceAttributes")
    if not isinstance(attrs, list):
        problems.append("prometheusSpec.otlp.promoteResourceAttributes is %s, want a list" % fmt(attrs))
    else:
        for wanted in ("service.name", "k8s.namespace.name"):
            if wanted not in attrs:
                problems.append("promoteResourceAttributes does not contain %s" % wanted)
    return problems


# ---------------------------------------------------------------- AC-7
def check_ac7():
    needle = "opentelemetry-collector" + ".monitoring.svc"
    problems = []
    for base in ("apps", "infrastructure"):
        top = os.path.join(ROOT, base)
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            # Test paths assert against this string, they do not ship it.
            dirnames[:] = [d for d in dirnames if d not in ("tests", "test")]
            for name in filenames:
                if not name.endswith((".yaml", ".yml", ".json", ".conf", ".md")):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    with open(path, encoding="utf-8") as fh:
                        body = fh.read()
                except (UnicodeDecodeError, OSError):
                    continue
                if needle in body:
                    problems.append("%s points OTLP at the non-existent monitoring namespace"
                                    % os.path.relpath(path, ROOT))
    return problems


CHECKS = [
    ("1", check_ac1),
    ("2", check_ac2),
    ("3", check_ac3),
    ("4", check_ac4),
    ("5", check_ac5),
    ("6", check_ac6),
    ("7", check_ac7),
]

failed = 0
for ac, fn in CHECKS:
    try:
        problems = fn()
    except (YamlError, OSError) as exc:
        print("AC-%s: FAIL could not read the manifests: %s" % (ac, exc))
        failed += 1
        continue
    if problems:
        failed += 1
        print("AC-%s: FAIL %s" % (ac, "; ".join(problems)))
    else:
        print("AC-%s: PASS" % ac)

sys.exit(1 if failed else 0)
PY
