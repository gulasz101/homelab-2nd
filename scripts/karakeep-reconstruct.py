#!/usr/bin/env python3
"""Reconstruct Karakeep bookmarks + RSS feeds from archived sources.

Karakeep's SQLite DB is the live store, but it is only *derived* state:
- bookmark history lives in the Obsidian vault as karakeep/<day>/manifest.json
  plus the morning-brew markdown posts (for days without a manifest);
- the RSS feed list survives in Hermes conversation history.

This script rebuilds both through the Karakeep REST API. It is the executable
form of ADR-016. It never prints the API key.

Usage:
    export KARAKEEP_API_KEY=ak2_...
    export KARAKEEP_SERVER_ADDR=https://keep.voitech.dev
    python3 karakeep-reconstruct.py --bookmarks            # import bookmarks
    python3 karakeep-reconstruct.py --feeds                # recreate RSS feeds
    python3 karakeep-reconstruct.py --bookmarks --feeds

Env:
    KARAKEEP_API_KEY        required
    KARAKEEP_SERVER_ADDR    default https://keep.voitech.dev
    OBSIDIAN_VAULT_PATH     default ~/wojtek.second.brain.obsidian.vault
    MORNING_BREW_DIR        default ~/Projects/morning-brew/content
"""
import argparse, collections, datetime, json, os, re, sys, time, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

API = os.environ.get("KARAKEEP_SERVER_ADDR", "https://keep.voitech.dev").rstrip("/") + "/api/v1"
KEY = os.environ.get("KARAKEEP_API_KEY", "").strip()
UA = "Mozilla/5.0 (compatible; homelab/karakeep-reconstruct)"

VAULT = os.environ.get("OBSIDIAN_VAULT_PATH", os.path.expanduser("~/wojtek.second.brain.obsidian.vault"))
BREW = os.environ.get("MORNING_BREW_DIR", os.path.expanduser("~/Projects/morning-brew/content"))

# Recovered from the pre-outage rssFeeds table (Hermes history). channel_ids were
# re-resolved from the channel names; edit here if either changes.
FEEDS = [
    ("niebezpiecznik.pl", "http://feeds.feedburner.com/niebezpiecznik?format=xml"),
    ("opensourceprojects.dev", "https://www.opensourceprojects.dev/rss"),
    ("9to5linux", "https://9to5linux.com/feed"),
    ("linuxlinks", "https://www.linuxlinks.com/feed/"),
    ("The Prime Time YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UCUyeluBRhGPCW4rPe_UvBZQ"),
    ("Framework YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UCDiKw3GnFIwyNJBzhCoRI-Q"),
    ("Jeff Feeling YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UCR-DXc1voovS8nhAvccRZhg"),
    ("T3.gg YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UCbRP3c757lWg9M-U7TyEkXA"),
    ("Better Stack YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UCkVfrGwV-iG9bSsgCbrNPxQ"),
    ("Fireship YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UC2Xd-TjJByJyK2w1zNwY0zQ"),
    ("NetworkChuck YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UC9x0AN7BWHpCDHSm9NiJFJQ"),
    ("Macho Nacho Productions YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UC4CsqctrGOn4NTz09sAhXwQ"),
    ("Mischa van der Burg YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UCDAck-gFPtrgTx_qp59-bQA"),
    ("Kai Lentit YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UCi8C7TNs2ohrc6hnRQ5Sn2w"),
    ("typecraft @ YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UCo71RUe6DX4w-Vd47rFLXPg"),
    ("Brodie Robertson @ YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UCld68syR8Wi-GY_n4CaoJGA"),
    ("Craft Computing @ YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UCp3yVOm6A55nx65STpm3tXQ"),
    ("Less Bitter @ YT", "https://www.youtube.com/feeds/videos.xml?channel_id=UCvjBQ_VzhInndfu2L12mCXA"),
]

RSS_HOSTS = ("linuxlinks.com", "opensourceprojects.dev", "9to5linux.com", "niebezpiecznik.pl")


def req(path, data=None, method=None):
    body = json.dumps(data).encode() if data is not None else None
    r = urllib.request.Request(API + path, data=body, method=method or ("POST" if body else "GET"),
                               headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json",
                                        "Accept": "application/json", "User-Agent": UA})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                return resp.status, json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            txt = e.read().decode()[:200]
            if e.code in (429, 500, 502, 503, 504):
                time.sleep(1.5 * (attempt + 1)); continue
            return e.code, txt
        except Exception as e:
            if attempt == 3:
                return "ERR", str(e)[:150]
            time.sleep(1.0 * (attempt + 1))


