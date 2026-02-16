---
name: data-pipelines
description: Use this skill for data pipeline work — ingestion with dlt, transformations with sqlmesh, analytics with DuckDB/MotherDuck, DataFrames with polars, notebooks with marimo, and project management with uv.
---

You are building data pipelines using a DuckDB-centric stack. The tools, in typical execution order: **dlt** (extract + load) → **sqlmesh** (transform) → **DuckDB/MotherDuck** (query engine) → **polars** (DataFrame work) → **marimo** (notebooks/apps). **uv** manages Python projects and dependencies.

## Language Preference

SQL first (DuckDB dialect), then Python, then bash. Use the simplest language that gets the job done.

## uv — Project Management

Never use pip directly. All Python work goes through uv.

```bash
uv init my-project                    # New project
uv add "dlt[duckdb]" sqlmesh polars   # Add dependencies
uv sync                               # Install into .venv
uv run python pipeline.py             # Run in project venv
uv run --with requests script.py      # Ad-hoc dependency
```

**Inline script dependencies** (PEP 723) for standalone scripts:

```python
# /// script
# dependencies = ["dlt[duckdb]", "polars"]
# requires-python = ">=3.12"
# ///
```

Run with `uv run script.py` — deps are resolved automatically.

Always commit `uv.lock`. Use `pyproject.toml` for dependency declarations, never `requirements.txt`.

## dlt — Extract + Load

dlt handles ingestion: API calls, pagination, schema inference, incremental loading, and state management.

### Scaffold and Run

```bash
dlt init rest_api duckdb             # Scaffold pipeline
uv run python pipeline.py           # Run extraction
dlt pipeline <name> info             # Inspect state
dlt pipeline <name> schema           # View inferred schema
```

### Pipeline Patterns

**Minimal pipeline:**

```python
import dlt

pipeline = dlt.pipeline(
    pipeline_name="my_pipeline",
    destination="duckdb",
    dataset_name="raw",
)
info = pipeline.run(data, table_name="events")
```

**Incremental loading:**

```python
@dlt.resource(write_disposition="merge", primary_key="id")
def users(updated_at=dlt.sources.incremental("updated_at")):
    yield from fetch_users(since=updated_at.last_value)
```

**REST API source (declarative):**

```python
from dlt.sources.rest_api import rest_api_source

source = rest_api_source({
    "client": {"base_url": "https://api.example.com/v1"},
    "resource_defaults": {"primary_key": "id", "write_disposition": "merge"},
    "resources": [
        "users",
        {
            "name": "events",
            "write_disposition": "append",
            "endpoint": {
                "path": "events",
                "incremental": {"cursor_path": "created_at", "initial_value": "2024-01-01"},
            },
        },
    ],
})
```

**Write dispositions:**

| Disposition | Behavior | Use For |
|---|---|---|
| `append` | Insert rows (default) | Immutable events, logs |
| `replace` | Drop and recreate | Small lookup tables |
| `merge` | Upsert by `primary_key` | Mutable records |

**Destinations:** `duckdb` (local file), `motherduck` (cloud). Set `motherduck_token` env var or configure in `.dlt/secrets.toml`.

### Project Structure

```
.dlt/
  config.toml          # Pipeline config
  secrets.toml         # Credentials (gitignored)
<source>_pipeline.py
```

## sqlmesh — Transform

SQL-first transformation framework. Models are SQL files with a header block. Plan/apply workflow — no accidental production changes.

### Scaffold and Run

```bash
sqlmesh init duckdb                              # New project
sqlmesh init -t dlt --dlt-pipeline <name>        # From dlt schema
sqlmesh plan                                     # Preview + apply (dev)
sqlmesh plan prod                                # Promote to production
sqlmesh fetchdf "SELECT * FROM analytics.users"  # Ad-hoc query
sqlmesh test                                     # Run unit tests
sqlmesh ui                                       # Web interface
```

### Model Kinds

| Kind | Behavior | Use For |
|---|---|---|
| `FULL` | Rewrite entire table | Small dimension tables |
| `INCREMENTAL_BY_TIME_RANGE` | Process new time intervals | Facts, events, logs |
| `INCREMENTAL_BY_UNIQUE_KEY` | Upsert by key | Mutable dimensions |
| `SEED` | Static CSV data | Reference/lookup data |
| `VIEW` | SQL view | Simple pass-throughs |
| `SCD_TYPE_2` | Slowly changing dimensions | Historical tracking |

### Model Example

