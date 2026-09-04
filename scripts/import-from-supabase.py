#!/usr/bin/env python3
"""Copy meetings out of a Supabase project into the local SQLite file.

The app is local-first now: it reads one file on this device and never talks to
Supabase. This moves what is already in a hosted project across, once, so
switching does not mean starting empty.

Reads through psql, so it needs the same connection string `supabase db push`
uses and nothing else. Idempotent: rows already present, matched on id, are
skipped rather than duplicated.

    ./scripts/import-from-supabase.py "$PG_URL" [path/to/scribe.sqlite]
"""
import json
import os
import sqlite3
import subprocess
import sys

DEFAULT_DB = os.path.expanduser(
    "~/Library/Containers/com.machinascribe.Scribe/Data/Library/"
    "Application Support/Scribe/scribe.sqlite"
)

# Ordered so a row's parents always exist before it does.
TABLES = [
    ("people", ["id", "name", "note", "created_at"]),
    ("meetings", ["id", "title", "location", "started_at", "ended_at", "duration_ms",
                  "source", "status", "error", "notes", "summary", "summary_json",
                  "summarized_at", "notion_page_id", "notion_url", "exported_at",
                  "created_at", "updated_at"]),
    ("speakers", ["id", "meeting_id", "label", "person_id", "resolved_by",
                  "match_delta_ms", "created_at"]),
    ("segments", ["id", "meeting_id", "speaker_id", "idx", "start_ms", "end_ms", "text"]),
    ("live_tags", ["id", "meeting_id", "name", "at_ms", "resolved_speaker_id", "created_at"]),
    ("meeting_attendees", ["id", "meeting_id", "name", "created_at"]),
]


def fetch(pg_url, table, columns):
    """Every row of one table, as dicts. json_agg keeps types and nulls intact
    rather than making us re-parse psql's aligned output."""
    select = ", ".join(columns)
    sql = f"select coalesce(json_agg(t), '[]') from (select {select} from public.{table}) t"
    out = subprocess.run(
        ["psql", pg_url, "-tAc", sql],
        capture_output=True, text=True, check=True,
    ).stdout
    return json.loads(out)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    pg_url = sys.argv[1]
    db_path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_DB

    if not os.path.exists(db_path):
        sys.exit(
            f"No database at {db_path}.\n"
            "Launch the app once so it creates the file, then run this again."
        )

    db = sqlite3.connect(db_path)
    db.execute("pragma foreign_keys = on")
    total = 0
    for table, columns in TABLES:
        rows = fetch(pg_url, table, columns)
        placeholders = ", ".join("?" * len(columns))
        # `or ignore` rather than `or replace`: anything recorded on this device
        # since the switch is newer than what is in the hosted project, and
        # should win.
        stmt = f"insert or ignore into {table} ({', '.join(columns)}) values ({placeholders})"
        # Count from each statement's own rowcount, not `total_changes`.
        # Inserting a segment fires the FTS trigger, which is itself a change,
        # so `total_changes` reported nearly ten times the number of rows.
        written = 0
        for row in rows:
            values = []
            for c in columns:
                v = row.get(c)
                values.append(json.dumps(v) if isinstance(v, (dict, list)) else v)
            written += db.execute(stmt, values).rowcount
        total += written
        print(f"  {table}: {written} imported ({len(rows)} found, "
              f"{len(rows) - written} already here)")
    db.commit()

    # The FTS index is populated by triggers on insert, so it is already in
    # step -- but verify rather than assume, because a silently empty index
    # means search returns nothing and looks like there is nothing to find.
    indexed = db.execute("select count(*) from segments_fts").fetchone()[0]
    stored = db.execute("select count(*) from segments").fetchone()[0]
    print(f"\n{total} rows imported. Search index: {indexed} of {stored} turns.")
    if indexed != stored:
        print("Index is out of step; rebuilding.")
        db.execute("insert into segments_fts(segments_fts) values ('rebuild')")
        db.commit()
    db.close()


if __name__ == "__main__":
    main()
