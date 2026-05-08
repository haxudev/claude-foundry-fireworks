#!/usr/bin/env bash
# claude-foundry: run Claude Code CLI against FW-GLM-5 on Azure AI Foundry
# via a local LiteLLM proxy. Inspired by sjalq/claude-fireworks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---- Load .env ---------------------------------------------------------------
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${AZURE_FOUNDRY_API_KEY:?AZURE_FOUNDRY_API_KEY not set (put it in .env)}"
: "${AZURE_FOUNDRY_ENDPOINT:=https://your-resource.services.ai.azure.com/openai/v1}"
export AZURE_FOUNDRY_API_KEY AZURE_FOUNDRY_ENDPOINT

PORT="${LITELLM_PORT:-4111}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-foundry-local-$(date +%s)}"
export LITELLM_MASTER_KEY

PYTHON_BIN="${PYTHON_BIN:-/home/haxu/miniconda3/bin/python3}"
LITELLM_BIN="${LITELLM_BIN:-/home/haxu/miniconda3/bin/litellm}"

LOG_FILE="$SCRIPT_DIR/litellm.log"
PID_FILE="$SCRIPT_DIR/litellm.pid"

# ---- Helpers ----------------------------------------------------------------
log()  { printf '\033[36m[claude-foundry]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[claude-foundry]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[claude-foundry]\033[0m %s\n' "$*" >&2; }

is_proxy_up() {
  curl -fsS "http://127.0.0.1:${PORT}/health/liveliness" >/dev/null 2>&1
}

get_proxy_pid() {
  python3 - "$PORT" <<'PY'
import re, subprocess, sys
port = sys.argv[1]
try:
    out = subprocess.check_output([
        'bash', '-lc', f'ss -ltnp "( sport = :{port} )"'
    ], text=True, stderr=subprocess.DEVNULL)
except Exception:
    raise SystemExit(0)
m = re.search(r'pid=(\d+)', out)
if m:
    print(m.group(1))
PY
}

stop_proxy() {
  local pid=""
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  fi

  if [[ -z "${pid:-}" ]]; then
    pid="$(get_proxy_pid || true)"
  fi

  if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
    log "Stopping LiteLLM proxy (pid $pid)"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi

  for _ in $(seq 1 10); do
    if ! is_proxy_up; then
      break
    fi
    sleep 1
  done

  rm -f "$PID_FILE"
}

start_proxy() {
  local foreground="${1:-0}"
  if is_proxy_up; then
    local existing_pid=""
    existing_pid="$(get_proxy_pid || true)"
    if [[ -n "${existing_pid:-}" ]]; then
      log "LiteLLM proxy already running on :$PORT (pid $existing_pid)"
      echo "$existing_pid" >"$PID_FILE"
      return 0
    fi
  fi

  if [[ ! -x "$LITELLM_BIN" ]] && ! command -v litellm >/dev/null 2>&1; then
    err "litellm CLI not found. Install with: $PYTHON_BIN -m pip install 'litellm[proxy]'"
    exit 1
  fi
  [[ -x "$LITELLM_BIN" ]] || LITELLM_BIN="$(command -v litellm)"

  if [[ "$foreground" == "1" ]]; then
    log "Starting LiteLLM proxy in foreground on :$PORT"
    exec "$LITELLM_BIN" \
        --config "$SCRIPT_DIR/config.yaml" \
        --host 127.0.0.1 \
        --port "$PORT"
  fi

  log "Starting LiteLLM proxy on :$PORT (log: $LOG_FILE)"
  : >"$LOG_FILE"
  nohup "$LITELLM_BIN" \
      --config "$SCRIPT_DIR/config.yaml" \
      --host 127.0.0.1 \
      --port "$PORT" \
      >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"

  for i in $(seq 1 40); do
    if is_proxy_up; then
      log "Proxy is up after ${i}s"
      return 0
    fi
    sleep 1
  done
  err "Proxy failed to start. Last log lines:"
  tail -n 40 "$LOG_FILE" >&2 || true
  exit 1
}

# ---- Subcommands ------------------------------------------------------------
run_claude() {
  start_proxy

  export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
  export ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY"
  unset ANTHROPIC_API_KEY
  export ANTHROPIC_MODEL="claude-sonnet-4-5"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-4-5"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="claude-haiku-4-5"
  export ANTHROPIC_SMALL_FAST_MODEL="claude-haiku-4-5"
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"

  log "Launching Claude Code via Anthropic-compatible proxy -> FW-GLM-5 @ Azure Foundry"
  exec claude "$@"
}

case "${1:-run}" in
  start)
    start_proxy
    ;;
  serve)
    start_proxy 1
    ;;
  stop)
    stop_proxy
    log "Stopped."
    ;;
  status)
    if is_proxy_up; then
      log "Proxy UP on http://127.0.0.1:$PORT"
    else
      warn "Proxy DOWN"
    fi
    ;;
  logs)
    tail -n 200 -f "$LOG_FILE"
    ;;
  test)
    start_proxy
    log "Sending test completion to FW-GLM-5..."
    curl -sS "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
      -H 'Content-Type: application/json' \
      -d '{"model":"FW-GLM-5","messages":[{"role":"user","content":"Say hi in 3 words."}]}' \
      | sed 's/^/  /'
    echo
    ;;
  run|"")
    shift || true
    run_claude "$@"
    ;;
  *)
    run_claude "$@"
    ;;
esac
