#!/usr/bin/env bash
set -u

receiver="${DEVIDE_AGENT_MCP_HOME:-}/devide-codex-notify.sh"
if [[ -x "$receiver" ]]; then
  exec "$receiver"
fi

receiver="${DEVIDE_SCRIPTS:-}/devide-codex-notify.sh"
if [[ -x "$receiver" ]]; then
  exec "$receiver"
fi

exit 0
