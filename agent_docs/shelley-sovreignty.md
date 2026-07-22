# Shelley and Operating Memory Sovereignty

> Status: architecture assessment based on the Shelley installation and database
> inspected on 2026-07-19. The filename preserves the requested spelling
> (`shelley-sovreignty.md`). Revalidate implementation details after significant
> Shelley upgrades.

## Executive summary

Shelley is a **sovereignty-compatible agent harness** and its local SQLite
storage is a strong foundation for retaining agent-session history. The firm can
read, copy, query, and transform the database without Shelley or a model
provider's permission. Standard SQLite tooling and DuckDB can access the data.

Shelley and `shelley.db` are **not, by themselves, a complete operating-memory
layer**. The database is best understood as a portable conversation and
execution ledger:

- It records prompts, responses, model identity, tool calls/results, usage,
  conversation generations, and local full-text search.
- It does not provide first-class governed stores for rules, approvals,
  exceptions, prompt libraries, examples, evals, or authoritative customer
  state.
- Exact provider HTTP requests and responses are not retained by current code.
- Conversation history is mutable and can be deleted, so it is not an immutable
  audit log.
- The SQLite file is portable only when copied with a WAL-safe backup procedure.
- Local custody does not establish what Shelley or model providers retain
  remotely; telemetry and provider contracts remain separate control
  boundaries.

The right role for Shelley is therefore:

1. Agent interface and execution environment.
2. Locally owned record of agent activity.
3. Capture source for candidate operating memory.
4. Consumer of approved operating memory held in authoritative owned systems.

A separate governance pipeline must convert useful observations and judgment
from Shelley sessions into reviewed, versioned, approved operating-memory
records.

## The sovereignty test

The operating-memory standard used in this assessment is stronger than "we can
export our chats." The firm should hold complete, current, authoritative copies
of the relevant:

- source artifacts and customer state;
- rules, procedures, exceptions, decisions, and approvals;
- prompt and agent-instruction libraries;
- examples and eval suites;
- execution and audit history;
- retrieval indexes, or at least the canonical inputs needed to rebuild them;
- provenance linking outputs to sources, policies, models, and human approvals.

The memory must be stored in open or replaceable formats, movable without an
incumbent supplier's permission, and usable by a successor harness or model.
Managed infrastructure is acceptable when the firm controls export, backup,
keys, and replacement. Self-hosting is not sufficient by itself, and managed
hosting is not disqualifying by itself.

## What Shelley currently persists

The canonical local database is:

```text
~/.config/shelley/shelley.db
```

The inspected build uses `modernc.org/sqlite` and stores a standard SQLite 3
file in WAL mode. Relevant tables include:

### `conversations`

Stores conversation-level state including:

- stable ID and human-readable slug;
- creation and update timestamps;
- working directory;
- archive state;
- parent conversation relationship;
- selected model;
- conversation options;
- active generation;
- tags;
- draft and queued-message state.

### `messages`

Stores ordered conversation events including:

- user, agent, system, and Git-context messages;
- structured model-facing and display payloads;
- creation time;
- model name and API URL for agent messages;
- token usage, cache usage, and cost metadata;
- generation and excluded-from-context state;
- fork relationships;
- user email;
- tool names, inputs, results, errors, and timing embedded in the structured
  payloads.

The persisted structures contain text, tool commands and arguments, tool
results, reasoning-related fields, and provider-specific encrypted reasoning
fields. This makes the database highly sensitive. It may contain any secret or
customer information that appeared in a prompt, command, file, browser result,
or tool response.

Reasoning-related fields do not prove that raw private model chain-of-thought is
stored. Depending on the model/provider, reasoning may be summarized, signed,
or encrypted.

### Full-text search

Shelley maintains an SQLite FTS5 virtual table named `messages_fts` with triggers
on `messages`. It indexes selected `Text` and `Thinking` values for user and
agent messages. This provides owned local transcript retrieval, but it is not a
complete retrieval index over source documents, approvals, external systems, or
all tool artifacts.

### `llm_requests`: abandoned debug storage

The schema contains an `llm_requests` table with columns for:

- conversation;
- model and provider;
- URL;
- exact request and response bodies;
- HTTP status and error;
- duration;
- request-prefix deduplication.

This table is vestigial. Embedded migrations establish its lifecycle:

1. Migration 010 created it for "tracking/debugging API calls."
2. Migration 011 added prefix deduplication for repeated conversation context.
3. Migration 025 states that the debug feature was removed and current code no
   longer reads or writes the table.
