# agent-shell evaluation

`@tigrisdata/agent-shell` — a TypeScript library that gives agents a virtual bash shell backed by Tigris object storage.

## What it is

A virtual shell (built on [just-bash](https://github.com/vercel-labs/just-bash)) where Unix commands operate on Tigris buckets as the filesystem. No real processes, no real FS — everything runs in TypeScript with S3 as the storage layer.

**Programmatic API:**

```javascript
import { TigrisShell } from "@tigrisdata/agent-shell";

const shell = new TigrisShell({
  accessKeyId: process.env.TIGRIS_STORAGE_ACCESS_KEY_ID,
  secretAccessKey: process.env.TIGRIS_STORAGE_SECRET_ACCESS_KEY,
  bucket: process.env.TIGRIS_STORAGE_BUCKET,
});

await shell.exec('echo "data" > output.txt');
await shell.exec("cat output.txt"); // → "data\n"
await shell.flush(); // atomic write to Tigris
```

**Key primitives:**

| Method                | What it does                                     |
| --------------------- | ------------------------------------------------ |
| `exec(cmd)`           | Run a command against the virtual FS             |
| `flush()`             | Atomically persist all buffered writes to Tigris |
| `mount(bucket, path)` | Mount another bucket at a path                   |
| `unmount(path)`       | Remove a mount                                   |
| Built-in: `fork`      | Copy-on-write bucket clone (zero duplication)    |
| Built-in: `snapshot`  | Point-in-time checkpoint                         |
| Built-in: `presign`   | Generate presigned sharing URL                   |

## Why it's interesting

1. **Atomic write-back** — all writes buffered in memory, only persisted on `flush()`. If anything throws, the bucket is byte-for-byte unchanged. This is the killer feature for agent workflows where partial writes are worse than no writes.

2. **Fork/snapshot** — copy-on-write bucket clones let you give each agent run its own sandbox at zero storage cost. Inspect results, merge or discard.

3. **Multi-mount** — compose multiple buckets into one namespace. Read-only "golden" dataset at `/data`, scratch space at `/workspace`.

4. **Bucket notifications** — Tigris fires webhooks on create/update/delete. Enables multi-agent pipelines without polling.

## Potential IV use cases

### Agent workspace isolation (exe.dev)

Fork a shared bucket per agent run. Agent writes freely to the fork — failed runs leave the source untouched, successful runs get reviewed and merged. Maps naturally to the exe.dev integration model: one Tigris bucket per client tag, agent-shell forks per task.

### Atomic artifact publishing

Agent builds a deliverable (report, dataset, transformed output). All writes buffered. On success: `flush()` publishes atomically. On failure: nothing written. No cleanup scripts, no partial state.

### Scheduled digest / knowledge base

The [`llm-digest` pattern](https://www.tigrisdata.com/blog/self-updating-knowledge-base/): cron reads inputs (RSS, APIs, internal data), agent synthesizes, atomic flush to Tigris, presign a URL, post to Slack. ~$0.23/night for the LLM calls. Could adapt for IV client status digests or pipeline health summaries.

### IV MCP server — docs layer

The future IV MCP server needs to combine structured (MotherDuck), unstructured (docs/artifacts in Tigris), and reference docs. Agent-shell could be the read/write layer for the unstructured tier:

- `docs_search` — list/grep against mounted doc buckets
- `docs_read` — `exec("cat /docs/client/artifact.md")`
- `docs_write` — buffer writes, atomic flush on success
- Per-client isolation via separate mounts scoped by tag

### Multi-agent pipelines

Agent A writes processed data to a prefix → Tigris bucket notification fires → Agent B picks up and continues. No shared mutable state, no polling, no message broker.

## Concerns / open questions

- **just-bash fidelity** — how complete is the shell emulation? The blog says "bash enough" — need to test edge cases (glob patterns, pipes, redirects, exit codes).
- **Performance at scale** — flush on a bucket with thousands of small files? What's the S3 API call count / latency? Is there batching?
- **Error semantics** — what happens on flush failure? Retry? Partial write? Need to read the source.
- **Auth model** — requires Tigris access keys or OAuth session. On exe.dev, keys would come via integration proxy. Need to confirm the proxy can serve Tigris credentials (currently Tigris MCP is OAuth-only per install.sh).
- **Lock-in** — the fork/snapshot primitives are Tigris-specific (not standard S3). StorageSDK claims multi-backend support, but fork/snapshot may only work on Tigris. Acceptable if we're committed to Tigris, but worth confirming.
- **Maturity** — new project (announced June 2026). API stability, bug surface, community size are unknowns.

## Evaluation plan

1. **Install and smoke-test** — `npm install @tigrisdata/agent-shell`, write/read/flush against an existing Tigris bucket. Confirm auth works with existing credentials.
2. **Fork semantics** — fork a bucket, write to the fork, verify source is unchanged, list forks, delete fork.
3. **Atomic failure** — write several files, throw before flush, confirm bucket is clean.
4. **Multi-mount** — mount two buckets, read from one, write to the other.
5. **Integration test on exe.dev** — run agent-shell inside an exe.dev VM. Confirm Tigris auth via integration proxy or forwarded credentials.
6. **Prototype: IV digest** — adapt the llm-digest pattern for a real IV data source. Cron on exe.dev, flush to Tigris, presign and share.

## Decision

Not yet. Pending hands-on evaluation (steps above).

## References

- [Blog: How small can we make an interface to Tigris?](https://www.tigrisdata.com/blog/agent-shell-homepage/)
- [Docs: Agent Shell](https://www.tigrisdata.com/docs/ai/agent-shell/)
- [Blog: Self-Updating Knowledge Base](https://www.tigrisdata.com/blog/self-updating-knowledge-base/)
- [npm: @tigrisdata/agent-shell](https://www.npmjs.com/package/@tigrisdata/agent-shell)
- [GitHub: just-bash](https://github.com/vercel-labs/just-bash)
