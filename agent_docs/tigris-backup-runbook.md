# klundstedt-mini → Tigris Backup Runbook

Encrypted off-site backup of the always-on Mac mini (`klundstedt-mini`) to Tigris
object storage. **This doc is the disaster-recovery reference — an encrypted
backup is worthless if you can't decrypt it. Keep the credentials below in
1Password; this file documents only item names and procedure, never secrets.**

## What's backed up

| Source                                                                   | Tigris bucket             | Prefix            | Tier       |
| ------------------------------------------------------------------------ | ------------------------- | ----------------- | ---------- |
| `~/` (minus excludes)                                                    | `klundstedt-mini-backup`  | `home/`           | IA         |
| External Photos library (`/Volumes/OWC8TB/Photos Library.photoslibrary`) | `klundstedt-mini-backup`  | `photos/`         | IA         |
| `/Volumes/OWC8TB/aws_s3_backup`                                          | `klundstedt-mini-archive` | `aws-s3/`         | GLACIER_IR |
| `/Volumes/OWC8TB/Box_Download_2025-01-12`                                | `klundstedt-mini-archive` | `box/`            | GLACIER_IR |
| `/Volumes/OWC8TB/iPhoneBackup`                                           | `klundstedt-mini-archive` | `iphone-backup/`  | GLACIER_IR |
| `/Volumes/OWC8TB/messages-store`                                         | `klundstedt-mini-archive` | `messages-store/` | GLACIER_IR |

- Both buckets: **private, multi-region USA**, with **soft-delete (30-day
  retention)** — deleted/overwritten objects are recoverable for 30 days
  (ransomware / bad-sync / accidental-delete protection). Bounded and
  auto-expiring, so it replaces unbounded daily snapshots (the CLI has no
  per-snapshot delete). Archive tier is **GLACIER_IR** (instant retrieval),
  not plain GLACIER (which is frozen — see below).
- Filter: `tigris-backup-filter.txt` (rclone `--filter-from`) — keeps
  `~/Library/Mobile Documents` (iCloud Drive) but **excludes the rest of
  `~/Library`** (app state + all TCC-protected dirs — the unattended job has no
  Full Disk Access), plus `node_modules`/`.venv`, `.lmstudio/models`, `.Trash`,
  `.cache`, `.DS_Store`, sockets, and the regenerable `archives/hub` DuckDB.
- **Client-side encryption** via rclone `crypt` (standard filename + directory
  name encryption). Tigris stores ciphertext only.

## Credentials (all in 1Password, `industryvault` account)

| Purpose                                             | 1Password item (vault)                       | Fields                                               |
| --------------------------------------------------- | -------------------------------------------- | ---------------------------------------------------- |
| Crypt password (decrypts everything — **critical**) | `Tigris mini-backup rclone crypt` (Personal) | `password`, `salt`                                   |
| Dedicated rclone key (Editor on both buckets)       | `Tigris mini-backup rclone key` (Personal)   | `access_key_id`, `password` (=secret)                |
| Tigris admin (create buckets/keys)                  | `Tigris - klundstedt Work` (Personal)        | `access_key_id`, `secret_access_key`, `endpoint_url` |

On the mini these are mirrored into the **login Keychain** for the unattended
job: `tigris-backup:crypt-password`, `tigris-backup:crypt-salt`,
`tigris-backup:s3-key-id`, `tigris-backup:s3-secret`
(read with `security find-generic-password -s <name> -w`).

Endpoint: `https://t3.storage.dev` · region `auto`.

## Restore procedure

You need: rclone, the **crypt password + salt**, and **an access key** (the
scoped key, or the admin key). Set up the remotes via env vars (no config file),
pulling secrets from 1Password:

```bash
ACC=industryvault.1password.com
KEY="Tigris mini-backup rclone key"; CRYPT="Tigris mini-backup rclone crypt"
tid=$(op item get "$KEY"   --account "$ACC" --reveal --fields label=access_key_id)
tsec=$(op item get "$KEY"  --account "$ACC" --reveal --fields label=password)
cpw=$(op item get "$CRYPT" --account "$ACC" --reveal --fields label=password)
csalt=$(op item get "$CRYPT" --account "$ACC" --reveal --fields label=salt)

export RCLONE_CONFIG_TIGRIS_TYPE=s3 RCLONE_CONFIG_TIGRIS_PROVIDER=Other
export RCLONE_CONFIG_TIGRIS_ACCESS_KEY_ID="$tid" RCLONE_CONFIG_TIGRIS_SECRET_ACCESS_KEY="$tsec"
export RCLONE_CONFIG_TIGRIS_ENDPOINT=https://t3.storage.dev RCLONE_CONFIG_TIGRIS_REGION=auto
# crypt remotes (same password unlocks both buckets)
for R in BKUP:klundstedt-mini-backup ARCH:klundstedt-mini-archive; do
  n=${R%%:*}; b=${R#*:}
  export RCLONE_CONFIG_${n}_TYPE=crypt RCLONE_CONFIG_${n}_REMOTE=tigris:$b
  export RCLONE_CONFIG_${n}_FILENAME_ENCRYPTION=standard RCLONE_CONFIG_${n}_DIRECTORY_NAME_ENCRYPTION=true
  export RCLONE_CONFIG_${n}_PASSWORD="$(rclone obscure "$cpw")"
  export RCLONE_CONFIG_${n}_PASSWORD2="$(rclone obscure "$csalt")"
done

# Browse (decrypted names):
rclone ls bkup:home | head
# Restore:
rclone copy bkup:home  ~/restore/home   --progress
rclone copy bkup:photos "~/restore/Photos Library.photoslibrary" --progress
rclone copy arch:aws-s3 ~/restore/aws-s3 --progress
rclone copy arch:box    ~/restore/box    --progress
```

