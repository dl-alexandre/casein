defmodule Casein.Agents.TerminalTools.JidoAdmit do
  @moduledoc "jido_admit."

  use Jido.Action,
    name: "jido_admit",
    description:
      "Admit a bounded headless Jido Workcell worker with supported typed actions (code_read / code_search / code_apply_patch / code_exec / git_status / git_diff / git_handoff / request_clarification / request_human_input / report_progress / report_result / handoff_evidence). Chooses Jido automatically when CASEIN_JIDO_HEADLESS or the per-workspace flag is on. Explicit runtime: opencode, or a disabled workspace, returns a worker_launch fallback receipt and starts no pane. Never exposes shell or tmux. Requires workspace_id.",
    category: "terminal",
    tags: ["terminal", "orchestration", "jido"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      runtime: [type: :string],
      skill: [type: :string],
      task_id: [type: :string],
      session_id: [type: :string],
      lease_id: [type: :string],
      origin: [type: :string],
      lane: [type: :string],
      release_sha: [type: :string],
      attempt_id: [type: :string],
      receipt_id: [type: :string],
      worktree_path: [type: :string],
      repository: [type: :string],
      base_branch: [type: :string],
      assigned_branch: [type: :string],
      allowed_paths: [type: {:list, :string}],
      push_allowed?: [type: :boolean],
      actions: [type: {:list, {:map, :any, :any}}],
      deadline_ms: [type: :integer],
      action_timeout_ms: [type: :integer],
      max_retries: [type: :integer],
      dry_run: [type: :boolean]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.JidoDelegate
  alias Casein.Agents.JidoPod.CodeActions
  alias Casein.Agents.JidoWorkcell.Limits
  alias Casein.Agents.TerminalTools.Helpers
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          runtime: %{
            type: "string",
            enum: ["jido", "opencode"],
            description:
              "Optional runtime pin. Omit to choose Jido when the workspace flag is on. opencode always returns a worker_launch fallback."
          },
          skill: %{
            type: "string",
            description: "Optional Jido skill name from the typed catalog (inspect, patch, …)."
          },
          task_id: %{
            type: "string",
            description: "Optional Mira/Oban task id. Omitted IDs remain absent."
          },
          session_id: %{
            type: "string",
            description:
              "Optional Casein terminal session id; legal only on the Casein terminal lane."
          },
          lease_id: %{
            type: "string",
            description: "Optional Mira/Oban lease id; omitted unless the scheduler assigned it."
          },
          origin: %{
            type: "string",
            enum: ["mira", "oban"],
            description: "Optional scheduler origin required when task_id or lease_id is present."
          },
          lane: %{
            type: "string",
            enum: ["casein_terminal", "terminal"],
            description: "Optional lane marker for the conditional Casein terminal session id."
          },
          release_sha: %{
            type: "string",
            description: "Exact 40-character lowercase release SHA required for a Git handoff."
          },
          attempt_id: %{
            type: "string",
            description: "Optional attempt id. Casein may mint its internal attempt identity."
          },
          receipt_id: %{
            type: "string",
            description:
              "Required by a git_handoff action; supplied by the manager, never minted by the worker."
          },
          worktree_path: %{
            type: "string",
            description:
              "Assigned worktree for Jido code actions. Required for non-empty action lists."
          },
          repository: %{
            type: "string",
            description: "Trusted repository identifier included in the completion receipt."
          },
          base_branch: %{
            type: "string",
            description: "Trusted base branch recorded in the worker receipt."
          },
          assigned_branch: %{
            type: "string",
            description: "Non-default branch assigned to this worker; Git is bound to it exactly."
          },
          allowed_paths: %{
            type: "array",
            description: "Explicit relative file allowlist for the audited Git handoff.",
            items: %{type: "string"}
          },
          push_allowed?: %{
            type: "boolean",
            description:
              "Trusted manager grant required before the worker may push its assigned branch."
          },
          actions: %{
            type: "array",
            maxItems: Limits.max_actions(),
            description:
              "Supported typed Jido steps only. Identity fields on args are ignored; workspace/worktree come from trusted scope.",
            items: %{
              type: "object",
              required: ["name"],
              properties: %{
                name: %{
                  type: "string",
                  enum: CodeActions.allowed(),
                  description: "Supported typed Jido action name."
                },
                args: %{
                  type: "object",
                  description:
                    "Action arguments. workspace_id/worktree_path/attempt_id are stripped."
                },
                mutation_token: %{
                  type: "string",
                  description:
                    "Optional idempotency token so fallback does not replay a mutation."
                }
              }
            }
          },
          deadline_ms: %{
            type: "integer",
            minimum: 1,
            description: "Attempt deadline in milliseconds."
          },
          action_timeout_ms: %{
            type: "integer",
            minimum: 1,
            description: "Per-action timeout in milliseconds."
          },
          max_retries: %{
            type: "integer",
            minimum: 0,
            description: "Worker crash retries. Mutations are not replayed."
          },
          dry_run: %{
            type: "boolean",
            description: "When true, return the Jido-vs-OpenCode selection without admitting."
          }
        }),
        ["workspace_id"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("jido_admit")

  @impl Jido.Action
  def run(params, context) do
    attrs = Helpers.to_impl_args(params)

    attrs =
      case trusted_principal(context) do
        principal when is_binary(principal) and principal != "" ->
          Map.put(attrs, :principal, principal)

        _ ->
          attrs
      end

    JidoDelegate.admit(attrs)
  end

  defp trusted_principal(context) when is_map(context) do
    context[:actor] || context[:principal]
  end

  defp trusted_principal(_context), do: nil
end
