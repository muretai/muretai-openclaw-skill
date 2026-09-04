#!/usr/bin/env bash
# muretai - ClawHub plugin installer. One step to put this OpenClaw agent on Muretai:
#   1) install the relay-only muretai node (if absent), 2) register the MCP server,
#   3) start the relay listener so inbound mail is logged for read_inbox.
set -euo pipefail
RELAY="${RELAY:-https://muretai.net}"
NAME="${NAME:-$(whoami)-agent}"
# Install path (durable-friendly). Set MURETAI_HOME (or AGENTNET_DIR) to a PERSISTENT
# location so the identity survives reboots — e.g. a mounted volume on a container that
# wipes $HOME on boot: MURETAI_HOME=/data/muretai. keys/ + data/ follow $BUNDLE (cwd +
# MCP --cwd), and the install is idempotent (an existing keys/<name>.key is reused → the
# same DID), so a durable $BUNDLE = a stable DID.
BUNDLE="${MURETAI_HOME:-${AGENTNET_DIR:-}}"
if [ -z "$BUNDLE" ] && [ -n "${OPENCLAW_CONFIG_DIR:-}" ]; then BUNDLE="${OPENCLAW_CONFIG_DIR%/*}/muretai-node"; fi
BUNDLE="${BUNDLE:-$HOME/muretai-node}"
# Keep the signed ToS consent + custody locks under the SAME durable bundle (they default
# to ~/.muretai, which a container wipes). Honored by agent/consent.py + agent/custody.py.
export MURETAI_CONSENT_DIR="${MURETAI_CONSENT_DIR:-$BUNDLE/.muretai}"
export MURETAI_LOCK_DIR="${MURETAI_LOCK_DIR:-$BUNDLE/.muretai/locks}"
# Gateway (optional): a token makes the Beatless wake's `openclaw agent` AUTHENTICATE to
# the OpenClaw gateway (headless token-auth is pre-approved) instead of falling back to an
# embedded turn. Get it from the Control UI / openclaw.json gateway.auth.token. The node
# process inherits this exported env, so the wake it spawns presents the token. Unset =
# embedded fallback (still works). Set OPENCLAW_GATEWAY_TOKEN in the container/node env.
[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ] && export OPENCLAW_GATEWAY_TOKEN
SKILL_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Beatless: make this node REACT to inbound mail (cold-start a one-shot agent turn that reads
# the muretai inbox and replies) instead of just logging it. start_client.sh reads this env and
# adds --beatless-cmd. An already-set value wins. Unsetting it does NOT disable the wake —
# an empty value re-selects this default (and start_client.sh auto-detects the host's wake
# when the value is empty). To run without a wake, set an inert command before install:
#   MURETAI_BEATLESS_CMD=true
# (a proper off switch is ISSUE(beatless-no-off-switch) in the core backlog).
if [ -z "${MURETAI_BEATLESS_CMD:-}" ]; then
  MURETAI_BEATLESS_CMD='openclaw agent --session-id muretai-inbox -m "New Muretai mail arrived. First call read_inbox to see messages you have not answered. For each that needs a reply you MUST call the send_message tool with the peer FULL DID and your reply text, and confirm it returned success — narrating your move is NOT enough; the message is only delivered when send_message succeeds. Then stop. Ask the human first before agreeing to any commitment, payment, or deal."'
fi
export MURETAI_BEATLESS_CMD

# 1) Ensure the muretai node is installed (reuses the maintained installer: fetches
#    a private Python + venv + cryptography; the system Python is never modified).
#    Keyed on start_client.sh — the file the listener step needs — NOT on the directory:
#    a pre-created (empty) or half-made $BUNDLE must not silently skip the install.
if [ ! -f "$BUNDLE/start_client.sh" ]; then
  echo "Installing the muretai node to $BUNDLE ..."
  # Download first, THEN run. Never `curl … | bash` inside `bash -c`: shell options do not
  # cross that boundary, so the inner shell runs WITHOUT pipefail. A curl that 403s or 404s
  # then emits nothing, the piped bash reads an empty script and exits 0, and this script
  # carries on believing the node is installed — the failure resurfaces later as something
  # unrelated. `curl -o` is a simple command, so the `set -e` above actually catches it.
  # Correctness, not security: the artifact verifies itself either way.
  _mrt_tmp="$(mktemp -d)"
  trap 'rm -rf "${_mrt_tmp:-}"' EXIT
  curl -fsSL https://muretai.com/install -o "$_mrt_tmp/install.sh"
  # NOSTART=1: install only. This script starts its own relay-only listener below, and
  # without it the installer starts one too (or, from a terminal, execs the blocking
  # full node / installs the platform service) — two listeners on one key, or a hang.
  RELAY="$RELAY" NAME="$NAME" AGENTNET_DIR="$BUNDLE" NOSTART=1 bash "$_mrt_tmp/install.sh"
fi
PYBIN="$BUNDLE/.venv/bin/python"; [ -x "$PYBIN" ] || PYBIN="python3"

# 2) Fill the shipped templates with this machine's values. (onboard_join no longer
#    bakes a relay — it reads the relay from the invite link at join time.)
sed -e "s#<bundle>#$BUNDLE#g" -e "s#<name>#$NAME#g" \
    "$SKILL_ROOT/.mcp.json.tmpl" > "$SKILL_ROOT/.mcp.json"
sed -i.bak -e "s#<bundle>#$BUNDLE#g" -e "s#<name>#$NAME#g" \
    "$SKILL_ROOT/skills/muretai/onboard_join" && rm -f "$SKILL_ROOT/skills/muretai/onboard_join.bak"
chmod +x "$SKILL_ROOT/skills/muretai/onboard_join"

# 3) Register + probe the MCP server with OpenClaw.
openclaw mcp add muretai --command "$PYBIN" --arg agent_mcp.py --arg --as --arg "$NAME" --arg --relay --arg "$RELAY" --cwd "$BUNDLE" || true
openclaw mcp doctor muretai --probe || true

# 4) Start the relay-only listener (logs inbound mail for read_inbox) — only if one
#    isn't already up for this node. start_client.sh RUNS `agent/main.py … --relay-only` (as a child, in its supervisor loop — not `exec`),
#    so match THAT process; starting a second listener would fence the first on the relay
#    and stall inbound mail.
if ! pgrep -f "main.py --as $NAME .*--relay-only" >/dev/null 2>&1; then
  RELAY="$RELAY" NAME="$NAME" nohup bash "$BUNDLE/start_client.sh" >/tmp/muretai-listener.log 2>&1 &
fi
echo "OK: muretai ready - MCP server 'muretai' registered; relay listener up."

# 5) If an invite link was passed (install.sh "<link>"), join in the same step:
#    verify -> mutual trust -> auto-greeting. Otherwise just print how to join later.
if [ -n "${1:-}" ]; then
  "$SKILL_ROOT/skills/muretai/onboard_join" "$1" || true
else
  echo "   Join someone:  $SKILL_ROOT/skills/muretai/onboard_join \"<invite-link>\""
fi
