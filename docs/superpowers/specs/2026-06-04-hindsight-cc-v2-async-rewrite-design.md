# hindsight-cc v2 — REST-direct, async hooks, shared container, `/setup` wizard

Date: 2026-06-04
Status: Approved (design)

## Background

`hindsight-cc` is a Claude Code plugin providing persistent memory via a local
Hindsight server in Docker. The sibling project `pi-ndsight` (a pi-coding-agent
extension) re-implemented the same idea with a faster, cleaner architecture. This
spec ports the relevant improvements back to `hindsight-cc`.

The two projects have **fundamentally different runtimes**:

- `pi-ndsight` runs as a long-lived TypeScript process. It can keep a background
  retain queue, reuse `fetch` connections, and bound calls with `AbortController`.
- `hindsight-cc` runs as Claude Code **hooks** — each hook is a fresh subprocess
  invoked per event. There is no long-lived process to hold a queue or warm
  connection.

So we port pi-ndsight's *behavior*, not its code, using mechanisms available to a
subprocess-based hook system.

### Problems in the current implementation

1. **Hooks are slow (primary complaint).** Every hook spawns `.venv/bin/python3`
   and imports `hindsight_client` (which pulls in pydantic/httpx), then makes a
   synchronous network round-trip — all on the critical path before Claude
   responds. The heavy import dominates cold-start.
2. **No timeouts.** `retain`/`recall` have no bounded timeout; a slow or
   unresponsive server can hang a prompt for the OS socket default (30–120s).
3. **Injection is disabled.** `inject-memories.py` was dropped from
   `hooks.json` on 2026-01-03. The plugin currently *stores* memories but never
   auto-*recalls* them — the bank is write-only in practice.
4. **`retain()` blocks on LLM extraction.** The Python `hindsight-client`
   `retain()` has no async flag, so it waits for server-side LLM extraction to
   finish. pi-ndsight avoids this with `{"async": true}` on the REST call.
5. **Container name is project-specific** (`hindsight-cc`), so pi-ndsight (which
   used `pindsight`) cannot share the same running container.

## Goals

- Make hooks fast: remove cold-start tax and all critical-path blocking.
- Re-add memory injection as a bounded, non-blocking recall.
- Share a single Hindsight container named `hindsight` between hindsight-cc and
  pi-ndsight.
- Add a `/hindsight-cc:setup` wizard for first-run configuration.

## Non-goals

- Rewriting `bank_utils.py` bank-ID logic (already correct and stdlib-only).
- Adding a docker-compose flow to hindsight-cc (keeps `docker run`).
- Changing the memory-bank prefix (`claude-code--`) — already aligned with
  pi-ndsight, which is what lets the two share memories.

## Decisions (locked with user)

| Question | Decision |
|----------|----------|
| Speed approach | **REST-direct, stdlib only.** Drop `hindsight-client`, the `.venv`, and the `install-dependencies.sh` SessionStart hook. |
| Memory injection | **Re-add** bounded low-budget recall on UserPromptSubmit (~2.5s hard timeout). |
| Setup wizard | **Slash command** `/hindsight-cc:setup` → writes a config file consumed by `ensure-hindsight.sh`. |
| Retain shape | **Keep both** retains (UserPromptSubmit + Stop), but make both async/non-blocking. |
| Container name | `hindsight` (shared with pi-ndsight). |
| Version | Bump to **2.0.0** (breaking infra changes). |
| `install-dependencies.sh` | Keep in-repo for dev/testing, but unwired from hooks. |

## Architecture

### 1. REST-direct API module (stdlib only)

New `scripts/hindsight_api.py` using only stdlib (`urllib.request`, `json`),
runnable under the system `python3` (no venv, no third-party imports). Mirrors the
endpoints the Python client wrapped:

- `retain(bank_id, content, *, context=None, async_=True, timeout=10.0)` →
  `POST /v1/default/banks/{bank}/memories` with body
  `{"items": [{"content", "context"}], "async": true}`.
