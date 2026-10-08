# hindsight-cc: architecture-aware, self-verifying Hindsight container

Date: 2026-10-08
Status: Approved 2026-10-08 (decisions O1-O4 resolved below). Implementation plan:
`docs/superpowers/plans/2026-10-08-hindsight-container-platform.md`

## Background

On 2026-10-06 the native arm64 `hindsight` container on this Apple Silicon Mac
(Docker Desktop) was crash-looping: `hindsight-api` died with
`Illegal instruction` (SIGILL, exit 132). An agent working in an unrelated
project recreated the container by hand with `docker run --platform linux/amd64 ...`
(Rosetta emulation) and moved `~/hindsight-data/installation` aside so the
embedded Postgres would re-download amd64 binaries. The plugin's
`scripts/ensure-hindsight.sh` was not involved and was not changed.

The result works but is not optimal, and the plugin's scripts no longer match
what is running. This spec makes the scripts architecture-aware and
self-verifying, and defines how to move the live container back to native arm64.

## Findings (verified 2026-10-08 unless marked otherwise)

| # | Finding | Evidence |
|---|---------|----------|
| F1 | **Native arm64 works today.** Full startup (API + embedded Postgres 18.1) is healthy in ~15 s, 0 `Illegal instruction` lines, 1.2 GiB container memory (`docker stats`) at idle. Real inference with the default local models (`BAAI/bge-small-en-v1.5`, `cross-encoder/ms-marco-MiniLM-L-6-v2`) succeeds. | Throwaway container from the same arm64 image on alternate port 18888 with a scratch volume, memory-capped at 1.4 GiB. Removed afterwards. |
| F2 | The crash happened on an older Docker engine and is **not reproduced**. Per the earlier agent's local session log the server was engine 24.0.2 at crash time; the VM now runs Docker Desktop 4.94.0 / engine 29.8.2. Cause is unproven. The earlier "SVE2" explanation is unsupported: the VM's `Features` line has no `sve`/`sme`. | `docker version`, `/proc/cpuinfo` inside the VM, that local session log (not part of this repo). |
| F3 | `ghcr.io/vectorize-io/hindsight:0.8.6` is a multi-arch OCI index (linux/amd64 + linux/arm64). Index digest `sha256:ffa391a77284...a232039`, the same digest the old arm64 container was pulled from. Docker picks arm64 on this host by default. | `docker buildx imagetools inspect`. |
| F4 | **Local-tag trap.** The local tag `...:0.8.6` now points at the amd64 variant. A plain `docker run` (what `ensure-hindsight.sh` does today) silently runs amd64 under Rosetta; the only signal is a stderr warning that the script discards. `docker run --platform linux/arm64` makes Docker fetch and retag the right variant. So a recreate today would produce another **amd64** container. | Reproduced on `busybox:1.36.1`: tag set to amd64, plain run printed `x86_64` with a platform-mismatch warning, `--platform linux/arm64` printed `aarch64`. |
| F5 | The embedded Postgres binaries are architecture-specific and live inside the data mount. `~/hindsight-data/installation/18.1.0/bin/postgres` is x86-64 (ELF `e_machine` bytes `3e 00`); `installation.arm64/...` is aarch64 (`b7 00`). `od -An -tx1 -j18 -N2 <binary>` detects this portably. Data dir is PG 18, ~1.2 GB. | `od` on both files. Whether an arm64 container would run the x86-64 binary through Rosetta binfmt is **unverified**. |
| F6 | **Memory.** Live amd64 container: 5.35 GiB; the `hindsight-api` process alone is 4.55 GB RSS (the Postgres processes each report ~330 MB RSS, mostly shared pages, so they are not additive). Docs say idle 0.8-1.0 GB, loaded 1.2-1.5 GB, recommended 2 GB. The Docker VM has 8 GiB shared with other development containers; only 1.8 GB was free during testing. Cause (Rosetta vs. workload backlog vs. leak) is **undetermined**. | `docker stats`, `ps` inside the container, `free -m` in the VM. |
| F7 | **The hand-built container dropped the plugin's safeguards.** `shm=64 MB` (plugin sets 2 GB to avoid `DiskFull` during migrations, see CHANGELOG), no stop timeout, no healthcheck, no memory limit, default unrotated logs. | `docker inspect hindsight`. |
| F8 | **Shutdown needs more than Docker's default.** The image traps SIGTERM and waits up to 30 s for Postgres to flush WAL; Docker's default stop timeout is 10 s, after which it SIGKILLs. The image defines no `HEALTHCHECK`, but calls `curl -sf <health>` itself, so `curl` is present. | `/app/start-all.sh` in the image; `docker image inspect`. |
| F9 | Docs recommend `--restart unless-stopped`, a named volume, `--shm-size=1g`, and a stable `HINDSIGHT_API_WORKER_ID` so stuck tasks can be recovered when the container ID changes. The plugin sets neither a restart policy nor a worker ID. | hindsight.vectorize.io/developer/installation. |
| F10 | The API key is passed as `-e HINDSIGHT_API_LLM_API_KEY=<value>` on the `docker run` command line, visible in `ps` while the command runs. A bare `-e NAME` forwards the value from the process environment instead. | `scripts/ensure-hindsight.sh` `create_container`. |
| F11 | `pi-ndsight` also creates the shared container (`docker compose`, falling back to `docker run`), pins image `0.7.2`, passes no `--platform`, and its compose file still says `container_name: pindsight`. Whichever tool creates the container first decides its flags. | `pi-ndsight` repo: `src/pindsight/server.ts`, `docker-compose.yml`. |