```sql
MODEL (
    name analytics.stg_events,
    kind INCREMENTAL_BY_TIME_RANGE (time_column event_date),
    cron '@daily',
    grain (event_id),
    audits (NOT_NULL(columns=[event_id]))
);

SELECT
    event_id,
    user_id,
    event_type,
    event_date
FROM raw.events
WHERE event_date BETWEEN @start_date AND @end_date
```

### Config (`config.yaml`)

```yaml
gateways:
  local:
    connection:
      type: duckdb
      database: db.duckdb
default_gateway: local
model_defaults:
  dialect: duckdb
```

### dlt Integration

`sqlmesh init -t dlt` auto-generates external models and incremental staging models from dlt's inferred schema. Schema changes from dlt are detected by `sqlmesh plan`.

## DuckDB — Query Engine

DuckDB is the shared SQL engine across the entire stack. Use DuckDB-specific syntax freely.

### CLI

```bash
duckdb                              # In-memory
duckdb my_data.db                   # Persistent local
duckdb md:my_db                     # MotherDuck
duckdb -c "SELECT 42"              # One-shot
```

### DuckDB SQL Syntax

**Friendly SQL:**

```sql
FROM my_table;                                          -- Implicit SELECT *
FROM my_table SELECT col1, col2 WHERE col3 > 5;        -- FROM-first
SELECT * EXCLUDE (internal_id) FROM events;             -- Drop columns
SELECT * REPLACE (amount / 100.0 AS amount) FROM txns;  -- Transform in-place
SELECT category, SUM(amount) FROM sales GROUP BY ALL;    -- Infer GROUP BY
```

**Read files directly (no import step):**

```sql
SELECT * FROM 'data.parquet';
SELECT * FROM read_csv('data.csv', header=true);
SELECT * FROM 's3://bucket/path/*.parquet';
COPY (SELECT * FROM events) TO 'output.parquet' (FORMAT PARQUET);
```

**Nested types:**

```sql
SELECT {'name': 'Alice', 'age': 30} AS person;
SELECT [1, 2, 3] AS nums;
SELECT list_filter([1, 2, 3, 4], x -> x > 2);
```

**Useful commands:**

```sql
DESCRIBE SELECT * FROM events;
SUMMARIZE events;
```

### MotherDuck

```sql
ATTACH 'md:';              -- All databases
ATTACH 'md:my_db';         -- Specific database
```

Auth via `motherduck_token` env var. Cross-database queries work: `SELECT * FROM local_db.main.t1 JOIN md:cloud_db.main.t2 USING (id)`.

## polars — DataFrames

Use polars when Python logic is needed — complex string transforms, ML features, row-level conditionals. For joins, aggregations, and window functions, prefer SQL.

### Key Patterns

```python
import polars as pl

# Lazy evaluation (always prefer for production)
lf = pl.scan_parquet("events/*.parquet")
result = (
    lf.filter(pl.col("event_date") >= "2024-01-01")
    .group_by("user_id")
    .agg(pl.col("amount").sum().alias("total_spend"))
    .sort("total_spend", descending=True)
    .collect()
)

# Three contexts
df.select(...)         # Pick/transform columns (output has ONLY these)
df.with_columns(...)   # Add/overwrite columns (keeps all originals)
df.filter(...)         # Keep rows matching condition
```

**DuckDB interop (zero-copy via Arrow):**

```python
import duckdb
result = duckdb.sql("SELECT * FROM df WHERE amount > 100").pl()
```

## marimo — Notebooks

Reactive Python notebooks stored as plain `.py` files. Cells auto-re-execute when dependencies change.

```bash
marimo edit notebook.py              # Create/edit
marimo run notebook.py               # Serve as app
marimo convert notebook.ipynb -o out.py  # From Jupyter
```

**SQL cells** use DuckDB by default and return polars DataFrames:

```python
result = mo.sql(f"""
    SELECT * FROM events
    WHERE event_date >= '{start_date}'
""")
```

Python variables and polars DataFrames are queryable from SQL cells and vice versa.

## Typical Pipeline Flow

1. `uv init` + `uv add "dlt[duckdb]" "sqlmesh[duckdb]" polars marimo`
2. `dlt init rest_api duckdb` — scaffold extraction
3. `uv run python pipeline.py` — dlt loads raw data into DuckDB
4. `sqlmesh init -t dlt --dlt-pipeline <name>` — generate transform models
5. Write SQL models → `sqlmesh plan` — transform raw into analytics
6. `marimo edit analysis.py` — explore with SQL cells and polars
7. For production: swap destination to `motherduck`, `sqlmesh plan prod`