- `recall(bank_id, query, *, budget="low", max_tokens=2048, timeout=2.5)` →
  `POST /v1/default/banks/{bank}/memories/recall` with body
  `{"query", "budget", "max_tokens"}`; returns the `results` list (each has
  `text`).
- `reflect(bank_id, query, *, budget="low", context=None, max_tokens=None,
  timeout=60.0)` → `POST /v1/default/banks/{bank}/reflect`; returns
  `answer`/`text`.
- `health(timeout=2.0)` → `GET /health`.

`BASE_URL` from `HINDSIGHT_BASE_URL` env, default `http://localhost:8888`. All
functions soft-fail (return empty/None, never raise out of the hook). Debug via
`HINDSIGHT_DEBUG`.

### 2. Hook scripts

`hooks/hooks.json`:

- **SessionStart**: only `ensure-hindsight.sh` (remove `install-dependencies.sh`).
- **UserPromptSubmit**: `python3 retain-prompt.py` then `python3 inject-memories.py`
  (re-add injection). Use system `python3`, not `.venv/bin/python3`.
- **Stop**: `python3 retain-transcript.py`.

Script behavior:

- `retain-prompt.py`: read prompt from stdin JSON, `retain(..., async_=True)` with a
  ~10s timeout. Returns immediately (server does extraction in background). Soft-fail.
- `inject-memories.py`: read prompt, `recall(..., budget="low", timeout=2.5)`. If
  results, print `<hindsight-memories>\n…\n</hindsight-memories>`; else print
  nothing. On timeout/error print nothing — prompt proceeds. This is the only
  remaining critical-path cost, and it is hard-bounded.
- `retain-transcript.py`: read transcript path from stdin JSON, build the
  last-exchange text, `retain(..., async_=True)`. Additionally launch the work
  **detached** (`subprocess` with `start_new_session=True`, or fork) so the Stop
  hook returns instantly regardless of server latency. Soft-fail.

All three import `hindsight_api` and `bank_utils` (both stdlib, fast).

### 3. Container management — shared `hindsight`

`scripts/ensure-hindsight.sh`:

- `CONTAINER_NAME="hindsight"`.
- **Legacy migration (runs before the health probe):** if a container named
  `hindsight-cc` exists AND no container named `hindsight` exists, `docker rm -f
  hindsight-cc` and proceed to create `hindsight`. Data persists in the
  `~/hindsight-data` volume, so nothing is lost — a brief one-time restart on first
  upgrade.
- **Health-probe-first reuse:** if `GET /health` answers, exit immediately and
  never touch the container. This is what makes sharing safe no matter which
  project (or which name) started the server.
- **Create/recreate only when not healthy.** The "missing API key → recreate" path
  is retained but, because the health probe already exited on a healthy server, it
  can never clobber a healthy shared container.
- **Config precedence at create time:** explicit `HINDSIGHT_API_LLM_*` env var >
  `~/.config/hindsight-cc/config.env` > built-in default. The config file is read
  only when creating the container.
- `docker run` flags unchanged otherwise: `--shm-size=2g`, `-p 8888:8888 -p
  9999:9999`, `-v ~/hindsight-data:/home/hindsight/.pg0`, image
  `ghcr.io/vectorize-io/hindsight:0.7.2` (overridable via `HINDSIGHT_IMAGE`).

First-to-create wins the LLM config; both projects share the `~/hindsight-data`
volume and the `claude-code--` bank prefix, so memories are shared.

### 4. `/hindsight-cc:setup` wizard

New `commands/setup.md` — a command that instructs Claude to:

