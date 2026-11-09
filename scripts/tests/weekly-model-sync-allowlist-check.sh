#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1096: the weekly model sync must not put failed-probe models in the key
# allowlist.
#
# `apps/llm-hub/scripts/weekly-model-sync.py` keeps failed probes out of the
# LiteLLM route list but not out of the key allowlist: `DESIRED_MODELS` in
# apps/llm-hub/litellm-key-provisioner-configmap.yaml was built from every id
# upstream offered, probed or not. So the provisioner granted every service
# key permission for a model the proxy cannot serve, and the strays piled up
# (thirteen ids with no `model_name:` route at the base commit).
#
# AC-1: compute_provisioner_desired() keeps only what has a route after the
#       run - the routed ids and the verified additions - and drops the
#       unrouted, the failed-probe and the route-removed ones. The expected
#       result set is pinned exactly, so a set that merely "looks plausible"
#       cannot pass.
# AC-2: every non-commented DESIRED_MODELS id has a matching `model_name:`
#       route in apps/llm-hub/litellm-helm-release.yaml. The `openai/` prefix
#       is stripped first: the provisioner expands it itself, so only the bare
#       name has to be routed. Offending ids are named in the FAIL reason.
# AC-3: comments inside DESIRED_MODELS survive the edit. A commented sample
#       block goes through compute_provisioner_desired() and then
#       update_key_provisioner(), and both the comments and the resulting set
#       are asserted. Running the function first is deliberate: it keeps AC-3
#       red until the function exists and green only when the function and the
#       text edit both work.
#
# Hermetic: standard-library Python only, no network, no cluster, no git, no
# sops, and it writes nothing inside the repo (the one temporary file lives in
# the system temp dir). The module is imported by path because its file name
# is not a valid module name, and importing it runs nothing - main() sits
# behind `if __name__ == "__main__"`.
#
# `weekly-model-sync.py` imports `ruamel.yaml` at module level (and builds
# `yaml = YAML()` there). Neither function under test touches YAML, and CI has
# no third-party Python packages, so when ruamel is not installed a minimal
# stand-in is registered that satisfies the import and raises on any real use.
# The real library is used whenever it is installed.
#
# Discovered and run by scripts/check.sh (it globs */tests/*-check.sh).
#
# Usage: bash scripts/tests/weekly-model-sync-allowlist-check.sh
# Exit:  0 = AC-1, AC-2 and AC-3 pass; 1 = at least one fails. Never anything
#        else - a check that cannot run reports FAIL, it does not invent an
#        exit code the factory would read as a setup error.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

python3 - "$ROOT" <<'PY'
import importlib.util
import re
import sys
import tempfile
import types
from pathlib import Path

ROOT = Path(sys.argv[1])
SYNC = ROOT / "apps" / "llm-hub" / "scripts" / "weekly-model-sync.py"
PROVISIONER = ROOT / "apps" / "llm-hub" / "litellm-key-provisioner-configmap.yaml"
RELEASE = ROOT / "apps" / "llm-hub" / "litellm-helm-release.yaml"

ACS = ("AC-1", "AC-2", "AC-3")

# The fake run AC-1 and AC-3 drive the function with. Names are chosen so the
# four outcomes cannot be confused: one id is routed and stays, one has no
# route at all, one failed its probe, one loses its route this run, and one
# verified addition arrives.
PROVISIONER_CURRENT = {"kept-routed", "stray-unrouted", "failed-probe-model", "removed-model"}
ROUTED_MODELS = {"kept-routed", "removed-model"}
VERIFIED_ADDITIONS = {"new-verified"}
FAILED_ADDITIONS = {"failed-probe-model"}
SAFE_REMOVALS = {"removed-model"}
EXPECTED = {"kept-routed", "new-verified"}

