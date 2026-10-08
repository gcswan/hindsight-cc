# hindsight-cc

![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Docker Required](https://img.shields.io/badge/docker-required-blue.svg)

A Claude Code plugin that provides persistent memory across conversations using the [Hindsight](https://github.com/vectorize-io/hindsight) vector database.

## Installation

Install directly from the GitHub marketplace:

```bash
claude plugin add gcswan/hindsight-cc
```

The plugin runtime is stdlib-only: its hooks run under your system `python3`
(no virtualenv, no `pip install`). Nothing is installed on first run, so the
first session is not slowed down by a dependency install.

To verify installation:

```bash
claude plugin list
```

### First-Run Setup

Configure the LLM provider Hindsight uses for its memory operations by running
the setup wizard inside Claude Code:

```text
/hindsight-cc:setup
```

It asks for a provider, model, and (for cloud providers) an API key, then
writes `~/.config/hindsight-cc/config.env`. The `ensure-hindsight.sh`
container-startup script reads that file when it creates the Hindsight
container, with precedence: explicit environment variable >
`~/.config/hindsight-cc/config.env` > built-in default. Local providers
(Ollama, LM Studio) need a base URL instead of an API key.

#### First-run onboarding note

On a brand-new machine, the very first Claude Code session may start *before*
you have run `/hindsight-cc:setup` — so there is no API key configured yet and
memory will not be active for that session. This is expected. Run
`/hindsight-cc:setup` and then start a new session; the Hindsight container is
created with your chosen provider and memory features come online.

You can also set the provider via environment variables (instead of, or in
addition to, the wizard) before starting Claude Code — see the examples under
[Requirements](#requirements) below.

## Features

- **Automatic Memory Injection**: Relevant context from past conversations is automatically injected into your prompts
- **Prompt Retention**: User prompts are stored for future semantic search
- **Transcript Retention**: Complete conversation segments are stored at session end
- **Per-Project Isolation**: Each project has its own memory bank
- **Automatic Server Management**: Hindsight Docker container starts automatically when you begin a session

## Requirements

- Docker installed and running
- A system `python3` on `PATH` (Python 3.10+; the repo pins 3.13 for dev). The
  hooks call it directly — no virtualenv is created or used at runtime.

The examples below show provider configuration via environment variables. The
same values can be supplied through `~/.config/hindsight-cc/config.env` via
`/hindsight-cc:setup`; the precedence is explicit env var > `config.env` >
built-in default. Cloud providers need an API key; local providers (Ollama, LM
Studio) need a base URL and no key.

```bash
# Groq (recommended for fast inference)
export HINDSIGHT_API_LLM_PROVIDER=groq
export HINDSIGHT_API_LLM_API_KEY=gsk_xxxxxxxxxxxx
export HINDSIGHT_API_LLM_MODEL=openai/gpt-oss-20b
# For free tier users: override to on_demand if you get service_tier errors
# export HINDSIGHT_API_LLM_GROQ_SERVICE_TIER=on_demand

# OpenAI
export HINDSIGHT_API_LLM_PROVIDER=openai
export HINDSIGHT_API_LLM_API_KEY=sk-xxxxxxxxxxxx
export HINDSIGHT_API_LLM_MODEL=gpt-4o

# Gemini
export HINDSIGHT_API_LLM_PROVIDER=gemini
export HINDSIGHT_API_LLM_API_KEY=xxxxxxxxxxxx
export HINDSIGHT_API_LLM_MODEL=gemini-2.0-flash

# Anthropic
export HINDSIGHT_API_LLM_PROVIDER=anthropic
export HINDSIGHT_API_LLM_API_KEY=sk-ant-xxxxxxxxxxxx
export HINDSIGHT_API_LLM_MODEL=claude-sonnet-4-20250514

# Ollama (local, no API key)
export HINDSIGHT_API_LLM_PROVIDER=ollama
export HINDSIGHT_API_LLM_BASE_URL=http://localhost:11434/v1
export HINDSIGHT_API_LLM_MODEL=llama3

# LM Studio (local, no API key)
export HINDSIGHT_API_LLM_PROVIDER=lmstudio
export HINDSIGHT_API_LLM_BASE_URL=http://localhost:1234/v1
export HINDSIGHT_API_LLM_MODEL=your-local-model

# OpenAI-compatible endpoint
export HINDSIGHT_API_LLM_PROVIDER=openai
export HINDSIGHT_API_LLM_BASE_URL=https://your-endpoint.com/v1
export HINDSIGHT_API_LLM_API_KEY=your-api-key
export HINDSIGHT_API_LLM_MODEL=your-model-name
```

## Usage

Once installed, the plugin works automatically:

1. **On session start**: The Hindsight server is started if not already running (an already-running server is reused)
2. **On each prompt**: Your prompt is stored, and relevant memories are injected
3. **On session end**: The conversation transcript is stored

Prompt and transcript retention are fire-and-forget (non-blocking). Memory
injection runs a recall that is hard-bounded at ~2.5s and soft-fails to no
injection, so a slow or unavailable server never holds up your prompt.

### Slash Commands

- `/hindsight-cc:setup` - First-run wizard to configure the LLM provider and write `config.env`
- `/hindsight-cc:memory-search <query>` - Search your project's memory bank
- `/hindsight-cc:memory-status` - Check server status and bank info
- `/hindsight-cc:reflect` - AI-assisted decision support over past context

## How It Works

### Memory Bank System

Each project gets its own isolated memory bank based on git repository identity (when available) or project path. **The plugin auto-detects the project directory from git root or current working directory - no environment variables needed.**

**Git-based (preferred)**: Extracts owner/repo from git remote origin

- Any clone of `gcswan/hindsight-cc` → `claude-code--gcswan-hindsight-cc`
- Same memories across all paths: `/home/user/hindsight-cc`, `/mnt/work/hindsight-cc`, etc.

**Path-based (fallback)**: Uses last 2 path components when not in a git repo

- `/home/user/code/myapp` → `claude-code--code-myapp`
- `/projects/demo` → `claude-code--projects-demo`

This ensures working on the same repository from different paths shares the same memory bank.

### Hook Flow

1. **SessionStart**: Starts the shared Hindsight server if not running (reuses it if it is)
2. **UserPromptSubmit**:
   - Stores the prompt for future search (fire-and-forget)
   - Queries for relevant memories and injects them (recall bounded at ~2.5s)
3. **Stop**: Stores the conversation transcript (fire-and-forget)

### Memory Format

Memories are injected as:

```xml
<hindsight-memories>
memory text 1
memory text 2
</hindsight-memories>
```

## Configuration

### Environment Variables

Each of the `HINDSIGHT_API_LLM_*` values can be set either as an environment
variable or via `~/.config/hindsight-cc/config.env` (written by
`/hindsight-cc:setup`), with precedence env var > `config.env` > default.

| Variable                    | Description                                  | Default                                 |
| --------------------------- | -------------------------------------------- | --------------------------------------- |
| `HINDSIGHT_API_LLM_API_KEY` | API key for Hindsight LLM operations         | required for cloud providers; omit for local (Ollama, LM Studio) |
| `HINDSIGHT_API_LLM_MODEL`   | LLM model for Hindsight                      | `gpt-5-nano`                            |
| `HINDSIGHT_API_LLM_BASE_URL`| LLM base URL (local providers / custom endpoints) | (unset)                            |
| `HINDSIGHT_DEBUG`           | Enable debug logging (`1`, `true`, or `yes`) | (disabled)                              |
| `HINDSIGHT_IMAGE`           | Docker image for Hindsight server            | `ghcr.io/vectorize-io/hindsight:0.8.6` |
| `HINDSIGHT_PLATFORM`        | Docker platform for the container: `linux/arm64` or `linux/amd64` | the Docker daemon's architecture |
| `HINDSIGHT_MEMORY_LIMIT`    | Container memory limit (`4g`, `4096m`, ...) or `none` | `4g`                                    |
| `HINDSIGHT_DATA_DIR`        | Host directory for the embedded Postgres data | `~/hindsight-data`                      |
| `HINDSIGHT_RECREATE_WAIT_SECONDS` | Seconds `recreate` waits for the new server to answer (recreate only) | `180`             |

The platform, memory limit and data directory settings are read when the
container is created or recreated.

### Data Storage

Memory data is stored in `~/hindsight-data/`. The server runs in a single
shared Docker container named `hindsight`, shared with the sibling pi-ndsight
project (same data volume and `claude-code--` bank prefix, so memories are
shared between them). On first run after upgrading, `ensure-hindsight.sh`
performs a one-time migration off the old `hindsight-cc` container name.

### Data Handling & Privacy

- Prompts and transcript segments are stored locally in the Hindsight data directory.
- Hindsight may send stored content to its configured LLM provider for embeddings and recall; avoid retaining sensitive or regulated data if you do not want it transmitted.

### Server Ports

- API: <http://localhost:8888>
- UI: <http://localhost:9999>

## Troubleshooting

### Debug Logging

Enable debug logging to see detailed output from plugin operations:

```bash
export HINDSIGHT_DEBUG=1
```

Debug messages are prefixed with the script name and written to stderr:

```text
[hindsight-cc:retain-prompt] Detected project directory: /home/user/code/hindsight-cc
[hindsight-cc:retain-prompt] Bank ID: claude-code--gcswan-hindsight-cc
[hindsight-cc:inject-memories] Found 3 memories
```

For combined Claude Code and plugin debugging:

```bash
export HINDSIGHT_DEBUG=1
claude --debug "hooks"
```

This shows hook execution, plugin debug messages, and success/failure status.

### Server Issues

Check server health:

```bash
curl http://localhost:8888/health
```

View container status:

```bash
docker ps -f name=hindsight
```

Check container logs:

```bash
docker logs hindsight
```

Restart the server:

```bash
docker restart hindsight
```

### Architecture and Emulation

`/hindsight-cc:memory-status` shows the container's image architecture next to
the Docker daemon's. An `EMULATED:` line means the container runs under
emulation (for example an amd64 image on an Apple Silicon Mac), which is slower
and uses more memory. The plugin always passes `--platform` explicitly when it
creates the container, so this only happens to containers created some other way
or forced with `HINDSIGHT_PLATFORM`.

To replace the container with one built from the current settings:

```bash
sh <plugin-dir>/scripts/ensure-hindsight.sh recreate
```

`<plugin-dir>` is where Claude Code installed the plugin (or a clone of this
repository); run this from your own terminal.

It needs the LLM API key (or, for a local provider, the base URL) in the
environment or in `config.env` (pass the key from
your secret manager for that one command; never write it into a file in this
repo). It stops the server cleanly, keeps the old container stopped as
`hindsight-prev`, creates and verifies the new one, and rolls back automatically
on failure or if it is interrupted (Ctrl-C, TERM, HUP). Remove `hindsight-prev`
with `docker rm hindsight-prev` once you are satisfied. If it was killed hard
(for example SIGKILL) and `hindsight-prev` is still there, restore by hand, in
this order:

1. `docker rm -f hindsight` (only if a new one exists).
2. Only if the new container's architecture differs from `hindsight-prev`'s
   (compare `docker image inspect -f '{{.Architecture}}'` of each container's
   image): move the binaries back: `installation` to `installation.<new arch>`,
   then `installation.<old arch>` to `installation`. An `installation.<arch>`
   directory alone does not mean this run swapped anything.
3. `docker rename hindsight-prev hindsight`
4. `docker update --restart=unless-stopped hindsight`
5. `docker start hindsight`

If the container exits with code 132 (illegal instruction) or Docker keeps restarting it
after crashes, the session start reports it instead of retrying forever; check
`docker logs hindsight`. If Docker killed it for running out of memory, raise the
limit: `HINDSIGHT_MEMORY_LIMIT=6g sh <plugin-dir>/scripts/ensure-hindsight.sh recreate`
(or `none`). On an Apple Silicon (arm64) host, a fallback for exit 132 is the
amd64 image under emulation, which uses more memory:
`HINDSIGHT_PLATFORM=linux/amd64 sh <plugin-dir>/scripts/ensure-hindsight.sh recreate`.
Please report the Docker Desktop version and `docker logs hindsight` output.

## Testing

The plugin runtime needs no third-party packages, but tests/lint/typecheck use
a dev-only virtualenv. Create it once with `./scripts/install-dependencies.sh`,
then run checks from the repo root using that venv (this venv is for
development only and is never used by the hooks at runtime):

```bash
./scripts/.venv/bin/pytest scripts/test
./scripts/.venv/bin/ruff check scripts/test/test_bank_utils.py
./scripts/.venv/bin/pyright scripts/test/test_bank_utils.py
```

## License

MIT
