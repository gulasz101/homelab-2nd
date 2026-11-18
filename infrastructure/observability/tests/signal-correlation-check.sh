#!/usr/bin/env bash
# Static check for OTel work order 2 (GUL-1596, red stage GUL-1681): link logs,
# traces and metrics in Grafana, and make Tempo write service-graph / span
# metrics back to Prometheus. No cluster, no network, no PyYAML: it reads the
# three HelmRelease files plus every dashboard ConfigMap in the repo as text and
# asserts the properties Flux would otherwise only prove at runtime.
#
# The YAML is read by a small indentation parser (the subset these files use:
# block maps, block sequences, flow lists/maps, block scalars) - the same shape
# the OTel WO-1 check uses. PyYAML is not installed on the Air or in CI and yq is
# not a hard dependency of every runner, so neither is used.
#
# The dashboard ConfigMaps carry a JSON document inside a YAML string, so the
# file text is unescaped once (`\"` -> `"`) before the datasource references are
# matched. Only references that sit inside a `"datasource": {...}` object count:
# a dashboard's own `uid` and a `"datasource": "$var"` variable are not
# datasource uids.
#
# What the acceptance criteria mean here (GUL-1596 spec):
#   AC-1 fixed uids on the Prometheus/Loki datasources, equal to the uids the
#        dashboards already query, plus a fixed uid for Tempo
#   AC-2 the Tempo datasource links to Loki (by trace id) and to Prometheus for
#        metrics and for the service map
#   AC-3 the Loki datasource turns a trace id into a Tempo link (derived field)
#   AC-4 Prometheus keeps exemplars and Grafana's Prometheus datasource points
#        an exemplar at Tempo
#   AC-5 Tempo's metrics-generator runs the service-graphs and span-metrics
#        processors and remote-writes them to Prometheus, which accepts them
#   AC-6 no dashboard references a datasource uid that nothing declares
#
# Protocol (agents/factory/CONTRACT.md point 2): one `AC-n: PASS|FAIL <reason>`
# line per acceptance criterion, exit 0 only when all of them pass.
#
# Usage: bash infrastructure/observability/tests/signal-correlation-check.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

python3 -I - "$ROOT" <<'PY'
import os
import re
import sys

ROOT = sys.argv[1]
OBS = os.path.join("infrastructure", "observability")
GRAFANA = os.path.join(ROOT, OBS, "grafana-helm-release.yaml")
PROMETHEUS = os.path.join(ROOT, OBS, "prometheus-stack-helm-release.yaml")
TEMPO = os.path.join(ROOT, OBS, "tempo-helm-release.yaml")

UID_RE = re.compile(r"^[A-Za-z0-9_-]{1,40}$")
# Grafana's own pseudo-datasources; a dashboard that names one of these is not
# pointing at a provisioned datasource.
SPECIAL_UIDS = {"-- Mixed --", "-- Grafana --", "-- Dashboard --"}
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
    spec = doc.get("spec")
    if not isinstance(spec, dict) or not isinstance(spec.get("values"), dict):
        raise YamlError("%s has no spec.values mapping" % os.path.basename(path))
    return spec["values"]


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


# ---------------------------------------------------------------- Grafana side

def grafana_datasources():
    """The provisioned datasource list, or None when the Grafana values carry none."""
    values = values_of(GRAFANA)
    block = dig(values, "datasources", "datasources.yaml")
    if block is MISSING:
        return None
    listed = dig(block, "datasources")
    if not isinstance(listed, list):
        return None
    return [entry for entry in listed if isinstance(entry, dict)]


def find_type(datasources, wanted):
    for entry in datasources:
        if dig(entry, "type") == wanted:
            return entry
    return None


def uid_of(datasources, wanted):
    entry = find_type(datasources, wanted) if datasources else None
    if entry is None:
        return None
    uid = dig(entry, "uid")
    if isinstance(uid, str) and uid:
        return uid
    return None


def name_of(entry):
    name = dig(entry, "name")
    return name if isinstance(name, str) and name else "<unnamed>"


# ---------------------------------------------------------------- dashboards

DS_OBJECT = re.compile(r'"datasource"\s*:\s*\{([^{}]*)\}')
OBJ_TYPE = re.compile(r'"type"\s*:\s*"([^"]*)"')
OBJ_UID = re.compile(r'"uid"\s*:\s*"([^"]*)"')
DASHBOARD_REFS = None