# A commented DESIRED_MODELS block, shaped like the real one inside the
# ConfigMap (the block is embedded Python under `provision.py: |`). Every
# comment here has to be there after the text edit.
SAMPLE_COMMENTS = (
    "# kept-routed: routed on the proxy and stays routed.",
    "# stray-unrouted: nothing routes this id, so it must not be allowed.",
    "# failed-probe-model: the probe failed this run.",
)
SAMPLE_TEXT = (
    "data:\n"
    "  provision.py: |\n"
    "    import os\n"
    "\n"
    "    LITELLM_URL = os.environ.get(\"LITELLM_URL\", \"http://litellm:4000\")\n"
    "    DESIRED_MODELS = [\n"
    '        "kept-routed",\n'
    "        # kept-routed: routed on the proxy and stays routed.\n"
    '        "stray-unrouted",\n'
    "        # stray-unrouted: nothing routes this id, so it must not be allowed.\n"
    '        "failed-probe-model",\n'
    "        # failed-probe-model: the probe failed this run.\n"
    '        "removed-model",  # route retired by this run\n'
    "    ]\n"
    "    MASTER_KEY = os.environ.get(\"LITELLM_MASTER_KEY\", \"\")\n"
)


def load_sync_module():
    """Import weekly-model-sync.py by path, stubbing ruamel.yaml if absent."""
    try:
        import ruamel.yaml  # noqa: F401
    except ImportError:
        package = types.ModuleType("ruamel")
        package.__path__ = []
        module = types.ModuleType("ruamel.yaml")

        class _UnavailableYAML:
            def __init__(self, *args, **kwargs):
                pass

            def __getattr__(self, name):
                raise RuntimeError(
                    "ruamel.yaml is not installed and the allowlist check must not need it"
                )

        module.YAML = _UnavailableYAML
        package.yaml = module
        sys.modules.setdefault("ruamel", package)
        sys.modules["ruamel.yaml"] = module

    spec = importlib.util.spec_from_file_location("weekly_model_sync", SYNC)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SYNC.relative_to(ROOT)}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def compute(sync):
    """Return the imported compute_provisioner_desired, or raise a clear error."""
    fn = getattr(sync, "compute_provisioner_desired", None)
    if fn is None or not callable(fn):
        raise RuntimeError(
            "compute_provisioner_desired is not defined in apps/llm-hub/scripts/weekly-model-sync.py"
        )
    return fn


def call_compute(fn):
    """Call the function once with the fake run's five arguments."""
    return fn(
        set(PROVISIONER_CURRENT),
        set(ROUTED_MODELS),
        set(VERIFIED_ADDITIONS),
        set(FAILED_ADDITIONS),
        set(SAFE_REMOVALS),
    )


def describe(got, expected):
    """One line naming what is wrong with a result set."""
    parts = []
    extra = sorted(got - expected)
    missing = sorted(expected - got)
    if extra:
        parts.append("kept " + ", ".join(extra))
    if missing:
        parts.append("dropped " + ", ".join(missing))
    return "; ".join(parts)


def check_ac1(sync):
    fn = compute(sync)
    result = call_compute(fn)
    try:
        got = set(result)
    except TypeError:
        return f"compute_provisioner_desired returned {type(result).__name__}, want a set of model ids"
    if got != EXPECTED:
        detail = describe(got, EXPECTED) or "unexpected result"
        return (
            f"expected {{{', '.join(sorted(EXPECTED))}}}, got "
            f"{{{', '.join(sorted(got))}}} ({detail})"
        )
    return None


def desired_models_ids(text):
    """Non-commented ids inside the DESIRED_MODELS block, openai/ kept."""
    block = re.search(r"DESIRED_MODELS\s*=\s*\[(.*?)\n\s*\]", text, re.DOTALL)
    if not block:
        raise RuntimeError(
            f"could not find the DESIRED_MODELS block in {PROVISIONER.relative_to(ROOT)}"
        )
    return re.findall(r'^\s*"((?:openai/)?[^"]+)"', block.group(1), re.MULTILINE)


