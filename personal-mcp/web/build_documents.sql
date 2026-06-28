-- Rebuild the documents table + full-text (BM25) index from the raw API pull.
-- Run: duckdb web-archive.duckdb < build_documents.sql
CREATE OR REPLACE TABLE documents AS
SELECT
  id, title, author, site_name, category, location,
  url, source_url, summary, text, notes,
  tags, word_count, reading_progress,
  TRY_CAST(saved_at AS TIMESTAMP)       AS saved_at,
  TRY_CAST(published_date AS TIMESTAMP) AS published_date,
  TRY_CAST(created_at AS TIMESTAMP)     AS created_at,
  TRY_CAST(updated_at AS TIMESTAMP)     AS updated_at
FROM read_json_auto('sources/reader-documents.jsonl', maximum_object_size=20000000);

INSTALL fts; LOAD fts;
PRAGMA create_fts_index('documents','id','title','author','site_name','summary','text', overwrite=1);