4. The migration intentionally abandoned the table in place instead of dropping
   it, because dropping a formerly large table could be slow.

On the inspected fresh installation, migrations 010, 011, and 025 ran during the
same initialization and `llm_requests` remained empty. Consequently, current
Shelley history does **not** prove the exact serialized provider request,
headers, complete effective prompt, or raw provider response for a run.

## Portability and interoperability

### SQLite

The database passed SQLite integrity checks and is directly accessible using
standard SQLite tools. This is a meaningful sovereignty advantage: access to
stored history does not depend on the Shelley UI, API, or vendor.

### WAL-safe copying

Shelley uses WAL mode and maintains these live files:

```text
shelley.db
shelley.db-wal
shelley.db-shm
```

Recent committed data may still reside in the WAL. Copying only `shelley.db`
while Shelley is running can produce a stale or incomplete snapshot. Use
SQLite's online backup API:

```bash
sqlite3 ~/.config/shelley/shelley.db \
  ".backup '/owned/backup/location/shelley-snapshot.db'"
```

The resulting snapshot is a portable single SQLite file. Continuous replication
with Litestream is an appropriate additional control, but periodic restoration
must be tested.

### DuckDB

DuckDB's SQLite extension was able to attach a Shelley snapshot read-only and
read all declared tables, including the FTS5 virtual and shadow tables. Ordinary
Shelley data is directly queryable:

```sql
ATTACH '/path/to/shelley-snapshot.db'
AS shelley (TYPE sqlite, READ_ONLY);

SELECT * FROM shelley.messages;
```

DuckDB's own SQL parser does not accept SQLite's `MATCH` operator directly, but
`sqlite_query` can delegate SQLite-specific FTS5 SQL to the attached SQLite
engine:

```sql
SELECT *
FROM sqlite_query(
    'shelley',
    $query$
    SELECT rowid, text
    FROM messages_fts
    WHERE messages_fts MATCH 'search terms'
    $query$
);
```

This makes DuckDB a practical successor-independent inspection, export, and
analytics tool.

### Turso Database 0.7.0

Turso 0.7.0 can open the SQLite file format and read ordinary Shelley tables,
but it is not a safe drop-in replacement:

- Shelley's schema uses SQLite FTS5.
- Turso's full-text search uses a different Tantivy-based implementation.
- Turso reported `Virtual table module not found: fts5` against the snapshot.
- FTS queries and message writes involving Shelley's FTS triggers failed.
- Turso explicitly does not support mixed SQLite-and-Turso multiprocess access.

Turso may be useful after an intentional schema/application migration, but it
should not open the live Shelley database alongside Shelley.

## Assessment against the operating-memory criteria

| Criterion                              | Status                         | Assessment                                                                                                |
| -------------------------------------- | ------------------------------ | --------------------------------------------------------------------------------------------------------- |
| Firm possesses the stored data         | Pass                           | The SQLite database is local and directly readable without Shelley.                                       |
| Open, movable format                   | Conditional pass               | Standard SQLite is portable, but a live copy must include a consistent WAL-safe snapshot.                 |
| Complete/current/authoritative memory  | Partial                        | Authoritative for Shelley conversation state, not for all operational artifacts or customer systems.      |
| Conversation and tool history          | Strong partial pass            | Rich prompts, responses, tool activity, model, usage, generations, and forks are retained.                |
| Exact provider traffic                 | Fail                           | Raw request/response logging was removed.                                                                 |
| Retrieval index                        | Partial                        | Owned FTS5 exists for selected transcript text, not broader operating memory.                             |
| Governed prompt library                | Outside DB                     | Instructions and skills live in files/repos; ownership depends on their versioning and backup.            |
| Eval library                           | Fail in Shelley                | No first-class eval-case, expected-result, or certification store exists.                                 |
| Rules, exceptions, approvals           | Fail as governed entities      | They may appear in prose but are not normalized, reviewed, effective-dated records.                       |
| Immutable audit history                | Fail                           | Rows are mutable; deleting a conversation cascades to its messages.                                       |
| Model contestability                   | Partial                        | Model identity is retained, but exact prompt assembly and harness semantics are not fully captured.       |
| Successor without incumbent permission | Data pass; operational partial | A successor can read/export the bits but may not reproduce undocumented harness behavior exactly.         |
| Harness telemetry auditable            | Partial/unverified             | Local activity is visible; remote harness/provider telemetry and retention require separate verification. |
| Security and custody                   | Needs hardening                | The inspected DB and WAL files were plaintext mode `0644` under a mode `0755` directory.                  |
| Client isolation                       | Not established by the DB      | Enterprise use needs explicit tenant boundaries, authorization, keys, retention, and deletion controls.   |