def dashboard_refs():
    """Every (type, uid, relpath) a dashboard panel/row/target points at."""
    global DASHBOARD_REFS
    if DASHBOARD_REFS is not None:
        return DASHBOARD_REFS
    refs = []
    for base in ("apps", "infrastructure"):
        top = os.path.join(ROOT, base)
        if not os.path.isdir(top):
            continue
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = sorted(d for d in dirnames if d not in (".git", "tests", "test"))
            for name in sorted(filenames):
                if not name.endswith((".yaml", ".yml", ".json")):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    with open(path, encoding="utf-8") as fh:
                        body = fh.read()
                except (OSError, UnicodeDecodeError):
                    continue
                if "datasource" not in body:
                    continue
                text = body.replace('\\"', '"')
                rel = os.path.relpath(path, ROOT)
                for match in DS_OBJECT.finditer(text):
                    obj = match.group(1)
                    uid_match = OBJ_UID.search(obj)
                    if uid_match is None:
                        continue
                    type_match = OBJ_TYPE.search(obj)
                    refs.append((type_match.group(1) if type_match else "", uid_match.group(1), rel))
    DASHBOARD_REFS = refs
    return refs


def uids_used(typ):
    """The distinct non-template datasource uids the dashboards query for one type."""
    out = set()
    for ref_type, uid, _ in dashboard_refs():
        if ref_type != typ:
            continue
        if not uid or uid.startswith("$") or uid in SPECIAL_UIDS:
            continue
        out.add(uid)
    return out


# ---------------------------------------------------------------- AC-1
def check_ac1():
    problems = []
    datasources = grafana_datasources()
    if datasources is None:
        return ["the Grafana values provision no datasources (datasources.datasources.yaml.datasources)"]

    for typ in ("prometheus", "loki"):
        entry = find_type(datasources, typ)
        if entry is None:
            problems.append("the Grafana values provision no %s datasource" % typ)
            continue
        uid = uid_of(datasources, typ)
        if uid is None:
            problems.append("the %s datasource (%s) has no fixed uid, so Grafana mints one and every "
                            "dashboard that hard-codes a uid goes blind" % (typ, name_of(entry)))
            continue
        if not UID_RE.match(uid):
            problems.append("the %s datasource uid %r is not a valid Grafana uid" % (typ, uid))
        used = uids_used(typ)
        if len(used) != 1:
            problems.append("the dashboards query %d %s uids (%s), so there is no single uid to pin"
                            % (len(used), typ, ", ".join(sorted(used)) or "none"))
            continue
        wanted = sorted(used)[0]
        if uid != wanted:
            problems.append("%s datasource uid is %r, but the dashboards query %r" % (typ, uid, wanted))

    tempo = find_type(datasources, "tempo")
    if tempo is None:
        problems.append("the Grafana values provision no tempo datasource")
    else:
        uid = uid_of(datasources, "tempo")
        if uid is None:
            problems.append("the tempo datasource has no fixed uid, so the links from logs and metrics "
                            "have no stable target")
        elif not UID_RE.match(uid):
            problems.append("the tempo datasource uid %r is not a valid Grafana uid" % uid)

    seen = {}
    for entry in datasources:
        uid = dig(entry, "uid")
        if isinstance(uid, str) and uid:
            if uid in seen:
                problems.append("uid %r is declared by both %s and %s"
                                % (uid, seen[uid], name_of(entry)))
            seen[uid] = name_of(entry)
    return problems


# ---------------------------------------------------------------- AC-2
def check_ac2():
    datasources = grafana_datasources()
    if datasources is None:
        return ["the Grafana values provision no datasources, so the Tempo datasource links nothing"]
    tempo = find_type(datasources, "tempo")
    if tempo is None:
        return ["the Grafana values provision no tempo datasource to link from"]
    problems = []
    loki_uid = uid_of(datasources, "loki")
    prom_uid = uid_of(datasources, "prometheus")
    json_data = dig(tempo, "jsonData")
    if json_data is MISSING:
        return ["the tempo datasource has no jsonData: no trace-to-logs, trace-to-metrics or service map link"]

    logs = dig(json_data, "tracesToLogsV2")
    if logs is MISSING:
        logs = dig(json_data, "tracesToLogs")
    if logs is MISSING:
        problems.append("jsonData.tracesToLogsV2 is missing, so a span cannot jump to its log lines")
    else:
        if loki_uid is None:
            problems.append("tracesToLogsV2 cannot be checked: the loki datasource has no fixed uid")
        elif dig(logs, "datasourceUid") != loki_uid:
            problems.append("tracesToLogsV2.datasourceUid is %s, want the loki uid %r"
                            % (fmt(dig(logs, "datasourceUid")), loki_uid))
        if dig(logs, "filterByTraceID") is not True:
            problems.append("tracesToLogsV2.filterByTraceID is %s, want true so the log query keys on the trace id"
                            % fmt(dig(logs, "filterByTraceID")))

    metrics = dig(json_data, "tracesToMetrics")
    if metrics is MISSING:
        problems.append("jsonData.tracesToMetrics is missing, so a span cannot jump to its RED metrics")
    else:
        if prom_uid is None:
            problems.append("tracesToMetrics cannot be checked: the prometheus datasource has no fixed uid")
        elif dig(metrics, "datasourceUid") != prom_uid:
            problems.append("tracesToMetrics.datasourceUid is %s, want the prometheus uid %r"
                            % (fmt(dig(metrics, "datasourceUid")), prom_uid))
        queries = dig(metrics, "queries")
        usable = []
        if isinstance(queries, list):
            for query in queries:
                expr = dig(query, "query") if isinstance(query, dict) else MISSING
                if isinstance(expr, str) and expr.strip():
                    usable.append(expr)
        if not usable:
            problems.append("tracesToMetrics.queries is %s, want at least one query with a PromQL expression"
                            % fmt(queries))

    service_map = dig(json_data, "serviceMap")
    if service_map is MISSING:
        problems.append("jsonData.serviceMap is missing, so the service graph view has no datasource")
    else:
        if prom_uid is None:
            problems.append("serviceMap cannot be checked: the prometheus datasource has no fixed uid")
        elif dig(service_map, "datasourceUid") != prom_uid:
            problems.append("serviceMap.datasourceUid is %s, want the prometheus uid %r"
                            % (fmt(dig(service_map, "datasourceUid")), prom_uid))
    return problems


