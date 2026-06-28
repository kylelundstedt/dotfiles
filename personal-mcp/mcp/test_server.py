"""Tests for the personal-mcp server logic.

Integration-style: runs against the live local archives on klundstedt-mini, so it
locks in the correctness-bearing behavior (email dedup, timestamp sanitization,
item_id mapping, per-UID calendar collapse) without mocking the data.

Skips cleanly where the data — or the embedding endpoint — isn't present, so the
file is safe to run anywhere (CI, another machine).

Run:  uv run --group dev pytest test_server.py -q   (from personal-mcp/mcp/)
"""
import os
import urllib.request

import pytest

import server


def _has(path):
    return os.path.exists(path)


def _embed_up():
    try:
        urllib.request.urlopen(server.EMBED_ENDPOINT.replace("/embeddings", "/models"), timeout=3)
        return True
    except Exception:
        return False


# Whole module needs the local archives present.
pytestmark = pytest.mark.skipif(
    not (_has(server.HUB_DB) and _has(server.MSG_DB)),
    reason="local archives not present (not the archive host)",
)


# --- pure logic -------------------------------------------------------------

def test_item_id_prefixes():
    assert server._item_id("email", 5) == "email:5"
    assert server._item_id("imessage", 7) == "imessage:7"
    assert server._item_id("sms", 9) == "sms:9"
    assert server._item_id(None, 1) == "email:1"  # unknown type falls back to email:


# --- query_messages dedup (the count bug this session fixed) ----------------

def test_query_messages_dedups_cross_source_email():
    # Amanda Reed <amanda@palomarventures.com> appears 3x raw in msgvault
    # (one "Tom Brady Raffle" email ingested from two sources). Dedup -> 2.
    r = server.do_query_messages(sender="amanda reed", source="email")
    assert r["count"] == 2
    assert all(row["item_id"].startswith("email:") for row in r["results"])
    assert all(isinstance(row["from_me"], bool) for row in r["results"])
    ids = [row["item_id"] for row in r["results"]]
    assert len(ids) == len(set(ids))  # no duplicate rows returned


def test_sms_not_deduped():
    # iMessage/SMS are keyed by id in the dedup partition (single ingest source),
    # so the tool count must equal the raw row count — only email collapses.
    raw = server._sqlite_rows(
        server.MSG_DB, "SELECT count(*) AS n FROM messages WHERE message_type = 'sms'"
    )[0]["n"]
    assert server.do_query_messages(source="sms", limit=1)["count"] == raw


def test_query_messages_count_ge_returned_and_capped():
    r = server.do_query_messages(source="sms", limit=10)
    assert r["count"] >= r["returned"]
    assert r["returned"] <= 10


def test_query_messages_date_filter_is_half_open():
    r = server.do_query_messages(source="sms", since="2024-01-01", until="2024-02-01")
    for row in r["results"]:
        assert str(row["ts"])[:7] == "2024-01"


def test_query_messages_rejects_bad_source():
    with pytest.raises(ValueError):
        server.do_query_messages(source="bogus")


# --- get_message ------------------------------------------------------------

def test_get_message_full_body_and_recipients():
    # Resolve the id dynamically so the test survives a msgvault re-ingest.
    q = server.do_query_messages(sender="amanda reed", subject_contains="hiya", source="email")
    assert q["count"] >= 1
    gm = server.do_get_message(q["results"][0]["item_id"])
    assert gm["source"] == "email"
    assert gm["body"]          # full body, not just a snippet
    assert gm["recipients"]    # to/cc/from rows present
    assert isinstance(gm["from_me"], bool)


def test_get_message_bad_input():
    assert "error" in server.do_get_message("not-an-id")
    assert "error" in server.do_get_message("web:123")  # wrong source for this tool


# --- hub timestamp sanitization (the build_hub.sql fix) ---------------------

def test_hub_has_no_out_of_range_timestamps():
    n = server._rows(
        server.HUB_DB,
        "SELECT count(*) AS n FROM items WHERE ts IS NOT NULL "
        "AND (ts < TIMESTAMP '1996-01-01' OR ts >= TIMESTAMP '2035-01-01')",
    )[0]["n"]
    assert n == 0


# --- semantic (needs the LM Studio embedding endpoint) ----------------------

@pytest.mark.skipif(not _embed_up(), reason="LM Studio embedding endpoint down")
def test_semantic_email_sorted_and_deduped():
    hits = server.do_semantic_email("freddie mac dataset license", limit=5)
    assert 0 < len(hits) <= 5
    assert all(h["source"] in server.MSG_SOURCES for h in hits)  # messages only
    scores = [h["score"] for h in hits]
    assert scores == sorted(scores, reverse=True)       # cosine similarity, higher first
    ids = [h["item_id"] for h in hits]
    assert len(ids) == len(set(ids))                    # deduped across sources


@pytest.mark.skipif(not _embed_up(), reason="LM Studio embedding endpoint down")
def test_semantic_unified_merges_sources_on_one_scale():
    # Default (all sources) must rank by a single cosine `score`, descending, and may
    # legitimately interleave message + web/calendar hits.
    hits = server.do_semantic("mortgage data licensing", limit=10)
    assert hits
    scores = [h["score"] for h in hits]
    assert scores == sorted(scores, reverse=True)
    assert all(h["source"] in server.SEMANTIC_SOURCES for h in hits)
    assert all(0.0 <= h["score"] <= 1.0001 for h in hits)  # cosine similarity range


@pytest.mark.skipif(not (_embed_up() and _has(server.CAL_DB)),
                    reason="endpoint or calendar db absent")
def test_semantic_calendar_one_hit_per_uid():
    hits = server.do_semantic("weekly meeting", limit=8, source="calendar")
    ids = [h["item_id"] for h in hits]
    assert ids and all(i.startswith("cal:") for i in ids)
    assert len(ids) == len(set(ids))                    # recurring events collapse to one


@pytest.mark.skipif(not _embed_up(), reason="LM Studio embedding endpoint down")
def test_semantic_merge_sorted_by_cosine_desc():
    hits = server.do_semantic("data engineering", limit=6)  # web + calendar merged
    scores = [h["score"] for h in hits]
    assert scores == sorted(scores, reverse=True)       # cosine similarity, higher first


@pytest.mark.skipif(not _embed_up(), reason="LM Studio embedding endpoint down")
def test_semantic_rejects_bad_source():
    with pytest.raises(ValueError):
        server.do_semantic("x", source="bogus")


def test_semantic_clean_error_when_embeddings_offline(monkeypatch):
    # Point the embed endpoint at a closed port: both semantic tools must raise a
    # clear RuntimeError, not a raw traceback. (No LM Studio needed for this test.)
    monkeypatch.setattr(server, "EMBED_ENDPOINT", "http://127.0.0.1:1/v1/embeddings")
    with pytest.raises(RuntimeError, match="Embedding endpoint unreachable"):
        server.do_semantic_email("anything", limit=1)
    with pytest.raises(RuntimeError, match="Embedding endpoint unreachable"):
        server.do_semantic("anything", limit=1)
