-- Load document embeddings (nomic-embed-text v1.5, dim 768) for semantic search.
-- Run after embed_reader.py: duckdb web-archive.duckdb < build_embeddings.sql
CREATE OR REPLACE TABLE embeddings AS
SELECT id, CAST(embedding AS FLOAT[768]) AS vec
FROM read_json_auto('sources/embeddings.jsonl', maximum_object_size=20000000);