## Goals

- G1. The container runs the host's native architecture by default and is never
  *silently* emulated.
- G2. An explicit, documented override (`HINDSIGHT_PLATFORM`) exists in case a
  future Docker release regresses native arm64.
- G3. `docker run` flags follow the Hindsight docs and the findings above.
- G4. An existing container that has drifted (wrong arch, crash-looping) is
  detected and reported, without ever clobbering a healthy shared server.
- G5. The live container is migrated to native arm64 with a snapshot and a
  tested rollback.
- G6. All new behavior is covered by the existing no-Docker shell test harness.

## Non-goals

- Replacing Docker with the `hindsight-embed` daemon (see Approach C).
- Moving to an external Postgres, a named volume, or the slim image with remote
  embeddings.
- Changing the LLM configuration flow (`/hindsight-cc:setup`, `config.env`).
- Changing `pi-ndsight` (follow-up; see Risks).
- Root-causing the 4.5 GB RSS (measured after migration, see Migration step 6).

## Approaches considered

**A. Keep Docker; make `ensure-hindsight.sh` architecture-aware and
self-verifying. (Recommended.)** Pin `--platform` to the Docker daemon's
architecture, apply the documented run flags, detect drift, add an explicit
`recreate` subcommand, and migrate the live container back to native arm64.
F1 shows native works; F4 shows the script is otherwise one `docker pull` away
from silent emulation.

**B. Keep amd64 and pin it** (`--platform linux/amd64` as the default).
Smallest diff and no data surgery. Rejected: it runs Postgres and torch under
Rosetta permanently, it is the configuration with the unexplained 5.35 GiB
footprint (F6), and it only exists because of a crash that F1/F2 show is no
longer reproducible. It stays available as the `HINDSIGHT_PLATFORM` override.

**C. Move to the official `hindsight-embed` daemon (no Docker).** This is the
route the official Claude Code integration documents (`uvx hindsight-embed`,
default port 9077, auto-exit after 5 min idle, profile files under
`~/.hindsight/`), and it removes the Docker VM from the picture. Rejected for
now: it changes the port, data location, and lifecycle; breaks the shared
container and bank data that `pi-ndsight` and the existing memories rely on;
and rewrites the setup flow. Worth a separate evaluation, not a side effect of
fixing this incident.

## Design (Approach A)

All script changes are in `scripts/ensure-hindsight.sh` (POSIX sh, as today)
plus one small Python helper and docs. Existing invariants are preserved:
health-probe-first reuse, never touch a healthy container, soft-exit 0 when
Docker is absent, config precedence `env > config.env > default`.

