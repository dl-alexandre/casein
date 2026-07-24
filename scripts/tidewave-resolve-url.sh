#!/usr/bin/env bash
#
# tidewave-resolve-url.sh — resolve Tidewave MCP URL using the Elixir resolver.
#
# Reads DEVIDE_TIDEWAVE_MCP_URL / DEVIDE_PREVIEW_ENV_ID from the environment and
# optional workspace name/id args. Prints the URL or exits 1 when unavailable.
#
# Usage:
#   bash scripts/tidewave-resolve-url.sh
#   bash scripts/tidewave-resolve-url.sh dalexandre-devide <workspace-uuid>
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WS_NAME="${1:-${DEVIDE_WORKSPACE_NAME:-}}"
WS_ID="${2:-${DEVIDE_WORKSPACE_ID:-}}"

mise exec elixir@1.20.0-otp-28 erlang@28.5 -- mix run --no-start -e "
workspace =
  if \"${WS_NAME}\" != \"\" or \"${WS_ID}\" != \"\" do
    %{
      name: if(\"${WS_NAME}\" != \"\", do: \"${WS_NAME}\", else: nil),
      id: if(\"${WS_ID}\" != \"\", do: \"${WS_ID}\", else: nil),
      metadata: %{}
    }
  else
    nil
  end

case Casein.Agents.TidewaveMCP.resolve_url(workspace) do
  url when is_binary(url) and url != \"\" -> IO.puts(url)
  _ -> System.halt(1)
end
"