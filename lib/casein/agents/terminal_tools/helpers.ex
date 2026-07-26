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
        "Apply the agent_pair template before using agent-pane mutation tools.",
        "Use terminal_capture_agent after sending input to inspect output."
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
        "Use terminal_capture after sending input to inspect output."
      ],
      examples: [
        %{
          arguments: %{
            "workspace_id" => "ws-1",
            "session" => "casein_ws-1_default",
            "pane" => "%3",
            "command" => "mix test"
          },
          structured_content: %{"status" => "sent"}
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

  def metadata(name)
      when name in [
             "terminal_set_agent_label",
             "terminal_report_worktree",
             "terminal_report_agent_state",
             "gate_report"
           ] do
    %{
      mutation?: true,
      danger_level: :low,
      capabilities: [:terminal_metadata],
      recovery_hints: ["Pass workspace_id so Casein can associate the update with the workspace."]
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
