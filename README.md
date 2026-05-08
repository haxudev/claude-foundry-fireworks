# claude-foundry-fireworks

Run the **Claude Code** CLI against the **FW-GLM-5** (Fireworks GLM-5) model
hosted on **Microsoft Azure AI Foundry**, via a local **LiteLLM** proxy.

Inspired by [sjalq/claude-fireworks](https://github.com/sjalq/claude-fireworks).

## How it works

```
  claude (CLI)
      │  Anthropic-format requests, ANTHROPIC_BASE_URL=http://127.0.0.1:4111
      │  using LiteLLM's unified /v1/messages route
      ▼
  LiteLLM proxy (config.yaml + param_filter.py)
      │  Anthropic-facing at /v1/messages
      │  backend mapped with custom_openai/FW-GLM-5
      ▼
  https://your-resource.services.ai.azure.com/openai/v1
      │
      ▼
  FW-GLM-5  (accounts/fireworks/models/glm-5)
```

`param_filter.py` strips Anthropic-only fields (`context_management`,
`reasoning_effort`, `thinking`, `cache_control`, `betas`, `anthropic-beta`)
that Foundry's OpenAI-compatible endpoint rejects.

## Setup

```bash
# 1. Install LiteLLM (once)
/home/haxu/miniconda3/bin/pip install 'litellm[proxy]'

# 2. Create local credentials file
cp .env.example .env
$EDITOR .env

# 3. Smoke test
./claude-foundry.sh test

# 4. Launch Claude Code
./claude-foundry.sh
```

## Subcommands

| Cmd      | Action                                          |
|----------|-------------------------------------------------|
| `run`    | (default) start proxy if needed and exec claude |
| `start`  | start proxy in background                       |
| `stop`   | stop proxy                                      |
| `status` | show proxy liveness                             |
| `logs`   | tail proxy logs                                 |
| `test`   | start proxy and send a one-shot completion      |

## Notes

- All Claude model aliases (sonnet-4-5, opus-4-7, haiku-4-5, etc.) are routed
  to `FW-GLM-5` in `config.yaml` — Claude Code's internal small/fast model
  selections all hit the same backend.
- Claude Code should talk to the proxy root with
  `ANTHROPIC_BASE_URL=http://127.0.0.1:4111`.
  The working Anthropic-facing endpoint is LiteLLM's unified `POST /v1/messages` route.
- Do **not** use LiteLLM's `/anthropic/v1/messages` passthrough route for Azure Foundry;
  that forwards directly upstream and returns 404.
- Azure Foundry itself is still reached through its OpenAI-compatible backend endpoint
  `…/openai/v1`, but that is an internal proxy/backend detail rather than the Claude-facing API.
- Runtime files and secrets are intentionally excluded from git; copy `.env.example` to `.env`
  before running locally.

## Verified root cause and fix

The `400 ... messages[*].thinking_blocks` failure was caused by two issues:

1. Claude Code sends Anthropic `/v1/messages` history where assistant turns can contain
   `content` blocks of type `thinking`. LiteLLM's Anthropic adapter later materializes those
   into `thinking_blocks` before forwarding to the `custom_openai/FW-GLM-5` backend.
2. The original `param_filter.py` hook only sanitized wrapper kwargs, not the live `messages`
   list passed through LiteLLM's Anthropic `/v1/messages` handler. That meant real Claude Code
   history still reached the backend with incompatible thinking state.

The fix is implemented in `param_filter.py` by mutating the `messages` list in
`async_pre_request_hook()` and stripping:

- assistant `content` items with `type: "thinking"`
- `redacted_thinking`
- top-level `thinking`
- already-materialized `thinking_blocks`

## Verified run procedure

Use a clean proxy restart before launching Claude Code:

```bash
./claude-foundry.sh stop
./claude-foundry.sh start
./claude-foundry.sh status
./claude-foundry.sh
```

`claude-foundry.sh` now detects and stops the actual LiteLLM listener on port `4111`, even if a
stale `litellm.pid` file is missing. This avoids silently reusing an older proxy process.

After the above restart sequence, the following previously failing Claude-style history shape has
been verified to return `200` through `POST /v1/messages`:

- user: `hi`
- assistant: `content: [{"type":"thinking", ...}, {"type":"text", ...}]`
- user: `本项目如何使用？有哪些命令？`

## Current limitation

This bridge fix prevents the `thinking_blocks` crash, but it does **not** preserve Anthropic-native
structured thinking end-to-end. Azure Foundry Fireworks GLM-5 still responds through its own
OpenAI-compatible backend shape, so the bridge keeps compatibility by stripping incompatible
Anthropic thinking history before provider validation.
