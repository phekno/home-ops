# Migrate Longhorn Backups from AWS S3 to Backblaze B2

**Date:** 2026-06-11
**Status:** Approved for planning

## Goal

Reduce monthly object-storage cost for Longhorn volume backups by moving the
backup target from AWS S3 to Backblaze B2. B2 storage is ~$6/TB-month versus
~$23/TB-month for S3 Standard. B2 is S3-compatible, so this is a configuration
change only — no application code, no new Longhorn driver.

Cost is the sole decision driver. Egress is not a concern: backups are
write-heavy and restores are rare.

## Current State

- **Backup target:** `s3://phekno-longhorn-backup@us-east-1/` (AWS S3)
  - `kubernetes/apps/longhorn-system/longhorn/app/helmrelease.yaml:54`
- **Credentials:** 1Password item `longhorn-backup` → ExternalSecret
  `longhorn-backup`, exposing `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
  - `kubernetes/apps/longhorn-system/longhorn/app/externalsecret.yaml`
- **Schedule:** RecurringJob `daily-backup`, `retain: 1` (one backup kept;
  recreated nightly) — `recurringjob.yaml`

Because only one backup is retained and it regenerates nightly, a clean cutover
is low-risk: no historical data migration is needed.

## Backblaze Side (already done by user)

- Bucket `phekno-longhorn-backup` created, region `us-west-004` (private).
- Application key scoped to the bucket created.
- 1Password item `longhorn-backup` updated with **B2-prefixed** fields so the
  old AWS keys can coexist during cutover:
  - `BB_AWS_ACCESS_KEY_ID` = B2 keyID
  - `BB_AWS_SECRET_ACCESS_KEY` = B2 applicationKey
  - `AWS_ENDPOINTS` = `https://s3.us-west-004.backblazeb2.com`
    (**must** include the `https://` scheme — Longhorn rejects a bare host)

## Configuration Changes (git)

### 1. `externalsecret.yaml`

Map the B2-prefixed 1Password fields onto the AWS env-var names Longhorn's S3
driver expects, and add the custom endpoint:

```yaml
target:
  name: longhorn-backup
  template:
    data:
      AWS_ACCESS_KEY_ID: "{{ .BB_AWS_ACCESS_KEY_ID }}"
      AWS_SECRET_ACCESS_KEY: "{{ .BB_AWS_SECRET_ACCESS_KEY }}"
      AWS_ENDPOINTS: "{{ .AWS_ENDPOINTS }}"
```

`dataFrom` already extracts the whole `longhorn-backup` item, so all three keys
are available without additional fetch blocks.

### 2. `helmrelease.yaml`

Change the backup target bucket URL:

```yaml
defaultBackupStore:
  backupTarget: s3://phekno-longhorn-backup@us-west-004/
  backupTargetCredentialSecret: longhorn-backup
```

The S3 driver picks up the Backblaze endpoint from `AWS_ENDPOINTS` in the
secret. The `@us-west-004` segment is the region label; it must match the
region in the endpoint host.

## Cutover & Verification

1. Commit both file changes; let Flux reconcile.
2. Confirm ExternalSecret synced (secret has all three keys, including the new
   `AWS_ENDPOINTS`). Force a refresh if needed so the rotated credentials land.
3. In the Longhorn UI, confirm the backup target connects with no error.
4. Trigger a manual backup of one volume → confirm objects appear in the B2
   bucket.
5. Run a **test restore** from that B2 backup into a scratch volume to prove a
   full round-trip.
6. Once verified, **decommission S3**: delete the AWS bucket and revoke/delete
   the AWS IAM access keys. Optionally remove the now-unused
   `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` fields from the 1Password item.

## Risks & Fallback

- **Bare endpoint host:** if `AWS_ENDPOINTS` lacks `https://`, the target fails
  to connect. Verify before cutover.
- **Addressing style:** if the target errors despite correct creds/endpoint, the
  common B2+Longhorn fix is adding `VIRTUAL_HOSTED_STYLE: "false"` (path-style)
  to the secret template. Applied only if needed, not preemptively.
- **Rollback:** S3 is untouched until step 6. Reverting the two-file commit
  (and the 1Password key mapping) restores the prior working state.

## Out of Scope

- Migrating existing S3 backup objects (unnecessary given `retain: 1`).
- Changing the backup schedule, retention, or recurring-job config.
- Cloudflare R2 (rejected: higher storage cost than B2).