## Important conceptual boundary

A transcript is a **source of candidate operating memory**, not automatically
operating memory.

For example, an employee may explain an exception to Shelley. The transcript
preserves the explanation, but the exception does not become authoritative until
it is:

1. identified as a candidate rule or judgment;
2. linked to its source evidence and affected client/process;
3. reviewed by an authorized human;
4. assigned effective dates and retention/classification;
5. approved and versioned;
6. published to the retrieval and execution systems;
7. superseded or revoked through a controlled process.

The firm should not ask a future agent to search old chats and infer which
statement became policy. Shelley should help capture and propose memory, while a
governed owned system decides what is authoritative.

## Recommended sovereign stack

### 1. Structured operating-memory registry: PostgreSQL

Use PostgreSQL for normalized and governed records. A minimum memory record
should include:

```text
tenant_id
type: rule | decision | exception | example | approval | eval
content
source_uri
source_hash
owner
authority
classification
effective_from
effective_until
status: proposed | approved | superseded | revoked
supersedes_id
approval_id
created_by_run
created_at
```

Use row-level security and separate encryption/access boundaries for clients.
The registry should point to original artifacts rather than absorbing every
large document as a database blob.

### 2. Owned object storage

Store original evidence in client- or IV-controlled S3-compatible object
storage:

- manuals, contracts, emails, and source-system exports;
- images, screenshots, and attachments;
- signed approvals and review evidence;
- generated deliverables;
- agent-session snapshots and portable exports.

Prefer client-owned buckets/accounts with delegated IV access. If IV operates
the primary service, maintain an independent replica or export in a location the
client controls. Use content hashes, versioning, retention policy, and immutable
names where appropriate.

### 3. Git for prompts, procedures, skills, schemas, and eval definitions

Keep operational text as ordinary versioned files:

```text
agents/
prompts/
procedures/
policies/
schemas/
examples/
evals/
```

Every consequential agent run should record the Git repository and commit that
supplied its instructions, tool definitions, schemas, and eval policy. A prompt
inside a transcript is history; a prompt reviewed and merged through a pull
request is governed operating memory.

GitHub may remain the service layer, but repositories should have independent
mirrors or Git-bundle backups so account suspension does not interrupt access.

### 4. Rebuildable retrieval

Start with PostgreSQL full-text search plus `pgvector` rather than treating a
proprietary vector database as authoritative. Store canonical text and metadata;
treat embeddings and search indexes as disposable derivatives carrying their
embedding model/version and rebuild timestamp.

Use DuckDB and Parquet for portable bulk analysis and exports. If scale requires
a table format such as Iceberg later, preserve the same rule: canonical source
artifacts and metadata must remain accessible independently of the compute
vendor.

### 5. Owned observability and provenance

Instrument Shelley and other harnesses with OpenTelemetry and route events
through an IV-controlled collector. Capture, subject to redaction policy:

- harness and version;
- model/provider/version;
- prompt, policy, skill, and eval revision IDs;
- retrieved memory IDs and source hashes;
- tool calls, results, errors, and timing;
- token usage, cost, and latency;
- human approvals and escalations;
- output artifact IDs;
- retries, failure states, and final disposition.

Use OpenLineage-compatible identifiers/events where useful to link jobs, runs,
inputs, and outputs. Content capture should be explicitly configured because
prompts and tool results may contain client secrets or regulated data.

### 6. Owned eval execution

Keep eval cases and expected outcomes in Git and run them locally or in
IV-controlled CI using Promptfoo or an equivalent runner. Persist results in
PostgreSQL or Parquet with:

- model and provider;
- harness and prompt revisions;
- memory snapshot/version;
- evaluator version;
- raw result and score;
- human adjudication where applicable.

This is what turns "models are interchangeable" from an architectural claim
into a tested property.

### 7. Model gateway

Use a self-controlled model gateway such as LiteLLM, or a small internal
provider abstraction, to enforce:

- approved models per client/task;
- provider failover;
- zero-data-retention/no-training endpoint selection;
- rate and cost limits;
- content-logging policy;
- request IDs tied to owned telemetry;
- consistent authentication and secret handling.