- **Archive tier = GLACIER_IR (instant retrieval)**: `arch:*` objects download
  directly, same as `bkup:` — no thaw step. (History: they were briefly plain
  GLACIER, which is _frozen_ — a restore drill caught it failing to GET — so they
  were re-tiered to GLACIER_IR via `--s3-storage-class GLACIER_IR`. Same $0.004/GB
  storage; a small $0.03/GB fee applies only when you actually restore.)
- **Recover a deleted/overwritten object (soft-delete, 30-day window)**: both
  buckets have soft-delete, so a bad sync (ransomware, accidental delete) is
  reversible for 30 days. List/restore prior versions via the Tigris dashboard or
  the S3 versioning API; the `--max-delete 5000` guard in the nightly also caps
  any single run's deletions.

## Verify integrity / restore drill

Spot-check one prefix:

```bash
rclone cryptcheck ~/Documents bkup:home/Documents --one-way --fast-list --exclude ".DS_Store"
```

Periodically (e.g. quarterly) run the full **restore drill** — it restores a
sample to a temp dir, verifies it decrypts and matches the source, and probes a
GLACIER fetch, then cleans up:

```bash
backup/restore-drill.sh
```

Last run: IA restore + decrypt + cryptcheck **PASS**. Archive was re-tiered to
GLACIER_IR (directly retrievable) — re-run the drill after the re-tier completes
to confirm the archive fetch now PASSes too.

## The nightly job

- `backup/tigris-backup.sh` → launchd `com.kylelundstedt.tigris-backup`,
  **daily 04:00**. Mini-only (hostname guard). Creds from the login Keychain
  (runs unattended).
- SQLite-checkpoints `msgvault.db`/`vectors.db`, then incremental `rclone sync`
  of: home, photos (→ backup bucket) and aws-s3, box, iphone-backup,
  messages-store (→ archive bucket). Recovery is via bucket soft-delete (30 days),
  not snapshots.
- Guards: skip if external drive unmounted, skip if another rclone is running,
  `--max-delete 5000` backstop, lock + 20h staleness. `lastrun` is written **only
  on full success** (a failed phase does not mark the run successful).
- Logs: `~/Library/Logs/tigris-backup/<date>.log` (30-day retention; the launchd
  `/tmp/tigris-backup.log` is just the latest and is wiped on reboot).

## Encrypted external drive (OWC8TB)

The external drive (`/Volumes/OWC8TB`) holds the archive sources (`aws_s3_backup`,
`iPhoneBackup`, `messages-store`, `Box_Download`) and the Photos library. It is
**encrypted in place with APFS** (FileVault-style), so a stolen/lost/RMA'd drive
is unreadable. The mini's internal disk is FileVault-encrypted, so keeping the
passphrase there preserves "stolen external drive alone = undecryptable."

- **Passphrase:** 1Password `OWC8TB disk encryption` (Personal, `password` field) —
  the authoritative recovery copy. Mirrored to the login Keychain
  (`security add-generic-password -s owc8tb-encryption`) for unattended unlock.
  Volume UUID `704B89D9-5896-4368-B518-D8CBD7EB4A15`.
- **Auto-unlock:** launchd agent `com.kylelundstedt.owc8tb-unlock` (RunAtLoad +
  hourly) runs `backup/owc8tb-unlock.sh`, which unlocks/mounts the drive from the
  Keychain after a reboot. The nightly also self-heals (calls the unlock script)
  and, if the drive still isn't mounted, registers a **failure** so the
  healthcheck goes red — an unmounted drive never silently "succeeds" with no
  archive backup.
- **Recovery (internal disk dead / another Mac):** get the passphrase from
  1Password, then `printf %s '<pass>' | diskutil apfs unlockVolume
704B89D9-5896-4368-B518-D8CBD7EB4A15 -stdinpassphrase`. Losing the passphrase
  does **not** lose the data — it's also in Tigris under a _different_ crypt key
  (`Tigris mini-backup rclone crypt`); restore from there.
- `install.sh` re-provisions the `owc8tb-encryption` Keychain item from 1Password
  on the mini (alongside the `tigris-backup:*` items).

## Monitoring (dead-man's-switch)

- healthchecks.io check pings `/start` at begin, **success only when every phase
  passed**, and `/fail` (with a summary) on any failure. It alerts if the daily
  success ping doesn't arrive — so it catches **both** failures **and the job not
  running at all** (crash, mac off, launchd skip).
- Ping URL is in the **login Keychain** (`tigris-backup:healthcheck-url`) and in
  1Password (`Tigris mini-backup rclone key` → `healthcheck_url`). If unset,
  pings are silently skipped (backup still runs).
- Check config: cron `0 4 * * *`, grace **8h**. Re-provision the Keychain item
  from 1Password on a rebuild (along with the `tigris-backup:*` cred items).

## CLI gotcha (tigris 3.x)

`tigris buckets create --enable-snapshots` / `--default-tier` are **silently
ignored** (flag-wiring bug). The buckets were created via the dashboard (which
sets `X-Tigris-Enable-Snapshot` + `X-Amz-Storage-Class` correctly). If recreating
via API, send those headers directly (e.g. boto3 `before-sign` hook).
