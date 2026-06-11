# Claude Code — project notes

Read **AGENTS.md** before doing anything in this repo. It is the authoritative source for:

- `git push` authentication (repo-local credential helper, not ambient `GH_TOKEN`) — see "Friction we hit" table
- Deploy path: commit → push to `master` → CI deploys; or `bash scripts/deploy-local.sh` for fast local activation
- `mix` invocation: use `mise exec elixir@1.20.0-otp-28 erlang@28.5 -- mix ...` (no host toolchain)
- MCP endpoint URLs, workspace_id, and agent pane pairing protocol
- `.devbox-agent-prompt.txt` for external agent starter prompts
