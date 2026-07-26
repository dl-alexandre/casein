---
name: casein-agent-pair
description: Operate Casein's human-plus-agent tmux layout without colliding with the operator. Use when discovering sessions, selecting the dedicated agent pane, sending commands or text, waiting on another agent, or reading its transcript.
---

# Casein agent pairing

1. Call `terminal_context` or `terminal_list_sessions` with `workspace_id`.
2. Call `terminal_topology` and locate the pane whose role is `agent`. Never assume the focused pane is safe; it belongs to the operator by default.
3. Prefer `terminal_send_agent_command`, `terminal_paste_agent_text`, and other role-aware tools. If using raw pane tools, always pass the explicit agent pane id.
4. Use `terminal_capture_agent` or `terminal_capture` to verify output after sending input.
5. Use `terminal_wait_agent_state` for semantic completion or attention instead of tight polling.
6. Preserve the operator and verify panes. Do not kill, resize, or retarget them unless the user explicitly asks.

If the layout lacks an agent pane, ask the operator to apply the built-in `agent_pair` template or use the appropriate Casein control to create it.
