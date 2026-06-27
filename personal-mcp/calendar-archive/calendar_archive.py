# /// script
# requires-python = ">=3.11"
# dependencies = ["icalendar", "duckdb"]
# ///
"""
Build the unified local calendar archive (DuckDB) from .ics exports.

Reads every .ics under ~/archives/calendar/sources/ and writes
~/archives/calendar/calendar-archive.duckdb (one row per event, schema below).

Sources are a mix of:
  - historical exports that no longer exist in any live account (defunct LPS work
    calendar; an old local-Mac calendar backup), and
  - Google Takeout exports of the current home + work calendars.

Refreshing the recent end = drop fresh Takeout .ics into the sources dir (overwriting
the matching gcal-*.ics) and re-run this script. There is no live API pull: a consumer
Gmail OAuth app would need Google verification to publish, which isn't worth it for a
personal tool, and the Takeout snapshot already covers the full history.

Env overrides (for testing): CAL_DB, CAL_SOURCES.
"""

import os, glob
from datetime import datetime, date

HOME = os.path.expanduser("~")
DB = os.environ.get(
    "CAL_DB", os.path.join(HOME, "archives", "calendar", "calendar-archive.duckdb")
)
SOURCES = os.environ.get(
    "CAL_SOURCES", os.path.join(HOME, "archives", "calendar", "sources")
)

COLUMNS = (
    "source",
    "uid",
    "start_iso",
    "start_date",
    "year",
    "end_iso",
    "summary",
    "location",
    "description",
    "organizer",
    "attendees",
    "status",
    "recurring",
)


def _to_iso(v):
    if v is None:
        return None, None, None
    dt = getattr(v, "dt", v)
    if isinstance(dt, datetime):
        return dt.isoformat(), dt.date().isoformat(), dt.year
    if isinstance(dt, date):
        return dt.isoformat(), dt.isoformat(), dt.year
    return str(dt), None, None


def _emails(comp, key):
    val = comp.get(key)
    if val is None:
        return None
    items = val if isinstance(val, list) else [val]
    out = []
    for a in items:
        s = str(a)
        out.append(s[7:] if s.lower().startswith("mailto:") else s)
    return ";".join(out) or None


def ingest():
    from icalendar import Calendar

    rows, bad = [], 0
    paths = glob.glob(f"{SOURCES}/**/*.ics", recursive=True)
    for p in paths:
        if (
            ".icbu" in p
        ):  # group the 10k UUID-named files in a backup bundle under one source
            source = (
                "ics:"
                + os.path.basename(p.split(".icbu")[0]).lower().replace(" ", "-")
                + "-icbu"
            )
        else:
            source = "ics:" + os.path.splitext(os.path.basename(p))[0].lower().replace(
                " ", "-"
            )
        try:
            with open(p, "rb") as f:
                cal = Calendar.from_ical(f.read())
        except Exception:
            bad += 1
            continue
        for c in cal.walk("VEVENT"):
            try:
                s_iso, s_date, s_year = _to_iso(c.get("DTSTART"))
                e_iso, _, _ = _to_iso(c.get("DTEND"))
                rows.append(
                    (
                        source,
                        str(c.get("UID", "")) or None,
                        s_iso,
                        s_date,
                        s_year,
                        e_iso,
                        str(c.get("SUMMARY", "")) or None,
                        str(c.get("LOCATION", "")) or None,
                        str(c.get("DESCRIPTION", "")) or None,
                        _emails(c, "ORGANIZER"),
                        _emails(c, "ATTENDEE"),
                        str(c.get("STATUS", "")) or None,
                        "RRULE" in c,
                    )
                )
            except Exception:
                bad += 1
    print(f"parsed {len(rows)} events from {len(paths)} .ics ({bad} skipped)")
    return rows


def write_db(rows):
    import duckdb

    os.makedirs(os.path.dirname(DB), exist_ok=True)
    con = duckdb.connect(DB)
    con.execute("DROP TABLE IF EXISTS events")
    con.execute("""
        CREATE TABLE events (
          source VARCHAR, uid VARCHAR, start_iso VARCHAR, start_date DATE,
          year INTEGER, end_iso VARCHAR, summary VARCHAR, location VARCHAR,
          description VARCHAR, organizer VARCHAR, attendees VARCHAR,
          status VARCHAR, recurring BOOLEAN)""")
    con.executemany(f"INSERT INTO events VALUES ({','.join('?' * len(COLUMNS))})", rows)
    con.execute("CREATE INDEX idx_year ON events(year)")
    n = con.execute("SELECT count(*) FROM events").fetchone()[0]
    print(f"wrote {n} rows -> {DB}")
    for r in con.execute("""SELECT source, count(*), min(year), max(year) FROM events
                            WHERE year BETWEEN 1990 AND 2030 GROUP BY 1 ORDER BY 1""").fetchall():
        print(f"  {r[0]:34} {r[1]:>6}  {r[2]}-{r[3]}")
    con.close()


if __name__ == "__main__":
    write_db(ingest())
