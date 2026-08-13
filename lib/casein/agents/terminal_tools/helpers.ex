defmodule Casein.Agents.TerminalTools.Helpers do
  @moduledoc """
  Shared JSON-Schema fragments and MCP metadata for terminal tool actions.
  Wire shapes are served on tools/list — keep them aligned with the previous
  hand-rolled `TerminalTools.definitions/0` output.
  """

  alias McpCtl.Params

  @default_capture_lines 120

  @doc false
  def default_capture_lines, do: @default_capture_lines

  @doc false
  def workspace_props, do: Params.terminal_workspace_props()

  @doc false
  def contains_param, do: Params.contains()

  @doc false
  def session_param, do: Params.session()

  @doc false
  def file_path_param do
    %{
      type: "string",
      description:
        "Workspace-relative path to open (e.g. \"lib/foo.ex\"). Absolute paths under " <>
          "the workspace root are normalized. Paths are re-validated server-side."
    }
  end

  @doc false
  def line_param do
    %{
      type: "integer",
      minimum: 1,
      description: "Optional 1-based line to reveal after opening (file surface only)."
    }
  end

  @doc false
  def pane_param, do: Params.pane()

  @doc false
  def caller_pane_param, do: Params.caller_pane()

  @doc false
  def lines_param, do: Params.lines()

  @doc false
  def ansi_param, do: Params.ansi()

  @doc false
  def keys_param, do: Params.keys()

  @doc false
  def command_param, do: Params.command()

  @doc false
  def paste_text_param, do: Params.paste_text()

  @doc false
  def submit_param, do: Params.submit()

  @doc false
  def confirm_param do
    %{
      type: "boolean",
      description:
        "Verify the agent actually consumed the submit (re-pressing Enter once if it did " <>
          "not) and fail with submit_not_confirmed when it never did. Defaults to true. " <>
          "Pass false when the keystroke itself is the point — answering a TUI menu or a " <>
          "y/n prompt, where no new turn starts."
    }
  end

  @doc false
  def next_prompt_text_param do
    %{
      type: "string",
      maxLength: Casein.Terminals.NextPrompt.text_limit(),
      description:
        "The message to deliver. Write it as a message to the agent, not as a shell command: " <>
          "it is pasted into the agent's prompt and submitted."
    }
  end

  @doc false
  def deliver_when_param do
    %{
      type: "string",
      enum: ["next_idle", "next_blocked", "next_done"],
      description:
        "Which state edge releases the message. next_idle (default) means the first " <>
          "transition into idle OR done — read it as \"when the agent stops working\", " <>
          "which is what every wired runtime actually reports at end of turn. " <>
          "next_done waits for a completed turn only; next_blocked waits for a permission " <>
          "prompt or a wedged turn. Hook-less runtimes (OpenCode) never emit these edges: " <>
          "set refuses with state_edges_unavailable instead of holding silently. " <>
          "Nothing here interrupts a working agent."
    }
  end

  @doc false
  def coalesce_key_param do
    %{
      type: "string",
      description:
        "Your identifier for this message. Only one message can be pending per pane " <>
          "regardless of key — the key lets you see whether the pending one is still yours " <>
          "and clear only that."
    }
  end

  @doc false
  def expires_in_seconds_param do
    %{
      type: "integer",
      minimum: 1,
      description:
        "Discard the message if it has not been delivered within this many seconds " <>
          "(default 86400, capped at 604800)."
    }
  end

  @doc false
  def actor_id_param do
    %{
      type: "string",
      description: "Who is sending, for audit attribution (for example an orchestrator name)."
    }
  end

  @doc false
  def allow_shared_worktree_param, do: Params.allow_shared_worktree()

  @doc false
  def since_param do
    %{
      type: "string",
      description: "Cursor uuid from a prior pull; return only newer entries."
    }
  end

  @doc false
  def tail_param do
    %{
      type: "integer",
      minimum: 1,
      maximum: 200,
      description: "Max entries to return (default 30)."
    }
  end

  @doc false
  def full_text_param do
    %{
      type: "boolean",
      description: "When true, return full text bodies instead of truncated previews."
    }
  end

  @doc false
  def label_param, do: %{type: "string"}

  @doc false
  def freeze_param do
    %{
      type: "boolean",
      description: "When true, keep this label until the pane is closed."
    }
  end

  @doc false
  def worktree_path_param, do: %{type: "string"}

  @doc false
  def branch_param, do: %{type: "string"}

  @doc false
  def agent_param, do: %{type: "string"}

  @doc false
  def runner_id_param, do: %{type: "string"}

  @doc false
  def session_id_param, do: %{type: "string"}

  @doc false
  def tmux_session_id_param, do: %{type: "string"}

  @doc false
  def ensure_preview_started_param do
    %{
      type: "boolean",
      description: "Start a runtime-owned preview server for this worktree. Defaults to false."
    }
  end

  @doc false
  def include_liveness_param do
    %{
      type: "boolean",
      description:
        "Observe each agent pane's worktree from outside (newest write, quiet time, commit " <>
          "count) and fold the verdict into agent_state. This is the only signal that " <>
          "separates a wedged agent from an idle one — a wedged agent reports nothing and " <>
          "leaves its last spinner frame on screen. Costs one pruned directory walk per " <>
          "worktree, cached briefly. Defaults to false."
    }
  end

  @doc false
  def include_transcript_param do
    %{
      type: "boolean",
      description:
        "Read each agent pane's own session transcript and fold the shape of its last turn " <>
          "into agent_state. This is what separates an agent that is waiting for you from " <>
          "one that merely finished: an assistant turn followed by silence resolves to " <>
          "awaiting_input, while an outstanding tool call stays working. Claude Code panes " <>
          "only; a pane whose transcript could not be resolved reports a reason and makes " <>
          "no claim. Costs one directory listing plus a bounded tail read per agent pane. " <>
          "Defaults to false."
    }
  end

  @doc false
  def exit_status_param do
    %{
      type: "string",
      enum: ["landed", "wip", "handoff"],
      description:
        "Session exit outcome. Call again at end-of-session so stale-worktree " <>
          "alarms skip intentional handoffs."
    }
  end

  @doc false
  def handoff_param do
    %{
      type: "string",
      description: "Short free-text status for the next agent or operator (branch, PR, blockers)."
    }
  end

  @doc false
  def gate_passed_param do
    %{
      type: "boolean",
      description: "Whether the gate run passed."
    }
  end

  @doc false
  def sha_param, do: %{type: "string"}

  @doc false
  def gate_duration_param do
    %{
      type: "number",
      minimum: 0,
      description: "Gate run duration in seconds."
    }
  end

  @doc false
  def gate_failed_step_param do
    %{
      type: "string",
      description: "The gate step that failed (last announced step of the run)."
    }
  end

  @doc false
  def agent_state_param do
    %{
      type: "string",
      enum: ["working", "blocked", "done", "idle"],
      description: "The agent's current semantic state."
    }
  end

  @doc false
  def agent_state_message_param do
    %{
      type: "string",
      description: "Short free-text detail (truncated to 200 characters)."
    }
  end

  @doc false
  def transcript_path_param do
    %{
      type: "string",
      description: "Absolute path to the agent CLI session JSONL transcript."
    }
  end

  @doc false
  def agent_session_id_param do
    %{
      type: "string",
      description: "Agent runtime's session identifier (for example Grok's sessionId)."
    }
  end

  @doc false
  def agent_runtime_param do
    %{
      type: "string",
      enum: ["grok", "claude", "codex", "opencode", "agent"],
      description: "Agent runtime identity supplied by an installed Casein hook."
    }
  end

  @doc false
  def grok_leader_socket_param do
    %{
      type: "string",
      description: "Private Grok leader socket injected into this managed launch."
    }
  end

  @doc false
  def grok_bundle_dir_param do
    %{
      type: "string",
      description: "Content-addressed Casein Grok capability bundle directory."
    }
  end

  @doc false
  def grok_bundle_digest_param do
    %{
      type: "string",
      description: "Lowercase SHA-256 digest of the injected Grok capability bundle."
    }
  end

  @doc false
  def agent_state_source_param do
    %{
      type: "string",
      enum: ["agent", "hook"],
      description: "Who is reporting: an agent directly, or an installed hook."
    }
  end

  @doc false
  def wait_states_param do
    %{
      type: "array",
      minItems: 1,
      items: %{type: "string", enum: ["working", "blocked", "done", "idle"]},
      description: "Target states to wait for."
    }
  end

  @doc false
  def timeout_ms_param do
    %{
      type: "integer",
      minimum: 0,
      maximum: 55_000,
      description: "Max time to block, in milliseconds (default 30000, capped at 55000)."
    }
  end

  @doc false
  def include_answer_param do
    %{
      type: "boolean",
      description:
        "When true and the matched state is done, include the observed agent's " <>
          "final assistant message from its transcript in answer."
    }
  end

  @doc false
  def metadata(name)
      when name in [
             "terminal_list_sessions",
             "terminal_context",
             "terminal_topology",
             "terminal_capture",
             "terminal_agent_pane",
             "terminal_capture_agent",
             "terminal_agent_transcript"
           ] do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_read],
      recovery_hints: ["Call terminal_list_sessions first when session is unknown."]
    }
  end

  def metadata(name)
      when name in [
             "terminal_send_agent_keys",
             "terminal_send_agent_command",
             "terminal_paste_agent_text"
           ] do
    %{
      mutation?: true,
      danger_level: :medium,
      capabilities: [:terminal_mutation],
      policy_tags: [:agent_pane_only],
      recovery_hints: [
        "Omit pane to require the agent_pair marker; pass pane to target any pane id.",
        "Use terminal_capture_agent after sending input to inspect output.",
        "On submit_not_confirmed the text reached the pane but was never submitted — " <>
          "capture the pane before resending, or use terminal_set_next_prompt if the " <>
          "agent is mid-turn.",
        "Do not double-Enter yourself: submit paths settle, press Enter, and retry once."
      ]
    }
  end

  # A staged prompt is a deferred pane mutation, so it carries the same
  # capability as the send tools it defers: a workspace whose agent write is
  # locked must not be able to arm an injection that fires later.
  def metadata("terminal_set_next_prompt") do
    %{
      mutation?: true,
      danger_level: :medium,
      capabilities: [:terminal_mutation],
      policy_tags: [:agent_pane_only, :deferred_delivery],
      recovery_hints: [
        "Only one message can be pending per pane; setting another replaces it.",
        "Use terminal_get_next_prompt to see what is already staged.",
        "Prefer deliver_when: next_done for Claude — its hook reports idle only at " <>
          "session start/end."
      ]
    }
  end

  def metadata("terminal_clear_next_prompt") do
    %{
      mutation?: true,
      danger_level: :low,
      capabilities: [:terminal_metadata],
      recovery_hints: [
        "Pass coalesce_key to avoid clearing a message you did not stage."
      ]
    }
  end

  def metadata("terminal_get_next_prompt") do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_read],
      recovery_hints: [
        "terminal_topology flags panes with pending_next_prompt without a per-pane call."
      ]
    }
  end

  def metadata(name) when name in ["terminal_send_keys", "terminal_send_command"] do
    %{
      mutation?: true,
      danger_level: :high,
      capabilities: [:terminal_mutation],
      policy_tags: [:raw_terminal_input],
      recovery_hints: [
        "Use terminal_topology to target the intended pane explicitly.",
        "Prefer terminal_send_agent_command when controlling the dedicated agent pane.",
        "Use terminal_capture after sending input to inspect output.",
        "terminal_send_command confirms the submit (one retry Enter) unless confirm:false.",
        "On submit_not_confirmed capture the pane before resending."
      ],
      examples: [
        %{
          arguments: %{
            "workspace_id" => "ws-1",
            "session" => "casein_ws-1_default",
            "pane" => "%3",
            "command" => "mix test"
          },
          structured_content: %{
            "status" => "sent",
            "submitted" => true,
            "delivery" => "delivered"
          }
        }
      ]
    }
  end

  def metadata("file_open_in_pane") do
    %{
      mutation?: true,
      danger_level: :medium,
      capabilities: [:terminal_mutation],
      policy_tags: [:opens_file_surface],
      recovery_hints: [
        "Pass workspace_id and a workspace-relative path.",
        "Call terminal_list_sessions first when session is unknown.",
        "Browser-viewable types (html/svg/pdf/images) open in a preview pane."
      ],
      examples: [
        %{
          arguments: %{
            "workspace_id" => "ws-1",
            "session" => "casein_ws-1_default",
            "path" => "lib/foo.ex",
            "line" => 12
          },
          structured_content: %{
            "surface" => "file",
            "pane_id" => "%4",
            "path" => "lib/foo.ex",
            "reused" => false
          }
        }
      ]
    }
  end

  def metadata("diff_open") do
    %{
      mutation?: true,
      danger_level: :low,
      capabilities: [:terminal_mutation],
      policy_tags: [:surfaces_diff_viewport],
      recovery_hints: [
        "Pass workspace_id; optional path focuses one file in the diff.",
        "Do not pass placement, size, position, or pane_id — Casein owns geometry.",
        "status no_viewer means nobody is watching; that is a correct no-op."
      ],
      examples: [
        %{
          arguments: %{
            "workspace_id" => "ws-1",
            "path" => "lib/foo.ex"
          },
          structured_content: %{
            "status" => "surfaced",
            "workspace_id" => "ws-1",
            "path" => "lib/foo.ex"
          }
        }
      ]
    }
  end

  def metadata("run_open") do
    %{
      mutation?: true,
      danger_level: :low,
      capabilities: [:terminal_mutation],
      policy_tags: [:surfaces_run_viewport],
      recovery_hints: [
        "Pass workspace_id; optional run_id focuses one ledger entry.",
        "A missing run_id lands on the ledger with nothing selected (normal empty state).",
        "Do not pass placement, size, position, or pane_id — Casein owns geometry.",
        "status no_viewer means nobody is watching; that is a correct no-op."
      ],
      examples: [
        %{
          arguments: %{
            "workspace_id" => "ws-1",
            "run_id" => "run-abc"
          },
          structured_content: %{
            "status" => "surfaced",
            "workspace_id" => "ws-1",
            "run_id" => "run-abc"
          }
        }
      ]
    }
  end

  # Layout tools are mutations, so a capability-scoped client (managed Grok)
  # only receives them once a human unlocks agent write — read-only by default,
  # exactly like the send tools. terminal_layout_snapshot writes a template row
  # rather than tmux, but it is still a workspace write and is classified as one.
  def metadata("terminal_layout_apply") do
    %{
      mutation?: true,
      danger_level: :medium,
      capabilities: [:terminal_mutation],
      policy_tags: [:declarative_layout, :additive_only],
      recovery_hints: [
        "Dry run first: call without dry_run to get the plan, then apply with plan_digest.",
        "plan_stale means the layout moved since you planned — re-plan, do not retry blind.",
        "unsupported_reconcile means the id is a built-in; snapshot the session and apply that.",
        "command_blocked means the template runs a command policy forbids — nothing ran.",
        "Cannot close windows or panes, and never moves focus. Use undo.template_id to revert."
      ],
      examples: [
        %{
          arguments: %{
            "workspace_id" => "ws-1",
            "session" => "casein_ws-1_default",
            "template_id" => "tpl-abc"
          },
          structured_content: %{
            "ok" => true,
            "mode" => "planned",
            "applied?" => false,
            "plan_digest" => "9f2c1d7a4b6e0c85",
            "change_count" => 3,
            "additive_only?" => true,
            "focus_unchanged?" => true
          }
        }
      ]
    }
  end

  def metadata("terminal_layout_snapshot") do
    %{
      mutation?: true,
      danger_level: :low,
      capabilities: [:terminal_mutation, :terminal_metadata],
      policy_tags: [:declarative_layout],
      recovery_hints: [
        "Take one before any layout change — applying the snapshot back is the undo.",
        "Does not touch tmux: no pane is opened, closed, resized, or focused.",
        "empty_topology means the session has no windows worth exporting.",
        "Pass dry_run true to see the export without saving it."
      ],
      examples: [
        %{
          arguments: %{"workspace_id" => "ws-1", "session" => "casein_ws-1_default"},
          structured_content: %{
            "ok" => true,
            "saved?" => true,
            "template_id" => "tpl-abc",
            "name" => "casein_ws-1_default export",
            "window_count" => 2
          }
        }
      ]
    }
  end

  def metadata(name)
      when name in [
             "terminal_set_agent_label",
             "terminal_bind_issue",
             "terminal_work_handle_create",
             "terminal_report_worktree",
             "terminal_report_agent_state",
             "terminal_request_clarification",
             "terminal_request_human_input",
             "gate_report"
           ] do
    %{
      mutation?: true,
      danger_level: :low,
      capabilities: [:terminal_metadata],
      recovery_hints: ["Pass workspace_id so Casein can associate the update with the workspace."]
    }
  end

  def metadata("terminal_say") do
    %{
      mutation?: true,
      danger_level: :low,
      capabilities: [:terminal_metadata],
      recovery_hints: [
        "On ambiguous_recipient, re-send to one of the returned pane addresses.",
        "On unknown_recipient, call terminal_topology to see the live window names.",
        "Delivery is not reading: the recipient collects with terminal_inbox."
      ]
    }
  end

  def metadata("terminal_inbox") do
    %{
      mutation?: true,
      danger_level: :low,
      capabilities: [:terminal_metadata],
      recovery_hints: [
        "Omit address to read the caller pane's own mailbox.",
        "Each message has status queued|collected and unread? — never treat send as read (#911).",
        "Pass collect=true only once you have acted; that clears unread. Peek leaves pending.",
        "Double-collect is idempotent via stable message_id — safe to retry.",
        "Addressed store only — does not write into panes (no terminal_send_*)."
      ],
      examples: [
        %{
          arguments: %{"workspace_id" => "ws-1", "session" => "casein_ws-1_x"},
          structured_content: %{
            "address" => "pane:%3",
            "pending" => 1,
            "unread" => 1,
            "messages" => [
              %{
                "message_id" => "msg-1",
                "status" => "queued",
                "unread?" => true,
                "body" => "rebase before auth"
              }
            ]
          }
        }
      ]
    }
  end

  def metadata(name)
      when name in [
             "terminal_work_handle_get",
             "terminal_work_handle_list"
           ] do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_read, :terminal_metadata],
      recovery_hints: [
        "Pass workspace_id and handle_id from terminal_work_handle_create.",
        "Status is always source=recorded — never scraped from the pane screen."
      ]
    }
  end

  def metadata("workspace_digest") do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_read],
      recovery_hints: [
        "Pass workspace_id when the endpoint is not pre-scoped.",
        "Follow up on risks with the suggested tool in each entry."
      ]
    }
  end

  def metadata("orchestration_status") do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_metadata, :terminal_read],
      recovery_hints: [
        "Requires workspace_id and session — fail closed when either is missing.",
        "gate_queue.observe_state unknown never means free; liveness.state unknown never means quiet.",
        "Pass gate_pr (or gate_run_id/branch/pid) for gate_queue.my_position.",
        "M1 aggregate — blocked[] + blocked_on + liveness on rows; no worker_launch here."
      ],
      examples: [
        %{
          arguments: %{
            "workspace_id" => "ws-1",
            "session" => "casein_ws-1_default",
            "gate_pr" => 384
          },
          structured_content: %{
            "total" => 3,
            "attention_count" => 1,
            "counts" => %{"needs_you" => 1, "working" => 2},
            "blocked" => [
              %{
                "pane_id" => "%3",
                "agent_state" => "blocked",
                "blocked_on" => %{
                  "kind" => "report",
                  "reason" => "blocked",
                  "detail" => "need unlock"
                }
              }
            ],
            "gate_queue" => %{
              "observe_state" => "ok",
              "lock_state" => "held",
              "depth" => 2,
              "my_position" => %{"status" => "waiting", "position" => 2, "ahead" => 1}
            }
          }
        }
      ]
    }
  end

  def metadata("worker_status") do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_metadata, :terminal_read],
      recovery_hints: [
        "Requires workspace_id, session, and pane — fail closed when any is missing.",
        "liveness.state unknown never means quiet; missing liveness is omitted, not idle.",
        "blocked_on.kind report vs derived stays distinct (M1 discipline).",
        "M2 single-worker deep status — inverse of orchestration_status; no worker_launch here."
      ],
      examples: [
        %{
          arguments: %{
            "workspace_id" => "ws-1",
            "session" => "casein_ws-1_default",
            "pane" => "%3"
          },
          structured_content: %{
            "found?" => true,
            "pane_id" => "%3",
            "agent_state" => "blocked",
            "issue" => 384,
            "blocked_on" => %{
              "kind" => "report",
              "reason" => "blocked",
              "detail" => "need unlock"
            },
            "liveness" => %{"state" => "active"},
            "worktree_path" => "/tmp/casein-agent-worktrees/wt-demo"
          }
        }
      ]
    }
  end

  def metadata("orchestration_list_workers") do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_metadata, :terminal_read],
      recovery_hints: [
        "Requires workspace_id and session — fail closed when either is missing.",
        "Compact FleetBoard rows only; optional fleet_role and needs_you_only filters.",
        "liveness unknown never becomes idle (FleetBoard kind discipline).",
        "M3 list — not worker_launch; use worker_status for one-pane depth."
      ],
      examples: [
        %{
          arguments: %{
            "workspace_id" => "ws-1",
            "session" => "casein_ws-1_default",
            "fleet_role" => "worker",
            "needs_you_only" => true
          },
          structured_content: %{
            "total" => 3,
            "filtered_total" => 1,
            "workers" => [
              %{
                "pane_id" => "%3",
                "window" => "worker-384",
                "issue" => 384,
                "agent_state" => "blocked",
                "blocked_on" => %{"kind" => "report", "reason" => "blocked"},
                "fleet_role" => "worker",
                "needs_you?" => true
              }
            ]
          }
        }
      ]
    }
  end

  def metadata("runtime_signal") do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_metadata, :terminal_read],
      recovery_hints: [
        "S11/#867: read modules.tmux_adapter first — SHA alone misses adapter/default mismatches.",
        "paths_disagree? true means MCP path (Backend.module fallback) ≠ legacy get_env(..., Tmux).",
        "mcp_surface.ok? false means missing callbacks (e.g. paste_text/3) on the live module.",
        "revision.status unknown never means current."
      ],
      examples: [
        %{
          arguments: %{"workspace_id" => "ws-1"},
          structured_content: %{
            "diverged?" => true,
            "attention" => ["tmux_adapter_paths_disagree"],
            "revision" => %{"status" => "current", "branch" => "master"},
            "modules" => %{
              "tmux_adapter" => %{
                "mcp_resolved" => "Casein.Terminals.Backends.Tmux",
                "ops_resolved" => "Casein.Terminals.Tmux",
                "paths_disagree?" => true
              }
            }
          }
        }
      ]
    }
  end

  def metadata("worker_launch") do
    %{
      mutation?: true,
      danger_level: :medium,
      capabilities: [:terminal_mutation, :terminal_metadata],
      recovery_hints: [
        "Requires workspace_id, session, runtime, task_slug — fail closed when any is missing.",
        "One call returns the full receipt (pane_id, worktree_path, handle_id) — no topology scrape required.",
        "dry_run: true plans without opening a window.",
        "Never falls back to a hidden subagent; spawn failure is a hard error.",
        "Follow with worker_status / worker_cancel / orchestration_list_workers; durable graph still out of scope."
      ],
      examples: [
        %{
          arguments: %{
            "workspace_id" => "ws-1",
            "session" => "casein_ws-1_default",
            "runtime" => "opencode",
            "task_slug" => "384-item"
          },
          structured_content: %{
            "ok" => true,
            "visible?" => true,
            "hidden_subagent?" => false,
            "pane_id" => "%42",
            "window_name" => "worker-384-item",
            "worktree_path" => "/tmp/casein-agent-worktrees/wt-demo",
            "handle_id" => "wh_abc"
          }
        }
      ]
    }
  end

  def metadata("worker_cancel") do
    %{
      mutation?: true,
      danger_level: :medium,
      capabilities: [:terminal_mutation, :terminal_metadata],
      recovery_hints: [
        "Requires workspace_id, session, pane — fail closed when any is missing.",
        "Kills by window id (@N) only — tmux renumbers indices.",
        "dry_run: true classifies without killing; cancelled? stays false.",
        "Refuses manager/operator/unlabeled panes, the caller's own window, and the last window.",
        "cancelled? means the window is gone, not hidden. Durable graph still out of scope."
      ],
      examples: [
        %{
          arguments: %{
            "workspace_id" => "ws-1",
            "session" => "casein_ws-1_default",
            "pane" => "%42"
          },
          structured_content: %{
            "ok" => true,
            "cancelled?" => true,
            "visible?" => false,
            "pane_id" => "%42",
            "window_id" => "@9",
            "window_name" => "worker-384-item"
          }
        }
      ]
    }
  end

  def metadata("worktree_status") do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_metadata, :terminal_read],
      recovery_hints: [
        "Requires workspace_id, session, pane — fail closed when any is missing.",
        "Joins WorkerStatus identity + Git.Inspector (same inspector as casein://fleet/summary).",
        "git.inspect_state unknown never means clean or not-ahead; unknown_reason is required.",
        "ahead nil (no upstream) omits commits_not_on_origin? — not a false-unpushed.",
        "M4.2 inspection — not changed_paths / worker_replace; durable graph still out of scope."
      ],
      examples: [
        %{
          arguments: %{
            "workspace_id" => "ws-1",
            "session" => "casein_ws-1_default",
            "pane" => "%42"
          },
          structured_content: %{
            "found?" => true,
            "pane_id" => "%42",
            "worktree_path" => "/tmp/casein-agent-worktrees/wt-demo",
            "git" => %{
              "inspect_state" => "ok",
              "branch" => "agent/opencode/demo",
              "head_sha" => "abc1234",
              "ahead" => 2,
              "commits_not_on_origin?" => true
            }
          }
        }
      ]
    }
  end

  def metadata("terminal_wait_agent_state") do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_read],
      recovery_hints: [
        "Re-issue the call when timed_out is true to keep long-polling.",
        "Have the observed agent call terminal_report_agent_state for precise transitions."
      ]
    }
  end

  def metadata("mcp_self_test") do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_read, :terminal_metadata],
      recovery_hints: [
        "Safe on a live fleet: writes stay inside a throwaway casein_mcp_self_test_* session.",
        "status undefined means the running adapter is missing the function at the called arity.",
        "resolved_adapter is what Shared.tmux/0 actually dispatches to — compare with checkout defaults."
      ],
      examples: [
        %{
          arguments: %{},
          structured_content: %{
            "ok?" => false,
            "resolved_adapter" => "Casein.Terminals.Backends.Tmux",
            "summary" => %{"ok" => 7, "undefined" => 2, "error" => 0, "total" => 9},
            "verbs" => [
              %{
                "verb" => "terminal_paste_agent_text",
                "fun" => "paste_text",
                "arity" => 3,
                "status" => "undefined"
              }
            ]
          }
        }
      ]
    }
  end

  def metadata(_name), do: %{}

  @doc """
  Convert validated action params (atom-keyed struct or map) into the
  string-keyed map the legacy implementation expects.
  """
  @spec to_impl_args(term()) :: map()
  def to_impl_args(%{__struct__: _} = params), do: to_impl_args(Map.from_struct(params))

  def to_impl_args(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end
end
