defmodule DevIDE.Terminals.Boundary do
  @moduledoc """
  Admission boundary for terminal input.

  Raw PTY input is intentionally separate from governed command submission.
  Governed terminal lines are resolved to existing safe actions and queued
  through the runner protocol; unrecognized lines are refused and audited.
  """

  alias DevIDE.Commands
  alias DevIDE.Policy
  alias DevIDE.Policy.Decision
  alias DevIDE.Runners
  alias DevIDE.Runs.Ledger
  alias DevIDE.Terminals.InspectionCommands
  alias DevIDE.Terminals.Workflows
  alias DevIDE.Workspace
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.State

  @max_line_bytes 512
  @interactive_command_ids ~w(agent claude clauded codex grok opencode)

  @type mode :: :governed | :raw

  @spec normalize_mode(term()) :: mode()
  def normalize_mode("raw"), do: :raw
  def normalize_mode(:raw), do: :raw
  def normalize_mode(_), do: :governed

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
    decision = raw_decision(workspace_id, host_id)

    _ =
      Ledger.raw_session_attached(decision, %{
        workspace_id: workspace_id,
        actor_id: actor_id,
        session_id: Keyword.get(opts, :session_id),
        metadata: %{
          "host_id" => host_id,
          "terminal_mode" => "raw"
        }
      })

    if Decision.allow?(decision), do: :ok, else: {:error, decision.reason}
  end

  @spec submit_governed(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom() | term()}
  def submit_governed(workspace_id, line, opts \\ [])
      when is_binary(workspace_id) and is_binary(line) do
    actor_id = Keyword.get(opts, :actor_id, "terminal")
    session_id = Keyword.get(opts, :session_id)
    cleaned = clean_line(line)
    run_id = Ledger.new_run_id()

    cond do
      cleaned == "" ->
        {:error, :blank}

      byte_size(cleaned) > @max_line_bytes ->
        audit_refusal(workspace_id, actor_id, session_id, run_id, audit_line(cleaned), :too_long)
        {:error, :too_long}

      true ->
        submit_governed_line(workspace_id, cleaned, actor_id, session_id, run_id)
    end
  end

  defp submit_governed_line(workspace_id, cleaned, actor_id, session_id, run_id) do
    case resolve_command(cleaned) do
      {:ok, command_id} ->
        enqueue_governed(workspace_id, command_id, cleaned, actor_id, session_id, run_id)

      {:error, :blank} ->
        {:error, :blank}

      {:error, :requires_raw_terminal} ->
        audit_refusal(
          workspace_id,
          actor_id,
          session_id,
          run_id,
          audit_line(cleaned),
          :requires_raw_terminal
        )

        {:error, :requires_raw_terminal}

      {:error, _reason} ->
        case Workflows.resolve_line(workspace_id, cleaned) do
          {:ok, command_id} ->
            enqueue_governed(workspace_id, command_id, cleaned, actor_id, session_id, run_id)

          {:error, _} ->
            submit_inspection_or_refuse(workspace_id, cleaned, actor_id, session_id, run_id)
        end
    end
  end

  defp submit_inspection_or_refuse(workspace_id, cleaned, actor_id, session_id, run_id) do
    case run_inspection(workspace_id, cleaned, actor_id, session_id, run_id) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        audit_refusal(workspace_id, actor_id, session_id, run_id, audit_line(cleaned), reason)
        {:error, reason}
    end
  end

  @spec resolve_command(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def resolve_command(line) when is_binary(line) do
    cleaned = clean_line(line)

    cond do
      cleaned == "" ->
        {:error, :blank}

      byte_size(cleaned) > @max_line_bytes ->
        {:error, :too_long}

      interactive_command_id?(cleaned) ->
        {:error, :requires_raw_terminal}

      true ->
        cleaned
        |> split_argv()
        |> command_id_for_argv()
    end
  end

  def resolve_command(_), do: {:error, :not_allowed}

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
  def format_reason(:raw_terminal_disabled), do: "raw terminal input is disabled in governed mode"
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

    if local_host?(host_id) and Application.get_env(:dev_ide, :allow_local_raw_terminal, false) do
      Decision.allow(:raw_terminal, Policy.mode(ctx), ctx)
    else
      Policy.can_use_raw_terminal?(ctx)
    end
  end

  defp local_host?(host_id), do: host_id in ["local", "localhost", nil, ""]

  defp interactive_command_id?(id), do: id in @interactive_command_ids

  defp enqueue_governed(workspace_id, command_id, line, actor_id, session_id, run_id) do
    case Runners.enqueue_command(workspace_id, command_id,
           requested_by: actor_id || "terminal",
           metadata: %{
             source: "terminal",
             trigger: "governed_terminal",
             terminal_mode: "governed",
             session_id: session_id,
             command_id: command_id,
             command_line: line,
             run_id: run_id,
             protocol: Runners.protocol()
           }
         ) do
      {:ok, assignment} -> {:ok, Runners.assignment_payload(assignment)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_inspection(workspace_id, line, actor_id, session_id, run_id) do
    with {:ok, ws} <- workspace_for_inspection(workspace_id),
         {:ok, root} <- Workspaces.safe_host_path(ws),
         {:ok, result} <- InspectionCommands.run(root, line, workspace: ws) do
      _ =
        Ledger.command_requested(%{
          workspace_id: workspace_id,
          actor_id: actor_id || "terminal",
          decision: :allow,
          command_id: line,
          command_line: line,
          run_id: run_id,
          plane: "governed_inspection",
          metadata: %{
            "policy_mode" => to_string(Policy.mode(%{workspace_id: workspace_id})),
            "session_id" => session_id,
            "exit_code" => inspect(result.exit_code),
            "output_truncated" => result.output_truncated
          }
        })

      {:ok, Map.put(result, :kind, :inspection)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_allowed}
    end
  end

  defp workspace_for_inspection(workspace_id) do
    case State.get(workspace_id) do
      {:ok, record} ->
        {:ok,
         %Workspace{
           id: workspace_id,
           name: record.name || workspace_id,
           path: record.host_path,
           status: :running,
           metadata: record.manager_payload || %{}
         }}

      :error ->
        Workspaces.get(workspace_id)
    end
  end

  defp audit_refusal(workspace_id, actor_id, session_id, run_id, line, reason) do
    decision =
      Decision.deny(:run_command, Policy.mode(%{workspace_id: workspace_id}), reason, %{})

    Ledger.command_denied(decision, %{
      workspace_id: workspace_id,
      actor_id: actor_id,
      session_id: session_id,
      command_line: if(line == "", do: "(blank)", else: line),
      run_id: run_id,
      plane: "governed",
      metadata: %{
        "reason" => Atom.to_string(reason)
      }
    })
  end

  defp clean_line(line) do
    line
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.trim()
  end

  defp audit_line(line) when byte_size(line) <= @max_line_bytes, do: line

  defp audit_line(line) do
    String.slice(line, 0, @max_line_bytes) <> "..."
  end

  defp split_argv(line) do
    OptionParser.split(line)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp command_id_for_argv([]), do: {:error, :not_allowed}

  defp command_id_for_argv([id]) do
    if Commands.allowed?(id), do: {:ok, id}, else: command_id_for_full_argv([id])
  end

  defp command_id_for_argv(argv), do: command_id_for_full_argv(argv)

  defp command_id_for_full_argv(argv) do
    Commands.allowlist()
    |> Enum.find(fn {_id, allowed_argv} -> argv in accepted_argvs(allowed_argv) end)
    |> case do
      {id, _argv} -> {:ok, id}
      nil -> {:error, :not_allowed}
    end
  end

  defp accepted_argvs(["mix", "test", "--color"] = argv), do: [argv, ["mix", "test"]]
  defp accepted_argvs(argv), do: [argv]
end
