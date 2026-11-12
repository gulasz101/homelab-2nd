#!/usr/bin/env python3
"""ZeroClaw / gemini-web2api cookie guard — watchdog pattern.

Silent when healthy (empty stdout = no delivery). Speaks on change:
  - imports a fresh Firefox cookie (validated BEFORE the old one is dropped)
  - reports a failed re-import
  - reports a paid-tier downgrade (the silent 4 Argon -> 3.5 Flash-Lite trap)
  - reports a WEDGED DOCKER ENGINE ("cannot ask" is a fault, not "nothing to do")
  - reports gemini-web2api not answering GET / (container may be up, proxy hung)
  - re-speaks an unresolved fault every REMIND_AFTER seconds, so a long outage cannot
    go quiet after one message (the 34 h wedge).

Never prints cookie values or tokens.

Test hooks (never needed in normal operation, used to prove the alert path without
stopping a live engine):
  GUARD_DOCKER=/path/to/docker     docker CLI to use (default /usr/local/bin/docker)
  GUARD_PROXY=http://host:port     proxy base URL (default http://127.0.0.1:8083)
  GUARD_STATE=/path/state.json     state file (default the normal scratch path)
  GUARD_SKIP_COOKIES=1             only run the availability checks, skip cookie/canary work
"""
import glob, hashlib, json, os, re, shutil, sqlite3, subprocess, sys, time, urllib.error, urllib.request

DOCKER = os.environ.get("GUARD_DOCKER", "/usr/local/bin/docker")
PROXY = os.environ.get("GUARD_PROXY", "http://127.0.0.1:8083")
# ADR-128: ~/.hermes is a read-only tombstone FILE on the Max, so the guard and its state cannot
# live there any more. GUARD_DIR is the host directory (guard.py, state, gemini2api.env).
SCRATCH = os.environ.get("GUARD_DIR", os.path.expanduser("~/homelab/gemini-web2api-guard"))
STATE = os.environ.get("GUARD_STATE", SCRATCH + "/cookie_guard_state.json")
ENVF = SCRATCH + "/gemini2api.env"
SKIP_COOKIES = os.environ.get("GUARD_SKIP_COOKIES") == "1"

WANT = ["SID", "HSID", "SSID", "APISID", "SAPISID",
        "__Secure-1PSID", "__Secure-1PSIDTS", "__Secure-1PAPISID", "__Secure-1PSIDCC"]
CANARY_MODEL = "gemini-4-argon"
PAID = ("4 Argon", "3.1 Pro", "3.8 Flash")

# A wedged daemon answers nothing at all, so every docker call needs a ceiling.
DOCKER_INFO_TIMEOUT = 15
DOCKER_CALL_TIMEOUT = 30
PROXY_PROBE_TIMEOUT = 10
RESTART_TIMEOUT = 120
REMIND_AFTER = 6 * 3600          # repeat an unresolved fault every 6 h
# Cumulative degraded time that counts as "this is not a cooldown any more". Cumulative, not a
# contiguous streak: this account recovers for minutes and falls back within minutes, and a 30-min
# sampler only ever sees the degraded side of that, so a contiguous clock never reaches the bar.
DEGRADED_ALERT_S = 6 * 3600
HEALTHY_CLEAR_S = 2 * 3600       # 2 quiet hours ends the streak (matches proxy_cooldown_min=120)


def env():
    return dict(l.split("=", 1) for l in open(ENVF).read().splitlines() if "=" in l)


