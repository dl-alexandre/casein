defmodule DevIDE.Terminals.Boundary do
  @moduledoc """
  Admission boundary for raw terminal input.

  Raw PTY attachment is gated by `DevIDE.Policy.can_use_raw_terminal?/1` and
  audited via `DevIDE.Runs.Ledger.raw_session_attached/2`.
  """

  alias DevIDE.Commands
  alias DevIDE.Policy
  alias DevIDE.Policy.Decision
  alias DevIDE.Runs.Ledger
  alias DevIDE.Terminals.InspectionCommands
  alias DevIDE.Workspaces.Scratch

  @interactive_command_ids ~w(agent claude clauded codex grok opencode)

  @spec raw_allowed?(String.t(), String.t() | nil) :: boolean()
  def raw_allowed?(workspace_id, host_id) do
    workspace_id
    |> raw_decision(host_id)
    |> Decision.allow?()
  end

  @spec authorize_raw(String.t(), keyword()) :: :ok | {:error, atom()}
  def authorize_raw(workspace_id, opts \\ []) when is_binary(workspace_id) do
    host_id = Keyword.get(opts, :host_id)
    actor_id = Keyword.get(opts, :actor_id)
    session_id = Keyword.get(opts, :session_id)
    decision = raw_decision(workspace_id, host_id)

    # Scratch is synthetic (no workspace_records row). Skip ledger rows so we
    # do not write audit events keyed to a non-existent workspace.
    unless Scratch.scratch?(workspace_id) or
             raw_session_attached_audited?(workspace_id, session_id) do
      _ =
        Ledger.raw_session_attached(decision, %{
          workspace_id: workspace_id,
          actor_id: actor_id,
          session_id: session_id,
          metadata: %{
            "host_id" => host_id,
            "terminal_mode" => "raw"
          }
        })
    end

    if Decision.allow?(decision), do: :ok, else: {:error, decision.reason}
  end

  # Best-effort dedup so a raw reconnect doesn't re-emit run.session_attached.
  # The lookback is bounded (last 20 ledger entries), so on a very busy workspace
  # the prior attach can scroll out of view and a duplicate audit may be written.
  # That is acceptable — audits are append-only and a rare duplicate is harmless.
  defp raw_session_attached_audited?(workspace_id, session_id)
       when is_binary(workspace_id) and is_binary(session_id) do
    Ledger.recent_for(workspace_id, 20)
    |> Enum.any?(
      &(&1.action == "run.session_attached" and &1.target_ref == session_id and
          &1.decision == :allow)
    )
  end

  defp raw_session_attached_audited?(_, _), do: false

  @spec interactive_command_ids() :: [String.t()]
  def interactive_command_ids, do: @interactive_command_ids

  @spec command_examples(keyword()) :: [String.t()]
  def command_examples(opts \\ []) do
    raw_available? = Keyword.get(opts, :raw_available?, true)

    safe_action_examples =
      Commands.allowlist()
      |> Enum.sort_by(fn {id, _argv} -> id end)
      |> Enum.reject(fn {id, _argv} ->
        not raw_available? and id in @interactive_command_ids
      end)
      |> Enum.map(fn
        {_id, ["mix", "test", "--color"]} -> "mix test"
        {_id, argv} -> Enum.join(argv, " ")
      end)

    InspectionCommands.examples() ++ safe_action_examples
  end

  @spec format_reason(term()) :: String.t()
  def format_reason(:blank), do: "blank command"
  def format_reason(:not_allowed), do: "command is not a safe action"
  def format_reason(:too_long), do: "command line is too long"
  def format_reason(:requires_local_host), do: "raw shell requires local host"
  def format_reason(:requires_manual_mode), do: "raw shell requires manual workspace mode"
  def format_reason(:requires_raw_terminal), do: "interactive command requires raw shell"
  def format_reason(:raw_terminal_disabled), do: "raw terminal input is disabled"
  def format_reason(:safe_action_not_allowed), do: "command is not a safe action"
  def format_reason(:not_found), do: "workspace is not registered"
  def format_reason({:policy_denied, _}), do: "command denied by policy"
  def format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_reason(reason), do: inspect(reason)

  defp raw_decision(workspace_id, host_id) do
    ctx = %{
      workspace_id: workspace_id,
      host_id: host_id,
      actor_type: :terminal
    }

    Policy.can_use_raw_terminal?(ctx)
  end
end