def host(url):
    return re.sub(r"^https?://", "", url).split("/")[0].replace("www.", "").lower()


def iso(day):
    d = datetime.date.fromisoformat(day)
    return datetime.datetime(d.year, d.month, d.day, 12, 0, 0, tzinfo=datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def classify(url, publisher):
    p = (publisher or "").lower()
    if any(h in host(url) for h in RSS_HOSTS) or "youtube" in host(url) or "youtu.be" in host(url):
        return "rss"
    return "rss" if any(k in p for k in ("linuxlinks", "open-source projects", "youtube", "9to5linux", "niebezpiecznik")) else "web"


def build_dataset():
    recs = {}
    for f in sorted(__import__("glob").glob(f"{VAULT}/karakeep/*/manifest.json")):
        day = os.path.basename(os.path.dirname(f))
        for b in json.load(open(f)).get("bookmarks", []):
            url = (b.get("url") or "").strip()
            if url and (url not in recs or day < recs[url]["day"]):
                recs[url] = {"url": url, "title": (b.get("title") or "")[:1000] or None,
                             "publisher": b.get("publisher"), "day": day, "origin": "manifest",
                             "type": "video" if (b.get("type") == "video" or b.get("kind") == "video") else "article"}
    man_days = {os.path.basename(os.path.dirname(f)) for f in __import__("glob").glob(f"{VAULT}/karakeep/*/manifest.json")}
    for f in sorted(__import__("glob").glob(f"{BREW}/*.md")):
        day = os.path.basename(f).replace("-morning-brew.md", "")
        if not re.match(r"^\d{4}-\d{2}-\d{2}$", day) or day in man_days:
            continue
        cur = None
        for ln in open(f, encoding="utf-8", errors="ignore"):
            h = re.match(r"^##\s+(?:\d+\.\s*)?(.+)$", ln)
            if h:
                cur = re.split(r"\s+—\s+by\s+", h.group(1), maxsplit=1)[0].strip()
            m = re.search(r"\*\*Source:\*\*\s*(?:\[[^\]]*\]\()?(https?://[^\s)\]>`]+)", ln) or re.search(r"🔗\s*(https?://[^\s)\]>`]+)", ln)
            if m and cur:
                url = m.group(1).strip(".,")
                if url not in recs or day < recs[url]["day"]:
                    recs[url] = {"url": url, "title": cur[:1000], "publisher": None, "day": day, "origin": "morning-brew",
                                 "type": "video" if "youtu" in host(url) else "article"}
    out = []
    for r in recs.values():
        r["createdAt"] = iso(r["day"]); r["source"] = classify(r["url"], r["publisher"]); out.append(r)
    return out


def import_bookmarks(state_path=None):
    ds = build_dataset()
    state = json.load(open(state_path)) if state_path and os.path.exists(state_path) else {}
    todo = [r for r in ds if r["url"] not in state]
    print(f"dataset={len(ds)} already_done={len(ds)-len(todo)} to_import={len(todo)}")
    counts = collections.Counter()

    def work(r):
        st, d = req("/bookmarks", {"type": "link", "url": r["url"], "title": r.get("title"),
                                   "createdAt": r["createdAt"], "source": r["source"], "crawlPriority": "low"})
        return st, r["url"], d

    with ThreadPoolExecutor(max_workers=6) as ex:
        for fut in as_completed([ex.submit(work, r) for r in todo]):
            st, url, d = fut.result()
            if st in (200, 201):
                counts["duplicate" if isinstance(d, dict) and d.get("alreadyExists") else "created"] += 1
                state[url] = d.get("id") if isinstance(d, dict) else True
            else:
                counts["failed"] += 1
                print("  FAIL", st, url[:90], str(d)[:120])
            if (counts["created"] + counts["duplicate"] + counts["failed"]) % 100 == 0:
                print("  progress", dict(counts))
                if state_path:
                    json.dump(state, open(state_path, "w"))
    if state_path:
        json.dump(state, open(state_path, "w"))
    print("bookmarks done:", dict(counts))


def import_feeds():
    for name, url in FEEDS:
        st, d = req("/feeds", {"name": name, "url": url, "enabled": True})
        print(f"  {st} {name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bookmarks", action="store_true")
    ap.add_argument("--feeds", action="store_true")
    ap.add_argument("--state", default=None, help="resume-state JSON path")
    a = ap.parse_args()
    if not KEY:
        sys.exit("KARAKEEP_API_KEY is required")
    if not (a.bookmarks or a.feeds):
        sys.exit("pass --bookmarks and/or --feeds")
    if a.bookmarks:
        import_bookmarks(a.state)
    if a.feeds:
        import_feeds()


if __name__ == "__main__":
    main()
