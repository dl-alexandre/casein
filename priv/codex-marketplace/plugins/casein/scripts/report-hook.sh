#!/usr/bin/env bash
set -u

receiver="${CASEIN_AGENT_MCP_HOME:-}/casein-codex-notify.sh"
if [[ -x "$receiver" ]]; then
  exec "$receiver"
fi

receiver="${CASEIN_SCRIPTS:-}/casein-codex-notify.sh"
if [[ -x "$receiver" ]]; then
  exec "$receiver"
fi

exit 0