# ---------------------------------------------------------------- AC-3
def check_ac3():
    datasources = grafana_datasources()
    if datasources is None:
        return ["the Grafana values provision no datasources, so the loki datasource cannot link to tempo"]
    loki = find_type(datasources, "loki")
    if loki is None:
        return ["the Grafana values provision no loki datasource to turn a trace id into a link"]
    tempo_uid = uid_of(datasources, "tempo")
    json_data = dig(loki, "jsonData")
    if json_data is MISSING:
        return ["the loki datasource has no jsonData, so a trace_id in a log line stays plain text"]
    fields = dig(json_data, "derivedFields")
    if not isinstance(fields, list) or not fields:
        return ["jsonData.derivedFields is %s, want a derived field that links trace_id to tempo" % fmt(fields)]
    problems = []
    if tempo_uid is None:
        problems.append("the derived field has no target: the tempo datasource has no fixed uid")
    matched = []
    for field in fields:
        if not isinstance(field, dict):
            continue
        uid = dig(field, "datasourceUid")
        if tempo_uid is not None and uid != tempo_uid:
            continue
        matcher = dig(field, "matcherRegex")
        if not isinstance(matcher, str) or not re.search(r"trace[_ ]?id", matcher, re.I):
            continue
        url = dig(field, "url")
        if not isinstance(url, str) or "__value.raw" not in url:
            continue
        if tempo_uid is not None:
            matched.append(dig(field, "name"))
    if tempo_uid is not None and not matched:
        problems.append("none of the %d derived fields links a trace id to the tempo uid %r "
                        "(want datasourceUid, a matcher naming the trace id, and a $${__value.raw} url)"
                        % (len(fields), tempo_uid))
    return problems


# ---------------------------------------------------------------- AC-4
def check_ac4():
    problems = []
    values = values_of(PROMETHEUS)
    spec = dig(values, "prometheus", "prometheusSpec")
    if spec is MISSING:
        problems.append("prometheus.prometheusSpec is missing from the Prometheus values")
    else:
        features = dig(spec, "enableFeatures")
        if not isinstance(features, list) or "exemplar-storage" not in features:
            problems.append("prometheusSpec.enableFeatures is %s, want exemplar-storage so exemplars survive "
                            "the write path" % fmt(features))

    datasources = grafana_datasources()
    if datasources is None:
        problems.append("the Grafana values provision no datasources, so no exemplar link is configured")
        return problems
    prometheus = find_type(datasources, "prometheus")
    if prometheus is None:
        problems.append("the Grafana values provision no prometheus datasource to carry exemplars")
        return problems
    tempo_uid = uid_of(datasources, "tempo")
    if tempo_uid is None:
        problems.append("the exemplar link has no target: the tempo datasource has no fixed uid")
    destinations = dig(prometheus, "jsonData", "exemplarTraceIdDestinations")
    usable = []
    if isinstance(destinations, list):
        for dest in destinations:
            if not isinstance(dest, dict):
                continue
            name = dig(dest, "name")
            if not isinstance(name, str) or not name:
                continue
            if tempo_uid is not None and dig(dest, "datasourceUid") != tempo_uid:
                continue
            if tempo_uid is not None:
                usable.append(name)
    if tempo_uid is not None and not usable:
        problems.append("jsonData.exemplarTraceIdDestinations is %s, want an entry naming the trace id label "
                        "and pointing at the tempo uid %r" % (fmt(destinations), tempo_uid))
    return problems


# ---------------------------------------------------------------- AC-5
def walk_keys(node, wanted, found):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in wanted:
                found.append(value)
            walk_keys(value, wanted, found)
    elif isinstance(node, list):
        for value in node:
            walk_keys(value, wanted, found)


