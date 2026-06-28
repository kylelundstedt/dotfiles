# klundstedt-mini → Tigris Backup Runbook

Encrypted off-site backup of the always-on Mac mini (`klundstedt-mini`) to Tigris
object storage. **This doc is the disaster-recovery reference — an encrypted
backup is worthless if you can't decrypt it. Keep the credentials below in
1Password; this file documents only item names and procedure, never secrets.**

## What's backed up

| Source | Tigris bucket | Prefix | Tier |
| --- | --- | --- | --- |
| `~/` (minus excludes) | `klundstedt-mini-backup` | `home/` | IA |
| External Photos library (`/Volumes/OWC8TB/Photos Library.photoslibrary`) | `klundstedt-mini-backup` | `photos/` | IA |
| `/Volumes/OWC8TB/aws_s3_backup` | `klundstedt-mini-archive` | `aws-s3/` | GLACIER |
| `/Volumes/OWC8TB/Box_Download_2025-01-12` | `klundstedt-mini-archive` | `box/` | GLACIER |

- Both buckets: **private, multi-region USA**. `klundstedt-mini-backup` has
  **snapshots enabled** (point-in-time recovery); `klundstedt-mini-archive` does not
  (GLACIER and snapshots are mutually exclusive).
- Excludes: `tigris-backup-excludes.txt` (caches, logs, `node_modules`/`.venv`,
  `.lmstudio/models`, `.Trash`, `.DS_Store`, sockets).
- **Client-side encryption** via rclone `crypt` (standard filename + directory
  name encryption). Tigris stores ciphertext only.

## Credentials (all in 1Password, `industryvault` account)

| Purpose | 1Password item (vault) | Fields |
| --- | --- | --- |
| Crypt password (decrypts everything — **critical**) | `Tigris mini-backup rclone crypt` (Personal) | `password`, `salt` |
| Dedicated rclone key (Editor on both buckets) | `Tigris - mini-backup key (rclone)` (Personal) | `access_key_id`, `password` (=secret) |
| Tigris admin (create buckets/keys) | `Tigris - klundstedt Work` (Personal) | `access_key_id`, `secret_access_key`, `endpoint_url` |

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
KEY="Tigris - mini-backup key (rclone)"; CRYPT="Tigris mini-backup rclone crypt"
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

- **GLACIER restore caveat**: `arch:*` objects are Archive tier. If a direct
  `copy` errors with an InvalidObjectState / not-retrievable condition, the
  objects must be restored (thawed) first — check current Tigris Archive
  retrieval docs at restore time.
- **Point-in-time (snapshots)**: list with `tigris snapshots list klundstedt-mini-backup`;
  recover a prior state via a fork from the snapshot
  (`tigris buckets create restore-fork --fork-of klundstedt-mini-backup --source-snapshot <version>`),
  then point a crypt remote at the fork and `copy` out.

## Verify integrity

```bash
rclone cryptcheck ~/Documents bkup:home/Documents --one-way --fast-list
```

## The nightly job

- `backup/tigris-backup.sh` → launchd `com.kylelundstedt.tigris-backup`,
  **daily 04:00**. Mini-only (hostname guard). Creds from the login Keychain
  (runs unattended).
- SQLite-checkpoints `msgvault.db`/`vectors.db`, then incremental `rclone sync`
  of: home, photos (→ backup bucket) and aws-s3, box, iphone-backup,
  messages-store (→ archive bucket), then a snapshot of `klundstedt-mini-backup`.
- Guards: skip if external drive unmounted, skip if another rclone is running,
  `--max-delete 5000` backstop, lock + 20h staleness. `lastrun` is written **only
  on full success** (a failed phase does not mark the run successful).
- Logs: `~/Library/Logs/tigris-backup/<date>.log` (30-day retention; the launchd
  `/tmp/tigris-backup.log` is just the latest and is wiped on reboot).

## Monitoring (dead-man's-switch)

- healthchecks.io check pings `/start` at begin, **success only when every phase
  passed**, and `/fail` (with a summary) on any failure. It alerts if the daily
  success ping doesn't arrive — so it catches **both** failures **and the job not
  running at all** (crash, mac off, launchd skip).
- Ping URL is in the **login Keychain** (`tigris-backup:healthcheck-url`) and in
  1Password (`Tigris - mini-backup key (rclone)` → `healthcheck_url`). If unset,
  pings are silently skipped (backup still runs).
- Check config: cron `0 4 * * *`, grace **8h**. Re-provision the Keychain item
  from 1Password on a rebuild (along with the `tigris-backup:*` cred items).

## CLI gotcha (tigris 3.x)

`tigris buckets create --enable-snapshots` / `--default-tier` are **silently
ignored** (flag-wiring bug). The buckets were created via the dashboard (which
sets `X-Tigris-Enable-Snapshot` + `X-Amz-Storage-Class` correctly). If recreating
via API, send those headers directly (e.g. boto3 `before-sign` hook).
