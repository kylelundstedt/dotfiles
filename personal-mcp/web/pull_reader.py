#!/usr/bin/env python3
"""Pull Readwise Reader documents -> JSONL (incremental merge by default).

Source of record for ~/archives/web. Mirrors the email/calendar pattern: the
cloud service (Readwise Reader) is the source; this writes an independent local
snapshot. HTML is stripped to plain text for search.

Incremental: fetches only docs updated since the last successful pull (state in
sources/_pull_state.json), upserts them into reader-documents.jsonl by id, and
records the changed ids in sources/_changed_ids.json so embed_reader.py only
re-embeds what changed. First run (no state) does a full pull.

Note: incremental keeps docs deleted from Reader (it's an archive). Moves and
edits propagate because they bump updated_at.

Token: env READWISE_TOKEN, else ~/.config/readwise/token.

Usage:
  python3 pull_reader.py                       # incremental (default)
  python3 pull_reader.py --full                # full re-pull from scratch
  python3 pull_reader.py --updated-after ISO   # explicit since (still merges)
"""
import json, sys, time, os, urllib.request, urllib.error
from datetime import datetime, timezone
from html.parser import HTMLParser

TOKEN_PATH = os.path.expanduser("~/.config/readwise/token")
TOKEN_FALLBACK = os.path.expanduser(
    "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/md/"
    ".obsidian/plugins/readwise-official/data.json")
# Data lives in the archive (this code is versioned in the repo, separate from data).
WEB_ARCHIVE = os.environ.get("WEB_ARCHIVE_DIR") or os.path.expanduser("~/archives/web")
SRC = os.path.join(WEB_ARCHIVE, "sources")
OUT = os.path.join(SRC, "reader-documents.jsonl")
STATE = os.path.join(SRC, "_pull_state.json")
CHANGED = os.path.join(SRC, "_changed_ids.json")
API = "https://readwise.io/api/v3/list/"


class _Text(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip += 1

    def handle_endtag(self, tag):
        if tag in ("script", "style") and self._skip:
            self._skip -= 1

    def handle_data(self, data):
        if not self._skip:
            self.parts.append(data)


def html_to_text(html):
    if not html:
        return ""
    p = _Text()
    try:
        p.feed(html)
    except Exception:
        return html
    return " ".join(" ".join(p.parts).split())


def token():
    if os.environ.get("READWISE_TOKEN"):
        return os.environ["READWISE_TOKEN"].strip()
    if os.path.exists(TOKEN_PATH):
        return open(TOKEN_PATH).read().strip()
    return json.load(open(TOKEN_FALLBACK))["token"]  # transition fallback


def load_existing():
    docs = {}
    if os.path.exists(OUT):
        for line in open(OUT):
            line = line.strip()
            if line:
                d = json.loads(line)
                docs[d["id"]] = d
    return docs


def write_all(docs):
    # Newest first by updated_at, so the file reads sensibly by hand.
    ordered = sorted(docs.values(), key=lambda d: d.get("updated_at") or "", reverse=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        for d in ordered:
            f.write(json.dumps(d, ensure_ascii=False) + "\n")
    os.replace(tmp, OUT)


def fetch(updated_after):
    tok = token()
    cursor = None
    results = []
    while True:
        params = ["withHtmlContent=true"]
        if cursor:
            params.append(f"pageCursor={cursor}")
        if updated_after:
            params.append(f"updatedAfter={updated_after}")
        url = API + "?" + "&".join(params)
        req = urllib.request.Request(url, headers={"Authorization": f"Token {tok}"})
        for _ in range(5):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    d = json.load(r)
                break
            except urllib.error.HTTPError as e:
                if e.code == 429:
                    wait = int(e.headers.get("Retry-After", "5"))
                    print(f"  rate-limited, sleeping {wait}s", file=sys.stderr)
                    time.sleep(wait + 1)
                    continue
                raise
        else:
            raise SystemExit("too many retries")
        for doc in d.get("results", []):
            doc["text"] = html_to_text(doc.get("content") or doc.get("html_content") or "")
            results.append(doc)
        cursor = d.get("nextPageCursor")
        print(f"  fetched {len(results)} updated docs...", file=sys.stderr)
        if not cursor:
            break
        time.sleep(0.5)
    return results


def main():
    os.makedirs(SRC, exist_ok=True)
    full = "--full" in sys.argv
    since = None
    if "--updated-after" in sys.argv:
        since = sys.argv[sys.argv.index("--updated-after") + 1]
    elif not full and os.path.exists(STATE) and os.path.exists(OUT):
        since = json.load(open(STATE)).get("last_pull_at")
    # No state / no existing file / --full => since stays None => full pull.

    run_start = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    mode = "full" if not since else f"incremental since {since}"
    print(f"mode: {mode}", file=sys.stderr)

    existing = {} if full else load_existing()
    fetched = fetch(since)

    for doc in fetched:
        existing[doc["id"]] = doc
    write_all(existing)

    json.dump([d["id"] for d in fetched], open(CHANGED, "w"))
    json.dump({"last_pull_at": run_start, "total_docs": len(existing),
               "changed_this_run": len(fetched)}, open(STATE, "w"), indent=2)

    print(f"{len(fetched)} changed, {len(existing)} total")


if __name__ == "__main__":
    main()
