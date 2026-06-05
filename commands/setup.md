---
description: "First-run setup wizard: configure the Hindsight LLM provider and write the config file"
allowed-tools: Bash, AskUserQuestion, Write
---

# Hindsight Setup Skill

## When to Use This Skill

Run this once on first use of the plugin (or any time you want to change the
LLM provider Hindsight uses for its memory operations). It walks you through
choosing a provider and model, then writes a config file that the
container-startup script reads when the Hindsight server is next created.

## How to Execute

Perform the following steps IN ORDER. This is an interactive wizard, so ask
each question and wait for the answer before moving on.

## Steps

### 1. Check Docker availability

Run a quick check that Docker exists and the daemon is reachable:

```bash
command -v docker && docker info >/dev/null 2>&1 && echo "docker: ok" || echo "docker: unavailable"
```

If Docker is missing or the daemon is down, clearly WARN the user that the
plugin needs Docker to run the Hindsight server, and that they should install
or start Docker before they expect memory features to work. Do NOT hard-fail:
continue the wizard so the config is still written and ready for later.

### 2. Ask for the LLM provider

Use `AskUserQuestion` to ask which provider Hindsight should use. Offer these
options:

- OpenAI (cloud)
- Anthropic (cloud)
- Gemini (cloud)
- Groq (cloud)
- Ollama (LOCAL)
- LM Studio (LOCAL)

Note that Ollama and LM Studio run a model locally on the user's machine; the
other four are cloud providers that need an API key.

### 3. Ask for the model

Ask which model to use, presenting a sensible default for the chosen provider.
Make clear these are suggestions the user can override with any model their
provider supports:

- OpenAI → `gpt-5-nano`
- Anthropic → `claude-haiku-4-5`
- Gemini → `gemini-2.0-flash`
- Groq → `llama-3.3-70b-versatile`
- Ollama → `llama3.1`
- LM Studio → no fixed default; ask which model the user currently has loaded

### 4. Ask for the base URL — LOCAL providers only

Only for Ollama and LM Studio, ask for the LLM base URL with these suggested
defaults:

- Ollama → `http://localhost:11434/v1`
- LM Studio → `http://localhost:1234/v1`

Skip this question entirely for cloud providers (OpenAI, Anthropic, Gemini,
Groq).

### 5. Ask for the API key — CLOUD providers only

Only for OpenAI, Anthropic, Gemini, and Groq, ask for the provider API key.
Treat this value as sensitive: do NOT echo it back in plaintext in any
summary or confirmation. Skip this question entirely for local providers
(Ollama, LM Studio).

### 6. Write the config file

Write `~/.config/hindsight-cc/config.env`. Do this carefully so a secret is
never exposed in shell history or a process listing any more than necessary:

1. First create the directory with Bash:

   ```bash
   mkdir -p ~/.config/hindsight-cc
   ```

2. Write the file contents with the `Write` tool (NOT with `echo`, `cat`, or a
   heredoc that would put the API key inline on a command line). Resolve the
   path to an absolute path first (e.g. `$HOME/.config/hindsight-cc/config.env`).

   The format is plain `KEY=value`, one per line, no surrounding quotes. Write
   ONLY the keys that apply to the chosen provider:

   - Always: `HINDSIGHT_API_LLM_PROVIDER` and `HINDSIGHT_API_LLM_MODEL`
   - `HINDSIGHT_API_LLM_API_KEY` only for cloud providers
   - `HINDSIGHT_API_LLM_BASE_URL` only for local providers

   Omit any inapplicable key entirely — the parser treats an absent key as
   unset and falls back to the built-in default or leaves it empty.

   Example for a cloud provider (OpenAI):

   ```
   HINDSIGHT_API_LLM_PROVIDER=openai
   HINDSIGHT_API_LLM_MODEL=gpt-5-nano
   HINDSIGHT_API_LLM_API_KEY=sk-...
   ```

   Example for a local provider (Ollama):

   ```
   HINDSIGHT_API_LLM_PROVIDER=ollama
   HINDSIGHT_API_LLM_MODEL=llama3.1
   HINDSIGHT_API_LLM_BASE_URL=http://localhost:11434/v1
   ```

3. Tighten permissions and confirm the file was written, with Bash:

   ```bash
   chmod 600 ~/.config/hindsight-cc/config.env && ls -l ~/.config/hindsight-cc/config.env
   ```

   Show the `ls -l` output to confirm the file exists with `0600` permissions.
   Do NOT print the file's contents (it may contain an API key).

## After

Tell the user what happens next:

- The config is read when the Hindsight container is next CREATED, not on every
  startup.
- If a container already exists, they may need to remove it and let the plugin
  recreate it: `docker rm -f hindsight` — or simply start a fresh Claude Code
  session. On the next create, `ensure-hindsight.sh` picks up the new config.
- The very first session before setup may have had no memory configured. That
  is expected; rerun this command after setup and start a new session so the
  container is created with the chosen provider.