def routed_model_names(text):
    """Every uncommented `model_name:` value in the LiteLLM release."""
    names = set()
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0]
        match = re.match(r"\s*(?:-\s*)?model_name:\s*(.+?)\s*$", line)
        if match:
            names.add(match.group(1).strip().strip("\"'"))
    return names


def check_ac2(_sync):
    ids = desired_models_ids(PROVISIONER.read_text(encoding="utf-8"))
    if not ids:
        return (
            f"parsed 0 ids out of DESIRED_MODELS in {PROVISIONER.relative_to(ROOT)}; "
            "refusing to report PASS over an empty set"
        )
    routes = routed_model_names(RELEASE.read_text(encoding="utf-8"))
    if not routes:
        return (
            f"parsed 0 model_name: routes out of {RELEASE.relative_to(ROOT)}; "
            "refusing to report PASS over an empty set"
        )
    unrouted = sorted({i[len("openai/"):] if i.startswith("openai/") else i for i in ids} - routes)
    if unrouted:
        return (
            f"{len(unrouted)} DESIRED_MODELS id(s) have no model_name: route in "
            f"{RELEASE.name}: {', '.join(unrouted)}"
        )
    return None


def check_ac3(sync):
    fn = compute(sync)
    update = getattr(sync, "update_key_provisioner", None)
    if update is None or not callable(update):
        return "update_key_provisioner is not defined in apps/llm-hub/scripts/weekly-model-sync.py"

    desired = set(call_compute(fn))
    if desired != EXPECTED:
        detail = describe(desired, EXPECTED) or "unexpected result"
        return f"compute_provisioner_desired gave {{{', '.join(sorted(desired))}}} ({detail})"

    updated = update(SAMPLE_TEXT, desired)
    if updated == SAMPLE_TEXT:
        return "update_key_provisioner returned the sample block unchanged"

    lost = [comment for comment in SAMPLE_COMMENTS if comment not in updated]
    if lost:
        return "comment(s) lost from DESIRED_MODELS: " + "; ".join(lost)

    # Re-read the rewritten block through the module's own parser, so the check
    # asserts the resulting set and not the shape of the returned string.
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, encoding="utf-8") as handle:
        handle.write(updated)
        temp_path = Path(handle.name)
    try:
        written = set(sync.current_provisioner_models(temp_path))
    finally:
        temp_path.unlink()

    if written != EXPECTED:
        detail = describe(written, EXPECTED) or "unexpected result"
        return (
            f"rewritten DESIRED_MODELS is {{{', '.join(sorted(written))}}}, want "
            f"{{{', '.join(sorted(EXPECTED))}}} ({detail})"
        )
    return None


def evaluate():
    """Run every AC independently; return [(ac, reason-or-None)]."""
    try:
        sync = load_sync_module()
        load_error = None
    except BaseException as exc:  # noqa: BLE001 - any failure is a FAIL, never a traceback
        sync = None
        load_error = f"{type(exc).__name__}: {exc}"

    checks = {"AC-1": check_ac1, "AC-2": check_ac2, "AC-3": check_ac3}
    results = []
    for ac in ACS:
        if sync is None and ac != "AC-2":
            # AC-2 reads the manifests, not the module, so it still reports the
            # truth about them even when the module will not import.
            results.append((ac, f"cannot import weekly-model-sync.py: {load_error}"))
            continue
        try:
            results.append((ac, checks[ac](sync)))
        except BaseException as exc:  # noqa: BLE001 - same rule: FAIL, never a traceback
            results.append((ac, f"{type(exc).__name__}: {exc}"))
    return results


def main():
    try:
        results = evaluate()
    except BaseException as exc:  # noqa: BLE001 - last resort, still one line per AC
        results = [(ac, f"check crashed: {type(exc).__name__}: {exc}") for ac in ACS]

    failed = 0
    for ac, reason in results:
        if reason is None:
            print(f"{ac}: PASS")
        else:
            failed = 1
            print(f"{ac}: FAIL {reason}")
    return 1 if failed else 0


sys.exit(main())
PY