1. Check Docker availability (warn, don't hard-fail, if absent).
2. Ask for provider (OpenAI, Anthropic, Gemini, Groq, Ollama, LM Studio).
3. Ask for model, showing a sensible default per provider.
4. Ask for base URL (local providers only).
5. Ask for API key (cloud providers only).
6. Write `~/.config/hindsight-cc/config.env` (mode 0600) as `KEY=value` lines:
   `HINDSIGHT_API_LLM_PROVIDER`, `HINDSIGHT_API_LLM_MODEL`,
   `HINDSIGHT_API_LLM_API_KEY`, `HINDSIGHT_API_LLM_BASE_URL`.
7. Tell the user to start a new session (or note the container will pick up config
   on next create).

`config.env` format is plain `KEY=value` so `ensure-hindsight.sh` can read it with
a small, careful parser (line-by-line, not blind `source`).

### 5. Slash commands and dev tooling

- `commands/memory-search.md`, `memory-status.md`, `reflect.md`: change
  invocation from `${CLAUDE_PLUGIN_ROOT}/scripts/.venv/bin/python3 …` to `python3
  ${CLAUDE_PLUGIN_ROOT}/scripts/…`.
- `search-memories.py`, `get-status.py`, `reflect.py`: rewrite to use
  `hindsight_api` instead of `hindsight_client`.
- `requirements.txt`: drop `hindsight-client`; keep `pytest`/`ruff` for dev only.
- `install-dependencies.sh`: keep in-repo (dev convenience) but remove from
  `hooks.json`.
- `inject-memories.py`: rewrite to use `hindsight_api.recall`.

### 6. Companion change in pi-ndsight

To complete container sharing:

- `src/pindsight/server.ts`: `CONTAINER = "hindsight"`.
- `docker-compose.yml`: `container_name: hindsight` (service name may stay).
- Align pi-ndsight's default data dir to `~/hindsight-data` (match hindsight-cc's
  volume) so both map the same Postgres data.

### 7. Docs & version

- `plugin.json`: `1.4.0` → `2.0.0`.
- Update `CLAUDE.md`, `README.md`, `CHANGELOG.md` to reflect: no venv, system
  `python3`, REST-direct, `/setup`, shared `hindsight` container, re-enabled
  injection.

## Data flow (per turn, after change)

```
UserPromptSubmit
  ├─ retain-prompt.py  → POST memories {async:true}  (~20ms, soft-fail)
  └─ inject-memories.py → POST recall {budget:low}   (≤2.5s hard cap; prints
                                                       <hindsight-memories> or nothing)
Stop
  └─ retain-transcript.py → detached POST memories {async:true} (returns instantly)
SessionStart
  └─ ensure-hindsight.sh → migrate legacy → health probe → (create if needed)
```

## Error handling

- Every network call is timeout-bounded and soft-fails (no exception escapes the
  hook). Recall failure → no injection. Retain failure → memory silently skipped.
- `ensure-hindsight.sh` soft-exits (status 0) when Docker is absent or the daemon
  is down, so it never blocks SessionStart.
- Config file absent → fall back to env vars / defaults.

## Testing

- `bank_utils` tests continue to run under system `python3` (stdlib only).
- New unit tests for `hindsight_api` request construction (URL, body shape,
  `async` flag, timeout wiring) using a stub HTTP server or by mocking
  `urllib.request.urlopen`.
- Manual: enable `HINDSIGHT_DEBUG=1`, confirm (a) UserPromptSubmit returns fast and
  injects memories when present, (b) bank count grows after a turn (verifies the
  detached retain actually completes — the most likely silent-failure mode), (c)
  legacy `hindsight-cc` container migrates to `hindsight` on first upgrade, (d)
  pi-ndsight attaches to the same running `hindsight` container.

## Risks

- **Detached retain silently dies.** A bare `&` is unreliable; the process must be
  truly detached (`start_new_session=True`). Verification (b) above is mandatory.
- **Migration downtime.** Removing `hindsight-cc` and creating `hindsight` is a
  brief restart; acceptable and one-time. Data is volume-backed.
- **System `python3` availability.** Hooks now rely on a system `python3` (3.x).
  Acceptable on macOS/Linux dev machines; document the requirement.
- **REST endpoint drift.** Endpoints are pinned to image `0.7.2`; mirror exactly
  what the Python client (and pi-ndsight) use.
