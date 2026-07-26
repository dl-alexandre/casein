#!/usr/bin/env bash
# sidechat.sh — helpers for read-only agent sidechat launches.
#
# Sourced by scripts/launch-casein-agent.sh. Not meant to be executed directly.

# Resolve --sidechat target to session + pane identifiers for the advisor prompt.
#   %2              — pane in CASEIN_TMUX_SESSION
#   session:pane    — explicit tmux session and pane id
#   agent           — advisor discovers the agent pane via terminal_agent_pane
sidechat_resolve_target() {
  local target="${1:-}"
  SIDECHAT_SESSION=""
  SIDECHAT_PANE=""
  SIDECHAT_TARGET_MODE=""

  case "$target" in
    agent)
      SIDECHAT_TARGET_MODE="agent"
      SIDECHAT_SESSION="${CASEIN_TMUX_SESSION:-}"
      ;;
    *:*)
      SIDECHAT_SESSION="${target%%:*}"
      SIDECHAT_PANE="${target#*:}"
      SIDECHAT_TARGET_MODE="explicit"
      ;;
    %*)
      SIDECHAT_SESSION="${CASEIN_TMUX_SESSION:-}"
      SIDECHAT_PANE="$target"
      SIDECHAT_TARGET_MODE="pane"
      ;;
    "")
      echo "error: --sidechat requires a target (pane id like %2, session:pane, or agent)" >&2
      return 1
      ;;
    *)
      echo "error: invalid --sidechat target: ${target} (use %2, session:pane, or agent)" >&2
      return 1
      ;;
  esac
}

# Write the advisor system prompt append file for this launch.
sidechat_write_prompt() {
  local out="$1"
  local runtime="${2:-agent}"
  local workspace_id="${CASEIN_WORKSPACE_ID:-}"
  local session="${SIDECHAT_SESSION:-}"
  local pane="${SIDECHAT_PANE:-}"
  local mode="${SIDECHAT_TARGET_MODE:-pane}"

  mkdir -p "$(dirname "$out")"

  cat >"$out" <<EOF
You are a read-only ${runtime} advisor for another agent in this Casein workspace.

Your job is to observe that agent's live CLI transcript and help the operator or
other agents understand what it is doing, what it is blocked on, and what it
answered — without mutating the workspace yourself.

## Capability limits
You must not edit files, write files, or run shell commands. The launcher has
disabled write and shell tools. Use terminal MCP read tools only.

## Observed agent target
- workspace_id: ${workspace_id}
- session: ${session:-<call terminal_list_sessions or terminal_topology>}
- pane: ${pane:-<call terminal_agent_pane when mode is agent>}
- target mode: ${mode}

When pane is unknown, call terminal_agent_pane first and use the returned pane
id for every subsequent transcript pull.

## Transcript workflow (source of truth)
1. Call terminal_agent_transcript with workspace_id, session, and pane.
2. Before each answer about the observed agent, re-pull with since set to the
   prior cursor so your view stays current.
3. Prefer terminal_agent_transcript over terminal_capture_agent — scrollback is
   lossy; the JSONL transcript is authoritative.

## Answering
Summarize the observed agent's current task, recent tool use, blockers, and
final replies from transcript entries. Do not guess from tmux scrollback.
EOF

  chmod 600 "$out"
}
