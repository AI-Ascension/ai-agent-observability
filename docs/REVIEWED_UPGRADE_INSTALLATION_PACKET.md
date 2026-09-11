# Reviewed upgrade installation packet

## Exact merged source

This packet is source preparation for merged commit
`c309c8e532574754609d9491f0a10be584f83a83`, tree
`7028a3b76581a4ac7e65bc9b282212ac9342aae9`. It describes a future
root-reserved installation only. It does not authorize sudo, filesystem writes
on the target host, an engine invocation, a service stop, secret transfer, or
deployment.

The reviewed wrapper is compatible with the observed deployed Compose source
digest `6a4f31c411d03e54a6d0d88ef0bc6d65fc18061e1adafc7af94d8f08c6dd7b6f`:
12 baseline services, six baseline volumes, and external network
`ai-agent-observability-net`. This is source-declaration evidence, not a fresh
runtime inventory. Root must obtain a reserved read-only inventory immediately
before a separately authorized mutation.

## Why a new canonical source is required

`/home/completetrain/ai-agent-observability` has a user-owned ancestor. The
reviewed wrapper deliberately rejects it. Do not repair that with `chown`, a
broad `chmod`, a symlink, a bind mount, or an in-place source relocation. Do
not touch its `.env`, systemd unit, workloads, volumes, network, or mounts.

Use these new root-owned paths instead:

| Purpose | Path | Required property |
| --- | --- | --- |
| Canonical materialized source | `/srv/ai-agent-observability-reviewed/live` | root-owned regular tree; no symlink or group/other write in any component |
| Clean candidate checkout | `/srv/ai-agent-observability-reviewed/candidate/c309c8e532574754609d9491f0a10be584f83a83` | root-owned clean Git checkout at the exact merged commit |
| Backup and journal root | `/var/backups/ai-agent-observability-reviewed-upgrade` | root:root `0700` |
| Installed wrapper | `/usr/local/sbin/ai-agent-observability-reviewed-upgrade` | root:root `0755`; byte-identical to the merged wrapper |
| Protected configuration | `/etc/ai-agent-observability-reviewed-upgrade.conf` | root:root `0600` |

The live tree is a copy, not a reference to the user-owned tree. Its `.env` is
copied once through a root-only file descriptor into a newly created root-owned
`0600` regular file; it is excluded from Git/source materialization, command
arguments, logs, and records. The candidate checkout retains root-owned Git
metadata because the wrapper verifies its exact clean HEAD.

## Protected configuration and immutable reader

After path creation and root-owned boundary checks, the config has exactly one
of every key:

```ini
DEPLOYMENT_ROOT=/srv/ai-agent-observability-reviewed/live
CANDIDATE_ROOT=/srv/ai-agent-observability-reviewed/candidate/c309c8e532574754609d9491f0a10be584f83a83
BACKUP_ROOT=/var/backups/ai-agent-observability-reviewed-upgrade
ENGINE_BIN=/usr/bin/podman
READER_IMAGE_ID=sha256:<approved-already-local-64-lowercase-hex-image-id>
BASELINE_COMPOSE_SHA256=6a4f31c411d03e54a6d0d88ef0bc6d65fc18061e1adafc7af94d8f08c6dd7b6f
```

The reader value is a required immutable image ID, not a tag and not a value to
guess. Root must identify an already-local approved reader image using
`/usr/bin/podman image inspect --format '{{.Id}}' <approved-reference>` and
place that exact returned ID in the protected config. Pulling an image is not
part of this packet. The wrapper rechecks the exact ID before archive use and
uses it without network, with a read-only root filesystem, dropped capabilities,
and only its named source/archive mounts.

## Future root sequence after authorization

1. Record read-only source, unit, project, container identity/state/labels,
   volume identity, external network identity, mount relationship, and `.env`
   metadata. Keep this distinct from source declaration evidence.
2. Build and verify the new canonical live and candidate trees while leaving the
   original source and running workload untouched. Verify candidate commit,
   clean state, modes, ownership, and protected config.
3. From the candidate, generate the four identity arguments with
   `OBSERVABILITY_EXPECTED_GIT_HEAD=c309c8e532574754609d9491f0a10be584f83a83 deploy/prepare-reviewed-upgrade.sh --plan`.
   Do not add paths, project names, secrets, or an engine argument.
4. Only with a separate reservation invoke the installed wrapper. It checks the
   baseline source digest; rejects unknown project objects; journals baseline
   identities; confirms exact journaled container IDs before stopping them;
   archives only the six existing volumes; materializes the full tracked tree;
   and starts the fixed Compose project. It has no `compose down`, volume
   deletion, image-pruning, or caller-controlled-path operation.
5. Treat systemd path switching, health checks, trace ingestion, backend query,
   persistence, and public/private access as later independent gates. Do not
   infer them from a successful source materialization or Compose command.

## Failure boundary

The backup root and each newly created ancestor are private (`0700`); existing
ancestors are never chmodded. The wrapper journals pre-existing and newly
created identities, restores source on post-materialization failure, stops only
baseline containers whose IDs remain journaled identities, and removes only an
exact recorded new container. It never deletes a volume automatically.

Volume archive restore, old-tree restart, object deletion, or systemd cutover
requires separate quiesced authorization and a new identity/data-loss review.
Keep the original source, secret file, mounts, and workloads until distinct
runtime and end-to-end evidence exists.

## Only indispensable entitlement inputs

Before requesting root installation authority, root needs:

1. approval to create the listed root-owned canonical paths and perform a
   non-disclosing one-time protected `.env` transfer;
2. the exact already-local approved reader-image ID; and
3. a reservation for the later fresh inventory and wrapper invocation.

All host, engine, installation, runtime, CI, backend-persistence, and live
deployment claims remain unverified at this source-preparation stage.