def api(path, tok, method="GET", body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(PROXY + path, data=data, method=method,
                                headers={"Authorization": "Bearer " + tok,
                                         "Content-Type": "application/json"})
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:
        return 0, repr(e)


def dk(*args, timeout=DOCKER_CALL_TIMEOUT):
    return subprocess.run([DOCKER, *args], capture_output=True, text=True, timeout=timeout)


def speak(msgs, st, key, state, text, remind_after=REMIND_AFTER):
    """State-deduped message. A *bad* state that stays bad is repeated every `remind_after`
    seconds — one-shot dedup is exactly how a 34 h outage can produce zero messages."""
    now = int(time.time())
    healthy = str(state).endswith(("ok", "healthy"))
    if key not in st and healthy:
        # first ever run: record the good state without announcing it (no deploy-day noise)
        st[key] = state
        st[key + "_at"] = now
        return
    if st.get(key) == state:
        if not healthy and (now - int(st.get(key + "_at", 0) or 0)) >= remind_after:
            msgs.append(text)
            st[key + "_at"] = now
        return
    msgs.append(text)
    st[key] = state
    st[key + "_at"] = now


def note_entitlement(st, paid_now, now, was_degraded):
    """Track how long the paid tier has been degraded, CUMULATIVELY.

    Measured on this account (2026-11-04): it comes back for a few minutes and falls back within
    minutes. A 30-min sampler therefore sees "degraded" at every sample, and the old contiguous clock
    was reset by each observed recovery — a 13-hour flapping outage never escalated once. Credit the
    gap since the previous sample (capped, because a long silence is not evidence), and only clear the
    counter after HEALTHY_CLEAR_S of continuous health, which is this account's normal refill.

    `was_degraded` must be the state BEFORE this sample: st["entitlement"] is already updated by the
    caller, so reading it here would credit the wrong side of the transition.
    """
    prev = st.get("last_sample_at")
    gap = min(now - int(prev), 2 * 3600) if prev and now > int(prev) else 0
    if was_degraded:
        st["degraded_accum_s"] = int(st.get("degraded_accum_s") or 0) + gap
    st["last_sample_at"] = now
    if not paid_now:
        st.pop("healthy_since", None)
        st.setdefault("degraded_since", now)
        return int(st.get("degraded_accum_s") or 0)
    healthy_since = int(st.setdefault("healthy_since", now))
    if now - healthy_since >= HEALTHY_CLEAR_S:
        st["degraded_accum_s"] = 0
        st.pop("degraded_since", None)
        st.pop("degraded_long", None)
    return int(st.get("degraded_accum_s") or 0)


def degraded_escalation(msgs, st):
    """Speak once when cumulative degraded time passes DEGRADED_ALERT_S. Called on every run (not
    only on canary runs) so crossing the bar is reported within one cadence, not within an hour."""
    if st.get("entitlement") != "degraded":
        return
    accum = int(st.get("degraded_accum_s") or 0)
    if accum < DEGRADED_ALERT_S:
        return
    speak(msgs, st, "degraded_long", "long",
          "🛑 gemini-web2api: the paid tier has been degraded for %dh in total today, in short "
          "windows rather than one clean outage. This is capacity, not a broken plan — the account "
          "still renders in windows, so do not start at the billing page. Measured causes, in "
          "order: (1) the proxy refuses anything past 2 in-flight requests per IP "
          "(per_ip_concurrent=2) while one image render holds a slot for 20-43 s, and that is the "
          "largest single failure class; (2) when Google rate-limits the direct IP this proxy "
          "benches it for 120 min (proxy_cooldown_min), which is the '~2 h refill' everyone "
          "quotes — it is a bench, not a bucket; (3) long gemini-4-argon runs spend the same "
          "allowance as image jobs. The decision is Wojtek's: raise the concurrency limit, or give "
          "image work its own account." % (accum // 3600),
          remind_after=24 * 3600)


ARTIFACT_ROWS = None    # test hook: feed rows instead of reading the live request log
LOG_TS_SKEW = 9000      # the proxy's request log stamps rows 2.5 h behind real UTC (measured 2026-11-05)

# GUL-1339: a canary sample that reaches no verdict is a fault, never a green. These two patterns
# are what the request log can already say about the cause BEFORE another chat request is spent.
DEAD_COOKIE = re.compile(r"SNlM0e", re.I)
SLOW_MODEL = re.compile(r"Client\.Timeout|context deadline exceeded", re.I)
INCONCLUSIVE_REASON_MAX = 120


def artifact_check(msgs, st, tok):
    """GUL-950: three 'artifact retrieval failed' image jobs in a row raise ONE alert, so nobody
    has to read jobs.db to know images are down. Runs on every pass (the request log is free to
    read) so a streak is caught within one 30-min cadence even while the tier is degraded.

    A streak is broken only by a successful render (HTTP 200). Local refusals (per-IP slot full,
    timeouts) say nothing about artifact retrieval, so they neither extend nor end it.
    """
    if ARTIFACT_ROWS is not None:
        rows = ARTIFACT_ROWS
    else:
        code, body = api("/admin/api/requests?limit=25&model=gemini-image", tok)
        if code != 200:
            return
        try:
            rows = json.loads(body).get("items") or []
        except Exception:
            return
    streak, ups, newest = 0, set(), None
    for r in rows:
        if "artifact retrieval failed" in str(r.get("error") or ""):
            streak += 1
            ups.add(str(r.get("upstream_model") or "?"))
            if newest is None:      # rows arrive newest first: keep the first, not the last
                newest = r
            continue
        if int(r.get("status") or 0) == 200:
            break
    if streak < 3:
        speak(msgs, st, "artifact_streak", "ok",
              "✅ gemini-web2api: images render again — the newest image job did not end in "
              "'artifact retrieval failed'.", remind_after=24 * 3600)
        return
    free = all("Flash-Lite" in u or u == "?" for u in ups)
    if int(time.time()) - (int((newest or {}).get("ts") or 0) + LOG_TS_SKEW) > 6 * 3600:
        return      # stale streak: no image job has tried for 6 h, so this is not a live outage
    when = time.strftime("%d %b %H:%M UTC", time.gmtime(int((newest or {}).get("ts") or 0) + LOG_TS_SKEW))
    cause = ("every one of them came back on 3.5 Flash-Lite, the free path, which has no image "
             "tool — the account is out of paid allowance, so a cookie re-export will not help"
             if free else
             "upstream was %s, which CAN draw, so this is the CDN-link parser instead"
             % ", ".join(sorted(ups)))
    speak(msgs, st, "artifact_streak", "down-%d" % (3 if streak < 6 else 6 if streak < 12 else 12),
          "🖼🛑 gemini-web2api: %d image jobs in a row failed with 'artifact retrieval failed' "
          "(newest %s). %s. Do not restart anything for this; repeats at most every 6 h."
          % (streak, when, cause))


def read_state():
    try:
        return json.load(open(STATE))
    except Exception:
        return {}


def newest_canary_row(tok):
    """Newest request-log row for the canary model, or None. Ordered on the monotonic id: the
    `ts` field drifts behind the host clock (see LOG_TS_SKEW), so it cannot order rows."""
    code, body = api("/admin/api/requests?limit=10&model=%s" % CANARY_MODEL, tok)
    if code != 200:
        return None
    try:
        rows = json.loads(body).get("items") or []
    except Exception:
        return None
    if not rows:
        return None
    try:
        return max(rows, key=lambda r: int(r.get("id") or 0))
    except Exception:
        return None


def log_first_cause(tok, st):
    """Read the request log BEFORE spending a chat request on the canary.

    The log is the only honest source and reading it is free. When its newest canary row already
    names the cause and is newer than our previous sample, report that cause instead of asking
    Google again: a dead cookie needs a browser login and a slow model needs patience, so neither
    is helped by another request. Returns (cause, deciding log text) or (None, "").
    """
    row = newest_canary_row(tok)
    if not row:
        return None, ""
    try:
        ts = int(row.get("ts") or 0)
    except Exception:
        ts = 0
    if ts:
        # The log's `ts` is stamped by the proxy container, 2.5 h behind the host clock
        # (LOG_TS_SKEW), while last_sample_at/checked_at are written here with time.time().
        # Compare on one clock or every real row looks older than our last sample and the
        # log-first path never fires (GUL-1339 F-1).
        ts += LOG_TS_SKEW
    prev = int(st.get("last_sample_at") or st.get("checked_at") or 0)
    if ts and prev and ts < prev:
        return None, ""          # older than the last sample we took: not this run's answer
    err = str(row.get("error") or "")
    if DEAD_COOKIE.search(err):
        return "dead-cookie", err
    if SLOW_MODEL.search(err):
        return "slow-model", err
    return None, ""


def clear_inconclusive(st):
    """A real verdict ends the no-verdict streak; the next inconclusive sample must speak again."""
    for k in ("inconclusive_samples", "inconclusive_since",
              "canary_inconclusive", "canary_inconclusive_at",
              "canary_inconclusive_escalation", "canary_inconclusive_escalation_at"):
        st.pop(k, None)


def note_inconclusive(msgs, st, now, reason, fault):
    """Record a canary sample that reached NO verdict — a fault, never a green.

    Timestamps are refreshed because a sample WAS taken, entitlement goes unknown because the
    paid tier cannot be claimed, and healthy_since is dropped because the health clock is broken.
    degraded_accum_s is deliberately left alone: an inconclusive sample is evidence of neither
    degradation nor recovery, and note_entitlement() would credit (or clear) time it has no right
    to. The second consecutive sample is the one that escalates.
    """
    n = int(st.get("inconclusive_samples") or 0) + 1
    st["inconclusive_samples"] = n
    st.setdefault("inconclusive_since", now)
    st["entitlement"] = "unknown"
    st["checked_at"] = now
    st["last_sample_at"] = now
    st["last_canary_reason"] = str(reason)[:INCONCLUSIVE_REASON_MAX]
    st.pop("healthy_since", None)
    st.pop("canary", None)

    speak(msgs, st, "canary_inconclusive", "inconclusive",
          "⚠️ gemini-web2api canary: inconclusive — %s The paid tier stays UNKNOWN until a "
          "real sample answers." % fault)
    if n >= 2:
        speak(msgs, st, "canary_inconclusive_escalation", "escalated",
              "🛑 gemini-web2api: %d consecutive canary samples reached no verdict. The paid "
              "tier is UNKNOWN and the last real verdict is stale — this is not a quiet "
              "account, it is a blind check. Last cause: %s"
              % (n, st["last_canary_reason"]))


def write_state(d):
    try:
        json.dump(d, open(STATE, "w"))
    except Exception:
        pass


# ---------------------------------------------------------------- availability checks

def engine_check(msgs, st):
    """Can we even ask the engine? A wedged Docker daemon makes every other check meaningless:
    docker inspect/restart raise, and the old code swallowed that and returned — so a wedged
    engine looked exactly like a healthy one with nothing to do."""
    try:
        r = dk("info", "--format", "{{.ServerVersion}}", timeout=DOCKER_INFO_TIMEOUT)
        ver = (r.stdout or "").strip()
        ok = r.returncode == 0 and bool(ver)
        why = (r.stderr or "").strip().splitlines()[:1]
        why = why[0][:200] if why else "docker info gave no answer"
    except subprocess.TimeoutExpired:
        ok, ver, why = False, "", "docker info did not answer within %ds" % DOCKER_INFO_TIMEOUT
    except FileNotFoundError:
        ok, ver, why = False, "", "no docker CLI at %s" % DOCKER
    except Exception as e:
        ok, ver, why = False, "", repr(e)[:200]

    if ok:
        speak(msgs, st, "engine", "ok",
              "✅ Docker engine answering again (server %s)." % ver)
    else:
        speak(msgs, st, "engine", "cannot-ask",
              "🛑 WATCHDOG BLIND: cannot ask the Docker engine on the Max (%s). "
              "This is NOT 'nothing to do' — the containers may be wedged and nothing can be "
              "inspected or restarted from here. Restart the OrbStack engine on the M1 Max, "
              "then check http://127.0.0.1:8083/ and the gemini4 alias." % why)
    return ok


def proxy_probe():
    """One plain GET / with a 10 s budget. The engine can be perfectly healthy while the proxy
    inside it is hung — that is the failure that went unnoticed for 34 hours."""
    try:
        with urllib.request.urlopen(PROXY + "/", timeout=PROXY_PROBE_TIMEOUT) as r:
            d = json.loads(r.read().decode())
        if d.get("status") == "ok":
            return True, str(d.get("version", "?")), ""
        return False, "", "GET / returned status=%r" % d.get("status")
    except Exception as e:
        return False, "", repr(e)[:200]


def proxy_check(msgs, st, can_ask_engine):
    ok, ver, why = proxy_probe()
    if ok:
        speak(msgs, st, "proxy", "ok",
              "✅ gemini-web2api answering again (version %s)." % ver)
        return True

    # Not answering. Say so; then, if we can still talk to the engine, try to fix it and
    # report what the restart actually achieved (no optimistic claims).
    restarted = ""
    if can_ask_engine:
        try:
            status = dk("inspect", "-f", "{{.State.Status}}", "gemini-web2api").stdout.strip()
        except Exception as e:
            status = ""
            restarted = " (could not inspect: %s)" % repr(e)[:80]
        if status == "running":
            try:
                dk("restart", "gemini-web2api", timeout=RESTART_TIMEOUT)
                restarted = " Restarted the container."
            except Exception as e:
                restarted = " Restart attempt failed: %s" % repr(e)[:80]
        elif status:
            try:
                dk("start", "gemini-web2api", timeout=RESTART_TIMEOUT)
                restarted = " Container was '%s' — started it." % status
            except Exception as e:
                restarted = " Start attempt failed: %s" % repr(e)[:80]
        if restarted:
            time.sleep(5)
            again, ver2, _ = proxy_probe()
            restarted += (" Still not answering after that." if not again
                          else " It answers again now (version %s)." % ver2)

    speak(msgs, st, "proxy", "down",
          "🛑 gemini-web2api is NOT ANSWERING on %s (GET / failed: %s).%s "
          "Every agent using the gemini4 alias is broken until this is back."
          % (PROXY, why, restarted))
    return False


def image_after_recovery(msgs, st, tok, key):
    """The one test we could not run while the account was on the free tier: once the paid tier is
    back, does an IMAGE request actually come back with pixels? Fires exactly one small job at
    recovery and reports what the request log says — so "the tier is back" and "images work" are not
    assumed to be the same thing."""
    base_id = 0
    _, sbody = api("/admin/api/requests?limit=1&model=gemini-image", tok)
    try:
        base_id = int(json.loads(sbody)["items"][0]["id"])
    except Exception:
        pass
    body = json.dumps({"model": "gemini-image", "stream": False,
                       "messages": [{"role": "user",
                                     "content": "a plain grey server rack on a concrete floor, "
                                                "flat illustration, no text"}]}).encode()
    req = urllib.request.Request(PROXY + "/v1/chat/completions", data=body,
                                headers={"Authorization": "Bearer " + key,
                                         "Content-Type": "application/json"})
    t0 = time.time()
    http, text = 0, ""
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            http, text = r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        http, text = e.code, e.read().decode()
    except Exception as e:
        text = repr(e)

    ok = http == 200 and ('"error"' not in text[:200])
    up, ms = "", ""
    for _ in range(8):
        _, sbody = api("/admin/api/requests?limit=5&model=gemini-image", tok)
        try:
            rows = [i for i in json.loads(sbody)["items"] if int(i["id"]) > base_id]
        except Exception:
            rows = []
        if rows:
            top = max(rows, key=lambda i: int(i["id"]))
            up, ms = str(top.get("upstream_model")), str(top.get("total_ms"))
            break
        time.sleep(1)

    if ok:
        msgs.append("✅📷 gemini-web2api: paid tier is back AND image generation works "
                    "(upstream %s, %s ms, %.0fs wall). Nano banana is usable again."
                    % (up or "?", ms or "?", time.time() - t0))
    else:
        msgs.append("⚠️📷 gemini-web2api: the paid tier is back (text models answer as paid) but an "
                    "IMAGE request still fails — upstream %s: %s. That rules the account out and "
                    "points at the artifact/parser path, so this needs a real fix, not patience."
                    % (up or "?", (text or "")[:180].replace("\n", " ")))
    st["image_check_at"] = int(time.time())
    st["image_check_ok"] = ok


def clock_check(msgs, st, can_ask_engine):
    """The OrbStack VM's clock drifts (measured 1 h 43 m behind the host, growing). That corrupts
    every log correlation, and a clock that far behind can also confuse cookie-expiry and TLS
    checks inside the containers. Cheap to measure: ask a throwaway container for epoch seconds."""
    if not can_ask_engine:
        return
    try:
        out = dk("run", "--rm", "--entrypoint", "/bin/sh", "zeroclaw:mattermost",
                 "-c", "date +%s", timeout=60).stdout.strip()
        vm = int(out.splitlines()[-1])
    except Exception:
        return                      # image missing or engine busy — not worth an alert of its own
    drift = int(time.time()) - vm
    if abs(drift) > 120:
        speak(msgs, st, "clock", "drift",
              "⚠️ the OrbStack VM's clock is %d min %s the host. Every log timestamp out of that "
              "container is offset by the same amount, which makes cross-agent timeline comparisons "
              "wrong (it has already produced three false 'your probe never arrived' readings). An "
              "engine restart resyncs it."
              % (abs(drift) // 60, "behind" if drift > 0 else "ahead of"))
    else:
        speak(msgs, st, "clock", "ok", "✅ OrbStack VM clock back in sync (±%ds)." % abs(drift))


def pin_check(msgs, st, can_ask_engine):
    """This fix is only as good as the next `docker run`. Warn if the live container drifts back
    to a moving tag or loses its restart policy."""
    if not can_ask_engine:
        return
    try:
        out = dk("inspect", "-f", "{{.Config.Image}}|{{.HostConfig.RestartPolicy.Name}}",
                 "gemini-web2api").stdout.strip()
    except Exception:
        return
    img, _, restart = out.partition("|")
    if not img:
        return
    problems = []
    if "@sha256:" not in img:
        problems.append("image is not pinned (%s)" % img)
    if restart not in ("unless-stopped", "always"):
        problems.append("restart policy is '%s'" % restart)
    if problems:
        speak(msgs, st, "pin", "drift",
              "⚠️ gemini-web2api runtime drift: %s. Re-apply ~/gemini2api/docker-compose.yml "
              "(pinned digest + restart unless-stopped), then `docker compose up -d`."
              % "; ".join(problems))
    else:
        speak(msgs, st, "pin", "ok", "✅ gemini-web2api pinned and restart-policied again.")


def container_check(msgs, st):
    """Keep the ZeroClaw container alive: restart if the container or its gateway is down."""
    try:
        status = dk("inspect", "-f", "{{.State.Status}}", "zeroclaw").stdout.strip()
    except Exception as e:
        # The engine check has already reported the 'cannot ask' fault; do not double-report,
        # but do not pretend this is fine either.
        speak(msgs, st, "container", "unknown",
              "⚠️ zeroclaw state unknown — docker inspect did not answer (%s)." % repr(e)[:120],
              remind_after=REMIND_AFTER)
        return
    if not status:
        # Empty output is not a state. Saying "the container was ''" and firing a restart
        # against a daemon that cannot answer is noise dressed up as a diagnosis.
        speak(msgs, st, "container", "unknown",
              "⚠️ zeroclaw state unknown — docker inspect returned nothing.",
              remind_after=REMIND_AFTER)
        return
    if status != "running":
        try:
            dk("restart", "zeroclaw", timeout=RESTART_TIMEOUT)
        except Exception:
            pass
        speak(msgs, st, "container", "was-%s" % status,
              "🔧 zeroclaw container was '%s' — restarted it." % status)
        return
    try:
        h = urllib.request.urlopen("http://127.0.0.1:42617/health", timeout=15).read().decode()
        healthy = '"status":"ok"' in h
    except Exception:
        healthy = False
    if not healthy:
        try:
            dk("restart", "zeroclaw", timeout=RESTART_TIMEOUT)
        except Exception:
            pass
        speak(msgs, st, "container", "unhealthy-restarted",
              "🔧 zeroclaw gateway was unhealthy — restarted the container.")
    else:
        speak(msgs, st, "container", "healthy", "✅ zeroclaw healthy again.")


def harvest_firefox():
    """Return a 'k=v; ...' cookie string from the Firefox profile, or None.

    Pick the profile that actually HAS a cookies.sqlite, newest first, and prefer a
    `.default-release` profile over a stale `.default` one. The old rule (newest profile
    DIRECTORY by mtime) silently chose a `.default` profile with no cookie DB at all, which
    reads as "no usable cookie" even while the live login sits in default-release.
    """
    profs = glob.glob(os.path.expanduser("~/Library/Application Support/Firefox/Profiles/*default*"))
    profs = [p for p in profs if os.path.exists(os.path.join(p, "cookies.sqlite"))]
    if not profs:
        return None
    release = [p for p in profs if p.endswith(".default-release")]
    src = os.path.join(max(release or profs, key=os.path.getmtime), "cookies.sqlite")
    if not os.path.exists(src):
        return None
    tmp = SCRATCH + "/_guard_ck.sqlite"
    try:
        shutil.copy(src, tmp)
        try:
            shutil.copy(src + "-wal", tmp + "-wal")
        except Exception:
            pass
        con = sqlite3.connect(tmp)
        rows = dict(con.execute(
            "SELECT name, value FROM moz_cookies WHERE host LIKE '%google.com'").fetchall())
        con.close()
    except Exception:
        return None
    finally:
        for f in (tmp, tmp + "-wal"):
            if os.path.exists(f):
                os.remove(f)
    if len([w for w in WANT if rows.get(w)]) < 6:
        return None
    return "; ".join("%s=%s" % (w, rows[w]) for w in WANT if rows.get(w))


def main():
    # Credentials are NOT allowed to be a precondition for the availability checks: a broken
    # env file used to abort the whole run (210 consecutive failures once), which is the same
    # blind watchdog by another route.
    try:
        E = env()
    except Exception:
        E = {}
    tok, key = E.get("ADMIN_TOKEN", ""), E.get("GEMINI_WEB_API_KEY", "")
    st = read_state()
    msgs = []

    # 1) availability first — a wedged engine or a hung proxy invalidates everything below
    can_ask_engine = engine_check(msgs, st)
    container_check(msgs, st)
    pin_check(msgs, st, can_ask_engine)
    clock_check(msgs, st, can_ask_engine)
    proxy_ok = proxy_check(msgs, st, can_ask_engine)

    if SKIP_COOKIES:
        write_state(st)
        print("\n".join(m for m in msgs if m))
        return

    if not tok or not key:
        speak(msgs, st, "creds", "missing",
              "⚠️ gemini-web2api guard: credentials unreadable at %s — cookie pool and paid-tier "
              "checks are SKIPPED (proxy availability above is still checked)." % ENVF)
        write_state(st)
        print("\n".join(m for m in msgs if m))
        return

    if not proxy_ok:
        # Cannot reach the admin API either; do not claim "no valid cookie" — that is a
        # different diagnosis and it is exactly the misread that hid the wedge.
        write_state(st)
        print("\n".join(m for m in msgs if m))
        return

    artifact_check(msgs, st, tok)

    ck = harvest_firefox()
    if not ck:
        speak(msgs, st, "last_pool", "empty-harvest",
              "⚠️ gemini-web2api: no usable cookie found in the Firefox profile "
              "(no google.com cookies / no profile). Paid models are unavailable; "
              "requests fall back to anonymous 3.5 Flash-Lite.")
        write_state(st)
        print("\n".join(m for m in msgs if m))
        return

    h = hashlib.sha256(ck.encode()).hexdigest()[:16]

    # A rate-limited account must not be re-imported on a schedule: each import costs a Google
    # auth round-trip (the validity check), and while the account answers 429 that check fails and
    # the candidate is deleted again — churn that feeds the very throttle we are waiting out.
    # Only the import pauses; the canary below keeps running so recovery is still detected.
    degraded = st.get("entitlement") == "degraded"
    if h != st.get("cookie_hash") and degraded:
        speak(msgs, st, "import_hold", "paused",
              "⏸ gemini-web2api: paid tier degraded — cookie re-import paused on purpose. "
              "Importing now just re-validates against a throttled account (429) and deletes the "
              "candidate again. It resumes by itself when the tier comes back.")
    elif h != st.get("cookie_hash"):
        st.pop("import_hold", None)
        # 1) add the candidate FIRST — never drop a working cookie before the new one proves itself
        st_code, body = api("/admin/api/cookies", tok, "POST",
                            {"label": "wojtek-ai-pro", "cookie": ck,
                             "note": "auto re-import by cookie guard"})
        new_id = None
        try:
            new_id = json.loads(body).get("id")
        except Exception:
            pass
        if not new_id:
            msgs.append("⚠️ gemini-web2api guard: could not add the harvested cookie (HTTP %s). "
                        "Existing pool left untouched." % st_code)
            write_state(st)
            print("\n".join(m for m in msgs if m))
            return

        c_code, cbody = api("/admin/api/cookies/%s/check" % new_id, tok, "POST")
        ok = False
        try:
            ok = bool(json.loads(cbody).get("ok"))
        except Exception:
            pass

        if not ok:
            # 2a) candidate is dead — remove it, keep whatever was already working
            api("/admin/api/cookies/%s" % new_id, tok, "DELETE")
            speak(msgs, st, "rejected_hash", h,
                  "⚠️ gemini-web2api guard: the Firefox cookie is present but NOT a valid login "
                  "(browser session expired). Paid models unavailable — open Firefox, visit "
                  "gemini.google.com to refresh the session. Previous pool entry kept.")
            write_state(st)
        else:
            # 2b) candidate verified — now retire the older entries
            s_code, sbody = api("/admin/api/cookies", tok)
            try:
                old = [i["id"] for i in json.loads(sbody)["items"] if i["id"] != new_id]
            except Exception:
                old = []
            for oid in old:
                api("/admin/api/cookies/%s" % oid, tok, "DELETE")
            st["cookie_hash"] = h
            msgs.append("✅ gemini-web2api: fresh cookie imported and validated"
                        + (" (retired %d stale entry/ies)." % len(old) if old else "."))

    # canary: what did the server ACTUALLY serve? (the only trustworthy identity signal)
    # Skip it when the pool has no valid cookie — with no login the proxy correctly refuses
    # paid models, and firing anyway produces a misleading "canary failed" error.
    s_code, sbody = api("/admin/api/cookies", tok)
    if s_code == 0:
        # proxy answered GET / a moment ago but the admin API does not — say that plainly
        speak(msgs, st, "admin", "unreachable",
              "⚠️ gemini-web2api answers GET / but its admin API does not (%s). "
              "Cookie pool and entitlement cannot be checked." % sbody[:120])
        write_state(st)
        print("\n".join(m for m in msgs if m))
        return
    st.pop("admin", None)
    try:
        n_valid = json.loads(sbody).get("enabled", 0)
    except Exception:
        n_valid = 0
    if not n_valid:
        speak(msgs, st, "entitlement", "no-cookie",
              "⚠️ gemini-web2api: no valid cookie in the pool — paid models (4 Argon, 3.1 Pro, "
              "3.8 Flash) are unavailable; anything using the proxy is on anonymous "
              "3.5 Flash-Lite.")
        st["checked_at"] = int(time.time())
        write_state(st)
        print("\n".join(m for m in msgs if m))
        return

    # While the paid tier is degraded the account is usually RATE LIMITED, and every canary is
    # another premium-model request that works against the cooldown. Back off to hourly probes
    # and stay silent until it recovers.
    now = int(time.time())
    if st.get("entitlement") == "degraded":
        st.setdefault("degraded_since", now)
    if st.get("entitlement") == "degraded" and (now - st.get("last_canary", 0)) < 3600:
        degraded_escalation(msgs, st)
        write_state(st)
        print("\n".join(m for m in msgs if m))
        return
    st["last_canary"] = now

    # GUL-1339: the log can name the cause for free. Read it first; a chat request spent on a
    # known-dead cookie or a known-slow model changes nothing but the request budget.
    cause, evidence = log_first_cause(tok, st)
    if cause:
        fault = ("the request log says the cookie is dead — SNlM0e is missing (the browser "
                 "session expired or is not signed in), so no canary was sent."
                 if cause == "dead-cookie" else
                 "the request log says the model is slow — Client.Timeout / context deadline "
                 "exceeded, so no canary was sent.")
        note_inconclusive(msgs, st, int(time.time()), evidence, fault)
        write_state(st)
        print("\n".join(m for m in msgs if m))
        return

    # Attribute the canary to ITS OWN log row, not to "whatever is newest". Two traps here:
    #  - image/video jobs land in the same log, so a blind limit=1 once reported an image job
    #    ('Nano Banana') as a paid-tier downgrade;
    #  - the row id is monotonic, the `ts` field is NOT reliable (observed drifting ~200 s
    #    behind the host clock), so we key on id > baseline and filter by model.
    base_id = 0
    s_code, sbody = api("/admin/api/requests?limit=1", tok)
    try:
        base_id = int(json.loads(sbody)["items"][0]["id"])
    except Exception:
        pass

    body = json.dumps({"model": CANARY_MODEL,
                       "messages": [{"role": "user", "content": "ping"}]}).encode()
    req = urllib.request.Request(PROXY + "/v1/chat/completions", data=body,
                                headers={"Authorization": "Bearer " + key,
                                         "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=120).read()
    except Exception as e:
        note_inconclusive(msgs, st, int(time.time()),
                          "canary request failed: %r" % e,
                          "the canary request failed (%r)." % e)
        write_state(st)
        print("\n".join(m for m in msgs if m))
        return

    up = ""
    for _ in range(10):
        s_code, sbody = api("/admin/api/requests?limit=10&model=%s" % CANARY_MODEL, tok)
        try:
            rows = [i for i in json.loads(sbody)["items"] if int(i["id"]) > base_id]
        except Exception:
            rows = []
        if rows:
            up = max(rows, key=lambda i: int(i["id"])).get("upstream_model") or ""
            break
        time.sleep(1)

    if not up:
        note_inconclusive(msgs, st, int(time.time()),
                          "canary went out but no log row matched it within 8 s",
                          "the canary went out but no log row matched it within 8 s, so the "
                          "served model cannot be verified.")
        write_state(st)
        print("\n".join(m for m in msgs if m))
        return
    st.pop("canary", None)

    paid_now = any(p in up for p in PAID)
    clear_inconclusive(st)
    was_degraded = st.get("entitlement") == "degraded"

    # Flapping is its own fault. Brief recoveries followed by fresh downgrades mean the account's
    # paid allowance is being burned by fleet load — a capacity problem, not an outage, and waiting
    # for a cooldown will never fix it.
    prev = st.get("entitlement")
    if prev is not None and (prev == "degraded") != (not paid_now):
        ts_log = [t for t in (st.get("transitions") or []) if now - t < 6 * 3600]
        ts_log.append(now)
        st["transitions"] = ts_log
    else:
        st["transitions"] = [t for t in (st.get("transitions") or []) if now - t < 6 * 3600]
    if len(st.get("transitions") or []) >= 4:
        speak(msgs, st, "flap", "flapping",
              "🛑 gemini-web2api: the paid tier has flipped %d times in 6 h. That is not an outage to "
              "wait out — the account's allowance is being spent by fleet traffic (long paid-chat runs "
              "count, not just images), so every quiet window gets re-burned within minutes. This needs "
              "a capacity decision: pace the heavy paid-model users, or add a second account/API key."
              % len(st["transitions"]))

    if up and not paid_now and st.get("entitlement") != "degraded":
        # Deliberately does NOT say "re-export the cookie". A paid model coming back cheap is
        # almost always a Google RATE LIMIT, and a fresh login does not restore the tier (tested).
        # Point the reader at the one place that can tell them apart: the browser.
        msgs.append("🛑 gemini-web2api: PAID TIER DOWNGRADED — asked for %s, server served '%s'. "
                    "Clients using this proxy are silently on a cheaper model. Likely a Google "
                    "rate limit, NOT a stale cookie — open gemini.google.com in the browser and "
                    "look for a usage notice with a reset time. Only re-import the cookie if the "
                    "browser also shows no login."
                    % (CANARY_MODEL, up))
    elif paid_now and st.get("entitlement") != "ok":
        msgs.append("✅ gemini-web2api: paid tier confirmed — %s served as '%s'." % (CANARY_MODEL, up))
    st["entitlement"] = "ok" if paid_now else "degraded"
    note_entitlement(st, paid_now, now, was_degraded)
    degraded_escalation(msgs, st)
    st["last_upstream"] = up
    st["checked_at"] = int(time.time())

    # recovery is the only moment the image path can be tested honestly — see image_after_recovery
    if paid_now and was_degraded:
        image_after_recovery(msgs, st, tok, key)

    write_state(st)
    print("\n".join(m for m in msgs if m))


if __name__ == "__main__":
    main()
