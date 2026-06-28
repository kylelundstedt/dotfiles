-- Load calendar event embeddings (nomic-embed-text v1.5, dim 768) for semantic search.
-- One vector per distinct event UID. Run after embed_calendar.py, from ~/archives/calendar:
--   duckdb calendar-archive.duckdb < build_calendar_embeddings.sql
CREATE OR REPLACE TABLE embeddings AS
SELECT id AS uid, CAST(embedding AS FLOAT[768]) AS vec
FROM read_json_auto('sources/calendar-embeddings.jsonl', maximum_object_size=20000000);