### D1. Platform resolution

`resolve_platform` sets `EFF_PLATFORM`:

1. `HINDSIGHT_PLATFORM` from the environment, then from `config.env`: the first
   value that is exactly `linux/arm64` or `linux/amd64` wins. Any other value is
   ignored (debug log), so an invalid environment value does not hide a valid
   `config.env` one.
2. Otherwise map `docker info --format '{{.Architecture}}'`:
   `aarch64`/`arm64` becomes `linux/arm64`, `x86_64`/`amd64` becomes
   `linux/amd64`. Use the **daemon** architecture, not `uname -m`, so remote
   daemons and Intel hosts are right.
3. Otherwise empty: omit `--platform` (today's behavior).

`config_get`'s key allowlist grows from the four `HINDSIGHT_API_LLM_*` keys to
those plus `HINDSIGHT_PLATFORM` and `HINDSIGHT_MEMORY_LIMIT`.

### D2. Container creation

`create_container` builds the command from one place. Flags and why:

| Flag | Value | Reason |
|------|-------|--------|
| `--platform` | `$EFF_PLATFORM` (omitted if empty) | F4 |
| `--restart` | `unless-stopped` | F9; survives Docker Desktop restarts |
| `--stop-timeout` | `40` | F8: image waits up to 30 s for WAL flush |
| `--shm-size` | `2g` (unchanged) | F7: prior `DiskFull` fix, above the docs' 1g minimum |
| `--memory`, `--memory-swap` | `$HINDSIGHT_MEMORY_LIMIT`, default `4g`, `none` disables | F6: bound the blast radius in an 8 GiB VM; docs recommend 2 GB; see Decision O1 |
| `--health-cmd` | `curl -sf http://localhost:8888/health` | F8; observability only, plain Docker does not restart on unhealthy |
| `--health-interval/-timeout/-retries/-start-period` | `30s` / `5s` / `3` / `120s` | long start period covers first-run model load and migrations |
| `--log-opt` | `max-size=10m`, `max-file=3` | the old crash loop wrote unbounded repeated lines |
| `-e HINDSIGHT_API_WORKER_ID` | `hindsight-local` | F9; stable across recreates |
| `-e HINDSIGHT_API_LLM_API_KEY` | bare name, value inherited from the environment; omitted when no key is set (local providers), as today | F10: the secret never appears in argv |
| unchanged | `-p 8888:8888 -p 9999:9999`, the data bind mount to `/home/hindsight/.pg0` (host side `~/hindsight-data`, now overridable with `HINDSIGHT_DATA_DIR`, which also lets the tests use a throwaway directory), `HINDSIGHT_IMAGE` override, provider/model/base-URL `-e` pairs | keeps sharing with `pi-ndsight` |

The image stays pinned by tag (`0.8.6`). `--platform` selects the variant and
Docker pulls it if only the other variant is present locally (verified, F4).

### D3. Drift detection (diagnose, never clobber)

New helpers: `container_image_arch <name>` (via `docker inspect -f '{{.Image}}'`
then `docker image inspect -f '{{.Architecture}}'`) and `platform_drift`
(container arch differs from the architecture implied by `EFF_PLATFORM`).

- **Healthy server:** exit 0 without touching anything, as today. Drift is
  surfaced only through D5 (status) and `HINDSIGHT_DEBUG`. SessionStart stdout
  is injected into the model's context and stderr is not reliably shown to the
  user, so a warning there is easy to miss.
- **Not healthy, container exists:** if it has exited with 132 (SIGILL), 126, or
  127, or is restarting, do not run `docker start` in a loop. Print a one-line
  diagnosis to stderr naming the exit code and the two remedies
  (`HINDSIGHT_PLATFORM=linux/amd64 ensure-hindsight.sh recreate`, or file an
  issue with the logs) and exit 1.

### D4. `ensure-hindsight.sh recreate` (explicit, never run by hooks)

1. Refuse if `hindsight-prev` already exists (never auto-delete rollback state);
   a refusal never takes the server down.
2. `docker stop -t 60 hindsight`.
3. `docker rename hindsight hindsight-prev`. The old container is kept, stopped,
   as the rollback target. Two containers must never run on the same data dir.
4. **pg0 installation guard.** Read `~/hindsight-data/installation/*/bin/postgres`
   with `od -An -tx1 -j18 -N2`. If its architecture does not match `EFF_PLATFORM`,
   move it to `installation.<arm64|amd64>` (never delete) and, if a previously
   saved `installation.<matching-arch>` exists, move that into place; otherwise
   leave `installation` absent and let pg0 download the right one (as the earlier
   agent's amd64 run did). Runs only here and when no container exists, never
   against a healthy server.
5. `create_container`, then wait for health with a 180 s deadline (the hook path
   keeps its 24 s deadline; the wait becomes a parameter, and
   `HINDSIGHT_RECREATE_WAIT_SECONDS` overrides the 180 s, mainly for tests).
6. Verify image arch equals the requested platform and health is ok. On any
   failure: remove the new container, undo the `installation` swap, rename
   `hindsight-prev` back, `docker start hindsight`, exit 1.

### D5. Status surface

`/hindsight-cc:memory-status` (`scripts/get-status.py`) gains a **Container**
section, produced by a new stdlib helper `scripts/container_info.py` (soft-fails
if `docker` is missing): image tag, image architecture, resolved platform,
state, restart count, health, memory use vs. limit, and an explicit line such as
`EMULATED: container is linux/amd64 on an arm64 daemon` when drift exists.

### D6. Docs and setup command

- `commands/setup.md` "After" section: replace the `docker rm -f hindsight`
  advice (which discards the safety net) with `ensure-hindsight.sh recreate`.
- `README.md`: add `HINDSIGHT_PLATFORM` and `HINDSIGHT_MEMORY_LIMIT` to the
  config table; add a troubleshooting entry for emulation and exit 132.
- `CLAUDE.md`: update the Hindsight Integration bullets.
- `CHANGELOG.md`: new entry.

## Migration of the live container (runbook; run after the plan is approved)

Not automated by hooks. The goal is to move to native arm64 with a rollback.

0. **Precondition: LLM key.** `recreate` takes the key from the environment or
   `~/.config/hindsight-cc/config.env`. Supply it at run time from a secret
   manager (for example the 1Password CLI, `op`) into the environment of that
   single command only. Never write it to `config.env`, shell history, a script,
   or a log, and never print it. A stale or missing key shows up as HTTP 401/429
   from the LLM provider after the container comes up.
1. `docker stop -t 60 hindsight` (graceful; the image needs up to 30 s).
2. Fresh snapshot: `cp -R ~/hindsight-data ~/hindsight-data.pre-arm64-<date>`
   (about 1.3 GB; check free disk first). Any older backup predates recent
   writes, so take a fresh one.
3. `ensure-hindsight.sh recreate` with `EFF_PLATFORM=linux/arm64`. Because
   `installation.arm64` already exists, the guard swaps it back into place.
4. Verify: health 200; image arch `arm64`; the on-disk Postgres binary is
   aarch64; a recall against a known bank returns results; the retain backlog
   drains; `docker stats` shows native memory.
5. **Index integrity.** The data directory was written on arm64, then on amd64,
   and now arm64 again. Cross-architecture reuse of a same-major-version
   Postgres data directory is generally supported, but default `char`
   signedness differs between x86-64 and aarch64 and can affect some index
   types. The database is about 1.2 GB, so run `REINDEX DATABASE` as cheap
   insurance (confirm the exact guidance against the PG 18 docs during
   implementation).
6. **Soak 24-48 h.** Record `hindsight-api` RSS under the real workload. This
   settles F6 (Rosetta, backlog, or leak) and the final default for
   `HINDSIGHT_MEMORY_LIMIT` (Decision O1).
7. **Retire.** After the soak: remove `hindsight-prev`, any other leftover
   pre-migration containers (their environment still holds the previous API
   key, so rotate that key if it is still live), `installation.amd64`, and the
   snapshots.

**Rollback** at any point before step 7: stop the new container, remove it,
rename `hindsight-prev` back to `hindsight`, swap `installation` back, and
`docker start hindsight`. `recreate` automates this for failures in steps 3-4.

## Error handling

| Situation | Behavior |
|-----------|----------|
| Docker missing or daemon down | unchanged: soft-exit 0 |
| Daemon architecture unknown or unmapped | omit `--platform` (today's behavior) |
| Invalid `HINDSIGHT_PLATFORM` | ignored, debug log |
| Healthy server | never touched (existing invariant) |
| Container exited 132/126/127 or restarting | no `docker start` loop; diagnosis to stderr; exit 1 |
| `recreate` fails after rename | automatic rollback (D4 step 6) |
| `hindsight-prev` already exists | refuse; never delete rollback state |

## Testing

Extend `scripts/test/test_ensure_hindsight.sh` (fake `docker`/`curl`/`sleep`
shims, no real Docker) and add `scripts/test/test_container_info.py`:

1. Platform resolution matrix: `aarch64` gives `linux/arm64`, `x86_64` gives
   `linux/amd64`, unknown gives empty, override wins, invalid override ignored.
2. Create path always passes `--platform` when resolvable, includes every D2
   flag, and the API key value never appears in the recorded argv (bare
   `-e HINDSIGHT_API_LLM_API_KEY` only).
3. Drift matrix: container arch vs. `EFF_PLATFORM`.
4. Healthy-server invariant: no mutating `docker` call when `/health` answers
   (existing test, kept).
5. Installation guard on synthetic ELF headers written with `printf`: x86 vs.
   arm detection, swap, restore of a saved matching dir, and never deleting.
6. `recreate` rollback: fake `docker` that fails the new container's health
   check leaves the original container running under its original name.
7. Crash classification: exit 132 gives a diagnosis and exit 1, with no
   `docker start` call.
8. `container_info.py` parsing, including `docker` absent.

**Manual acceptance on this machine:** every Migration step 4 check; a second
`ensure-hindsight.sh` run is a no-op; `/hindsight-cc:memory-status` shows
`native` and no `EMULATED` line; `docker rm -f hindsight && ensure-hindsight.sh`
recreates a native arm64 container with all D2 flags (checked by
`docker inspect`).

## Risks

- **SIGILL returns after a Docker Desktop update.** Mitigated by the
  `HINDSIGHT_PLATFORM=linux/amd64` override and the exit-132 diagnosis (D3).
- **Cross-architecture index issues** after the platform flip. Mitigated by the
  snapshot and the `REINDEX` step.
- **Memory limit too low** causes OOM-kill and restart. Mitigated by the 24-48 h
  soak before the default is finalized; Postgres recovers from WAL after a kill.
- **`pi-ndsight` can create the container first** with different flags and image
  (F11). Follow-up: give it the same `--platform`, restart/health/stop-timeout
  flags, image pin, and container name, in its own spec.
- **The `installation` guard moves files inside the data mount.** It only moves
  (never deletes), runs only when no container is using the directory, and is
  covered by tests on synthetic headers.

## Decisions (resolved 2026-10-08)

- **O1. Default memory limit: `4g`** (above the docs' 2 GB, well below the
  8 GiB VM). Finalized after the Migration step 6 soak.
- **O2. Drift handling: report only** in `/hindsight-cc:memory-status`, with
  `recreate` as the explicit remedy. No auto-recreate at SessionStart.
- **O3. Stay on Docker** (Approach A). The `hindsight-embed` daemon (C) is a
  separate future evaluation.
- **O4. Key source for `recreate`: 1Password at run time.** The operator exports
  the key into the environment from `op` without printing it (for example
  `HINDSIGHT_API_LLM_API_KEY="$(op item get <item> --fields password --reveal)"
  ensure-hindsight.sh recreate`). `config.env` is not modified. The key travels
  to the container through the inherited environment (D2), never argv.
