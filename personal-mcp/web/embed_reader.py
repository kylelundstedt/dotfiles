#!/usr/bin/env python3
"""Embed Reader documents via the local LM Studio endpoint -> embeddings.jsonl.

Incremental by default: only embeds docs listed in sources/_changed_ids.json
(written by pull_reader.py) plus any doc missing a vector, then upserts into
embeddings.jsonl by id. Use --all to re-embed everything.

Mirrors msgvault's vectors.db approach, reusing the same endpoint/model as
email/config.toml (nomic-embed-text v1.5, dim 768). nomic requires task prefixes:
documents -> "search_document: ", queries -> "search_query: " (see semantic.sh).

Usage:
  python3 embed_reader.py            # incremental (changed + missing)
  python3 embed_reader.py --all      # re-embed all docs
"""
import json, os, sys, urllib.request

# Data lives in the archive (this code is versioned in the repo, separate from data).
WEB_ARCHIVE = os.environ.get("WEB_ARCHIVE_DIR") or os.path.expanduser("~/archives/web")
SRC = os.path.join(WEB_ARCHIVE, "sources")
DOCS = os.path.join(SRC, "reader-documents.jsonl")
OUT = os.path.join(SRC, "embeddings.jsonl")
CHANGED = os.path.join(SRC, "_changed_ids.json")
ENDPOINT = "http://localhost:1234/v1/embeddings"
MODEL = "text-embedding-nomic-embed-text-v1.5@q8_0"
BATCH = 64
MAXCHARS = 6000  # ~nomic context budget


def embed(inputs):
    body = json.dumps({"model": MODEL, "input": inputs}).encode()
    req = urllib.request.Request(ENDPOINT, data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.load(r)
    return [e["embedding"] for e in d["data"]]


def doc_input(d):
    parts = [d.get("title") or "", d.get("summary") or "", d.get("text") or ""]
    return "search_document: " + " ".join(p for p in parts if p)[:MAXCHARS]


def load_docs():
    docs = {}
    for line in open(DOCS):
        line = line.strip()
        if line:
            d = json.loads(line)
            docs[d["id"]] = d
    return docs


def load_embeddings():
    emb = {}
    if os.path.exists(OUT):
        for line in open(OUT):
            line = line.strip()
            if line:
                e = json.loads(line)
                emb[e["id"]] = e["embedding"]
    return emb


def write_embeddings(emb):
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        for did, v in emb.items():
            f.write(json.dumps({"id": did, "embedding": v}) + "\n")
    os.replace(tmp, OUT)


def main():
    all_mode = "--all" in sys.argv
    docs = load_docs()
    emb = {} if all_mode else load_embeddings()

    if all_mode:
        targets = list(docs)
    else:
        changed = set(json.load(open(CHANGED))) if os.path.exists(CHANGED) else set()
        missing = set(docs) - set(emb)
        targets = [d for d in docs if d in changed or d in missing]
        # drop vectors for docs no longer present
        emb = {k: v for k, v in emb.items() if k in docs}

    n = len(targets)
    print(f"embedding {n} docs ({'all' if all_mode else 'incremental'})...", file=sys.stderr)
    if n == 0:
        write_embeddings(emb)
        print("done, 0 changed")
        return

    dim = None
    for i in range(0, n, BATCH):
        batch_ids = targets[i:i + BATCH]
        vecs = embed([doc_input(docs[d]) for d in batch_ids])
        for did, v in zip(batch_ids, vecs):
            emb[did] = v
            dim = len(v)
        print(f"  {min(i + BATCH, n)}/{n}", file=sys.stderr)
    write_embeddings(emb)
    print(f"done, dim={dim}, {len(emb)} total vectors")


if __name__ == "__main__":
    main()