def walk_list_values(node, found):
    if isinstance(node, dict):
        for value in node.values():
            walk_list_values(value, found)
    elif isinstance(node, list):
        for value in node:
            if isinstance(value, str):
                found.add(value)
            walk_list_values(value, found)


def find_metrics_generator(values):
    """The metrics-generator block, whichever chart spelling (camel/snake) carries it."""
    found = []
    walk_keys(values, ("metricsGenerator", "metrics_generator"), found)
    best = None
    best_score = 0
    for node in found:
        if not isinstance(node, dict):
            continue
        score = 0
        if "enabled" in node:
            score += 3
        if "storage" in node or "remoteWriteUrl" in node or "remote_write_url" in node:
            score += 3
        if "processor" in node:
            score += 2
        if score > best_score:
            best, best_score = node, score
    return best


def check_ac5():
    problems = []
    values = values_of(TEMPO)
    generator = find_metrics_generator(values)
    if generator is None:
        problems.append("the Tempo values define no metricsGenerator block, so Tempo derives no metrics from traces")
    else:
        if "enabled" in generator and generator["enabled"] is not True:
            problems.append("tempo.metricsGenerator.enabled is %s" % fmt(generator["enabled"]))

        urls = []
        direct = dig(generator, "remoteWriteUrl")
        if isinstance(direct, str):
            urls.append(direct)
        remote_write = dig(generator, "storage", "remote_write")
        if isinstance(remote_write, list):
            for item in remote_write:
                url = dig(item, "url") if isinstance(item, dict) else MISSING
                if isinstance(url, str):
                    urls.append(url)
        targets = [url for url in urls if "prometheus" in url and "/api/v1/write" in url]
        if not urls:
            problems.append("the metrics generator has no remote_write url, so nothing is written back")
        elif not targets:
            problems.append("the metrics generator remote_write url(s) %s do not target Prometheus at "
                            "/api/v1/write" % urls)

        processors = dig(generator, "processor")
        if processors is MISSING:
            processors = dig(generator, "processors")
        named = set()
        if isinstance(processors, dict):
            named = {str(key) for key in processors}
        elif isinstance(processors, list):
            named = {value for value in processors if isinstance(value, str)}
        normalised = {name.replace("_", "-") for name in named}
        for want in ("service-graphs", "span-metrics"):
            if want not in normalised:
                problems.append("the metrics generator processors are %s, want %s enabled"
                                % (sorted(named) or "empty", want))

        listed = set()
        walk_list_values(values, listed)
        activation = {value.replace("_", "-") for value in listed}
        for want in ("service-graphs", "span-metrics"):
            if want not in activation:
                problems.append("no overrides list activates %s, so Tempo generates no %s series"
                                % (want, want))

    prometheus_values = values_of(PROMETHEUS)
    prom_spec = dig(prometheus_values, "prometheus", "prometheusSpec")
    if prom_spec is MISSING:
        problems.append("prometheus.prometheusSpec is missing from the Prometheus values")
    elif dig(prom_spec, "enableRemoteWriteReceiver") is not True:
        problems.append("prometheusSpec.enableRemoteWriteReceiver is %s, want true or Prometheus rejects the "
                        "metrics generator's remote write" % fmt(dig(prom_spec, "enableRemoteWriteReceiver")))
    return problems


# ---------------------------------------------------------------- AC-6
def check_ac6():
    datasources = grafana_datasources()
    if datasources is None:
        return ["the Grafana values declare no datasource uid at all, so every dashboard uid is unknown"]
    declared = set()
    for entry in datasources:
        uid = dig(entry, "uid")
        if isinstance(uid, str) and uid:
            declared.add(uid)
    unknown = {}
    for ref_type, uid, rel in dashboard_refs():
        if not uid or uid.startswith("$") or uid in SPECIAL_UIDS:
            continue
        if uid in declared:
            continue
        record = unknown.setdefault(uid, {"types": set(), "files": set(), "count": 0})
        record["types"].add(ref_type or "untyped")
        record["files"].add(rel)
        record["count"] += 1
    problems = []
    for uid in sorted(unknown):
        record = unknown[uid]
        files = sorted(record["files"])
        shown = ", ".join(files[:3]) + (" and %d more" % (len(files) - 3) if len(files) > 3 else "")
        problems.append("uid %r (%s) is referenced %d times in %s but no provisioned datasource declares it"
                        % (uid, "/".join(sorted(record["types"])), record["count"], shown))
    return problems


CHECKS = [
    ("1", check_ac1),
    ("2", check_ac2),
    ("3", check_ac3),
    ("4", check_ac4),
    ("5", check_ac5),
    ("6", check_ac6),
]

failed = 0
for ac, check in CHECKS:
    try:
        problems = check()
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