The gateway should remain stateless where possible and must not become another
exclusive memory store.

### 8. Durable workflows and approvals

High-stakes approvals must land in the relevant customer system of record or a
durable workflow engine, not only in chat. PostgreSQL plus signed approval
records may be sufficient initially. Temporal is appropriate when workflows
must survive crashes, wait days for humans, and resume deterministically.

Do not add a workflow platform merely to transfer data between two tables. Add
it when long-running state and recovery are genuine operational requirements.

### 9. Backup, security, and recovery

Minimum controls:

- Litestream replication or frequent WAL-safe snapshots of `shelley.db`;
- PostgreSQL point-in-time recovery;
- object-store versioning/retention and an independent copy;
- Git mirrors/bundles;
- encryption at rest and in transit with controlled keys;
- directory/file permissions appropriate for sensitive data;
- client-specific IAM and tenant boundaries;
- documented retention and verified deletion;
- quarterly restore drills;
- audit of Shelley/provider network destinations and retention terms.

Owning a plaintext file without access control or tested recovery is possession,
not mature custody.

## Recommended IV starting architecture

Avoid beginning with a large knowledge-platform procurement. A practical first
stack is:

1. **Shelley** for agent execution and locally owned session history.
2. **Litestream to owned S3-compatible storage** for continuous Shelley backup.
3. **PostgreSQL + pgvector** for governed operating-memory records and retrieval.
4. **Git** for prompts, procedures, policies, schemas, skills, and evals.
5. **Promptfoo** for provider-independent evals.
6. **OpenTelemetry Collector** for normalized agent telemetry.
7. **DuckDB + Parquet** for inspection, analytics, and portable export.
8. **LiteLLM or an internal gateway** for provider abstraction and policy.

The core lifecycle is:

```text
Shelley session
    -> candidate rule / decision / exception / example
    -> source and provenance capture
    -> authorized human review
    -> approved, versioned operating-memory record
    -> retrieval/index publication
    -> future agent use
    -> eval and outcome feedback
```

## Sovereignty acceptance test

IV or a client should periodically simulate the loss of each supplier. Starting
only from owned backups and documented credentials, verify that a replacement
team can:

1. Restore Shelley history to a consistent SQLite database.
2. Restore the operating-memory registry and source artifacts.
3. Rebuild every full-text and vector index.
4. Resolve each approved memory item to source evidence and approval history.
5. Point another model gateway and agent harness at the same memory.
6. Run the owned eval suite and compare results.
7. Continue active workflows without the departing supplier.
8. Export or delete one client's records completely and verifiably.
9. Establish where prompts, traces, and derived data were sent or retained.

If the drill succeeds, the firm owns the memory layer. If the data is readable
but the operation cannot be resumed, the firm owns an archive, not operating
memory.

## Conclusions

- Shelley materially advances sovereignty by storing rich agent history in a
  local, inspectable, standard SQLite database.
- `shelley.db` gives IV ownership of **the harness's memory of work**.
- It does not automatically give IV a complete, authoritative representation of
  **how the business operates**.
- The principal missing capability is not another chat database. It is the
  governed promotion of candidate knowledge into approved operating-memory
  records with provenance, effective dates, ownership, security, and evals.
- Shelley should remain an execution ledger and capture source. Customer state,
  approved rules, approvals, and business decisions should live in owned
  authoritative systems and be supplied to models as context.
- The strongest proof of sovereignty is a successful replacement drill, not a
  contractual export clause or the existence of a local file.

## References

- DuckDB SQLite extension: <https://duckdb.org/docs/stable/core_extensions/sqlite>
- DuckDB Parquet support: <https://duckdb.org/docs/stable/data/parquet/overview>
- Litestream: <https://litestream.io/>
- PostgreSQL full-text search: <https://www.postgresql.org/docs/current/textsearch.html>
- PostgreSQL row-level security: <https://www.postgresql.org/docs/current/ddl-rowsecurity.html>
- pgvector: <https://github.com/pgvector/pgvector>
- OpenTelemetry GenAI semantic conventions: <https://opentelemetry.io/docs/specs/semconv/gen-ai/>
- OpenLineage: <https://openlineage.io/>
- Promptfoo: <https://www.promptfoo.dev/docs/>
- LiteLLM: <https://docs.litellm.ai/>
- Temporal: <https://docs.temporal.io/>
- Turso SQLite compatibility: <https://github.com/tursodatabase/turso/blob/main/COMPAT.md>
