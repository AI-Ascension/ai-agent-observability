# Reviewed upgrade installation packet

## Exact merged source

This packet is the bounded root-installation artifact for merged commit
`7c5f3eab18446dea7f1eeafb8427cbe574c1d199`, tree
`2e4076d66b529a54968871724f9ca97723af7e9e`. The existing-test-environment
deployment scope already authorizes this work; root coordinates the reserved
operations. The blocker is unavailable rootful/sudo entitlement, not missing
per-step consent for the listed paths, protected `.env` transfer, reservation,
or the read-only reader-ID discovery. The later stop-after-merges scope
supersedes that live authority for this delivery: this packet is source-only,
and its root execution, `.env` transfer, reader inspection, wrapper invocation,
and all host mutations are explicitly deferred by user instruction. It has not
been run and makes no host-write, engine, service, secret-transfer, or
deployment claim.

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
| Clean candidate checkout | `/srv/ai-agent-observability-reviewed/candidate/7c5f3eab18446dea7f1eeafb8427cbe574c1d199` | root-owned clean Git checkout at the exact merged commit |
| Backup and journal root | `/var/backups/ai-agent-observability-reviewed-upgrade` | root:root `0700` |
| Installed wrapper | `/usr/local/sbin/ai-agent-observability-reviewed-upgrade` | root:root `0755`; byte-identical to the merged wrapper |
| Protected configuration | `/etc/ai-agent-observability-reviewed-upgrade.conf` | root:root `0600` |

The live tree is a copy, not a reference to the user-owned tree. Its `.env` is
copied once through a root-only file descriptor into a newly created root-owned
`0600` regular file; it is excluded from Git/source materialization, command
arguments, logs, and records. The candidate checkout retains root-owned Git
metadata because the wrapper verifies its exact clean HEAD.

## Observed entitlement boundary

Under `OBS-READ-01`, the exact read-only command `sudo -n -l` reported that
`completetrain` may run `(ALL : ALL) ALL`, but only
`/usr/local/sbin/podman-svc *` and an unrelated image-video runner were
`NOPASSWD`. The same reservation constrained `podman-svc` to root `ps` and
`health` plus one unrelated named restart; it provides no generic inspect,
install, file-copy, Compose, or rootful upgrade operation. Thus noninteractive
rootful installation authority is unavailable even though an interactive sudo
rule is listed. This is confirmed historical host-policy evidence, not a claim
about a current grant.

If a later user scope restores host execution and supplies the entitlement,
root discovers the approved reader's exact already-local immutable ID
read-only and supplies it as `READER_IMAGE_ID` to the installation script. It
is an image identity, not a credential.

## Protected configuration and immutable reader

After path creation and root-owned boundary checks, the config has exactly one
of every key:

```ini
DEPLOYMENT_ROOT=/srv/ai-agent-observability-reviewed/live
CANDIDATE_ROOT=/srv/ai-agent-observability-reviewed/candidate/7c5f3eab18446dea7f1eeafb8427cbe574c1d199
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

## Root-coordinated installation and later reservation

Do not run this script under the current stop-after-merges scope. If a later
user scope restores the host operation, root may run the committed
`deploy/install-reviewed-upgrade-root-packet.sh --install` from a clean
reviewed checkout that contains the exact merged candidate as an ancestor, as
root, with only the non-secret immutable
`READER_IMAGE_ID=sha256:...` and `REVIEWED_PACKET_SHA256=<root-recorded-sha256>`
environment inputs. Root records the installer SHA-256 from the independently
reviewed committed delivery before invocation; the script recomputes and
requires that external value before any host operation. It refuses a dirty
checkout, a checkout missing the exact candidate ancestor, non-baseline legacy
Compose source, existing destination paths, nonlocal reader image, or an
installer that differs from the root-recorded review. It creates only the listed root-owned paths;
makes a root-owned clean candidate clone; copies the legacy tree into the new
live tree; transfers `.env` directly into its final mode-0600 path without
logging it; installs the reviewed wrapper and protected config; and writes a
0600 identity-and-content manifest. The legacy tree and `.env` are copied only
through descriptor-bound, no-follow reads; symlinks, special files, changed
entries, and files larger than the fixed 64 MiB copy bound are refused. It does not call Compose, start/stop workloads,
pull images, alter the old source, change any parent ownership, or replace
canonical source. A failed installation preserves any new listed paths for
explicit identity review; it does not guess which partial state is disposable.

Before the wrapper has been invoked, root may run the same script with
`--rollback-install`. It removes only the listed newly-created packet paths and
refuses unless its root-owned manifest schema, each recorded device/inode/type
identity, and the complete candidate/live/config/wrapper content digests all
match. It also refuses if the backup root contains anything beyond that
manifest. Failed installation preserves all partial paths and, once created,
their root-owned partial journal for manual identity review rather than guessing
that data is disposable. A failed rollback leaves its root-only rollback-state
record in place and is never resumed automatically. These refusals are deliberate: a wrapper journal can mean source
replacement or volume archives exist, requiring the wrapper's recovery record
and a distinct quiesced data review. It never auto-restores volumes or restarts
the old tree.

After installation, root reserves the following operations as one coordinated
host window; no per-step user reauthorization is implied:

1. Record read-only source, unit, project, container identity/state/labels,
   volume identity, external network identity, mount relationship, and `.env`
   metadata. Keep this distinct from source declaration evidence.
2. Build and verify the new canonical live and candidate trees while leaving the
   original source and running workload untouched. Verify candidate commit,
   clean state, modes, ownership, and protected config.
3. From the candidate, generate the four identity arguments with
   `OBSERVABILITY_EXPECTED_GIT_HEAD=7c5f3eab18446dea7f1eeafb8427cbe574c1d199 deploy/prepare-reviewed-upgrade.sh --plan`.
   Do not add paths, project names, secrets, or an engine argument.
4. Invoke the installed wrapper only within that reservation. It checks the
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
requires a separate quiesced data-loss review. These are not performed by the
installation script or automatically authorized by its rollback.
Keep the original source, secret file, mounts, and workloads until distinct
runtime and end-to-end evidence exists.

## Only missing entitlement

If a later user scope restores execution, the only then-missing input is a
bounded rootful/sudo entitlement covering the fixed installation script and
the coordinated wrapper reservation. With that entitlement, root discovers the
reader ID read-only and keeps it in the protected config. The current scope
does not permit seeking, exercising, or waiting on that entitlement.

The later wrapper still has material risk: it can replace the canonical source
and archive named volumes; any volume restore remains a separately reviewed,
quiesced action. All host, engine, installation, runtime, CI,
backend-persistence, and live deployment claims remain unverified until their
respective gates run. Under the 2026-09-11 stop-after-merges scope, those live
operations are deferred by user instruction rather than pending work here.
