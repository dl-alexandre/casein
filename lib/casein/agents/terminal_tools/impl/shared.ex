defmodule Casein.Agents.TerminalTools.Impl.Shared do
  @moduledoc false

  alias Casein.Agents.AgentPane
  alias Casein.Terminals.Tmux
  alias Casein.Terminals.TmuxPolicy
  alias Casein.Terminals.TmuxTopology
  alias Casein.Workspaces
  alias Casein.Workspaces.Scratch

  @session_prefix "casein_"
  @default_capture_lines 120

  def tmux, do: Application.get_env(:casein, :tmux_adapter, Tmux)

  def compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # PaneSubmit returns atom confirmation/delivery; MCP payloads stringify them.
  def stringify_confirmation(result) when is_map(result) do
    Map.new(result, fn
      {key, value}
      when key in [:confirmation, :delivery] and is_atom(value) and not is_nil(value) ->
        {key, Atom.to_string(value)}

      pair ->
        pair
    end)
  end

  def string_arg(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_argument, key}}
    end
  end

  def string_param(params, key) do
    case Map.get(params, key) || Map.get(params, atom_key(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp atom_key("caller_pane"), do: :caller_pane
  defp atom_key("tmux_session_id"), do: :tmux_session_id
  defp atom_key("workspace_id"), do: :workspace_id
  defp atom_key("session"), do: :session
  defp atom_key("pane"), do: :pane
  defp atom_key("freeze"), do: :freeze
  defp atom_key(_), do: nil

  def workspace_id(params) do
    case Map.get(params, "workspace_id") || Map.get(params, :workspace_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  def workspace_id_arg(params) do
    case workspace_id(params) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :missing_workspace_id}
    end
  end

  def truthy?(value), do: value in [true, "true", "1", 1]

  def session_arg(params) do
    with {:ok, session} <- string_arg(params, "session"), do: validate_session(session, params)
  end

  def session_or_default_arg(params) do
    case Map.get(params, "session") || Map.get(params, :session) do
      session when is_binary(session) and session != "" -> validate_session(session, params)
      _ -> default_session(params)
    end
  end

  defp validate_session(session, params) do
    with true <- String.starts_with?(session, @session_prefix) || {:error, :unscoped_session},
         true <- workspace_matches?(session, params) || {:error, :workspace_mismatch},
         true <- session_exists?(session) || {:error, :no_such_session} do
      {:ok, session}
    end
  end

  defp default_session(params) do
    case sessions_for(params) do
      [] ->
        {:error, :no_workspace_sessions}

      [session] ->
        {:ok, session.session}

      sessions ->
        # The caller's own pane pins the session it physically lives in —
        # a stronger signal than "whichever session the operator has attached".
        case caller_session(sessions, params) do
          {:ok, session} -> {:ok, session}
          :none -> {:error, ambiguous_sessions_error(sessions)}
        end
    end
  end

  defp caller_session(sessions, params) do
    with pane_id when is_binary(pane_id) <- caller_pane(params),
         %{session: session} <-
           Enum.find(sessions, fn %{session: session} -> pane_id in pane_ids(session) end) do
      {:ok, session}
    else
      _ -> :none
    end
  end

  defp workspace_matches?(session, params) do
    case workspace_prefixes(params) do
      [] ->
        true

      prefixes ->
        # Full <prefix><sid> match, not a bare prefix: `casein_acme_` is a
        # genuine prefix of workspace `acme_prod`'s `casein_acme_prod_1`, so
        # String.starts_with?/2 let a token scoped to `acme` drive `acme_prod`.
        Enum.any?(prefixes, &TmuxPolicy.session_in_namespace?(session, &1))
    end
  end

  defp session_exists?(session) do
    adapter = tmux()
    Code.ensure_loaded(adapter)

    cond do
      function_exported?(adapter, :session_exists?, 1) -> adapter.session_exists?(session)
      function_exported?(adapter, :session_alive?, 1) -> adapter.session_alive?(session)
      true -> false
    end
  end

  def sessions_for(params) do
    tmux().list_sessions()
    |> Enum.filter(&String.starts_with?(&1.session, @session_prefix))
    |> filter_workspace(params)
  end

  def filter_workspace(sessions, params) do
    case workspace_prefixes(params) do
      [] ->
        # Unscoped MCP listing must not leak synthetic scratch shells
        # (`casein___scratch___*`). Scoped workspace_id calls already exclude
        # them via prefix matching.
        Enum.reject(sessions, &scratch_session?/1)

      prefixes ->
        # Same exact-boundary rule as workspace_matches?/2 — this is the listing
        # that leaks a neighbouring workspace's session names to a scoped token.
        Enum.filter(sessions, fn %{session: name} ->
          Enum.any?(prefixes, &TmuxPolicy.session_in_namespace?(name, &1))
        end)
    end
  end

  defp scratch_session?(%{session: name}) when is_binary(name) do
    String.starts_with?(name, Tmux.workspace_session_prefix(Scratch.id()))
  end

  defp scratch_session?(_), do: false

  defp workspace_prefixes(params) do
    case workspace_id(params) do
      nil ->
        []

      id ->
        id
        |> workspace_session_prefixes()
        |> Enum.uniq()
    end
  end

  defp workspace_session_prefixes(id) do
    prefixes = [Tmux.workspace_session_prefix(id)]

    case Workspaces.get(id) do
      {:ok, ws} ->
        for candidate <- [ws.name, ws.id], is_binary(candidate), candidate != "" do
          Tmux.workspace_session_prefix(candidate)
        end
        |> Enum.uniq()

      _ ->
        prefixes
    end
  end

  defp ambiguous_sessions_error(sessions) do
    %{
      error: :ambiguous_workspace_sessions,
      ambiguous: true,
      message: "Multiple workspace sessions match. Pass session explicitly.",
      candidate_sessions: Enum.map(sessions, &session_candidate/1),
      safe_to_mutate: false,
      next_tool: "terminal_context"
    }
  end

  def session_candidate(%{session: name} = session) do
    %{
      session: name,
      attached: Map.get(session, :attached),
      activity: Map.get(session, :activity)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def caller_pane(params) do
    case Map.get(params, "caller_pane") || Map.get(params, :caller_pane) do
      pane when is_binary(pane) and pane != "" -> pane
      _ -> nil
    end
  end

  def target_arg(session, params) do
    case Map.get(params, "pane") || Map.get(params, :pane) do
      pane when pane in [nil, ""] ->
        {:ok, session}

      pane when is_binary(pane) ->
        if pane in pane_ids(session), do: {:ok, pane}, else: {:error, :pane_not_in_session}

      _ ->
        {:error, :invalid_pane}
    end
  end

  defp pane_ids(session), do: session |> then(&tmux().list_session_panes(&1)) |> Enum.map(& &1.id)

  def find_agent_pane(session, opts) do
    AgentPane.find(session, tmux(), opts)
  end

  # Anchor agent-pane resolution to the caller: prefer its window's panes and
  # never resolve to the caller itself (an agent targeting "the agent pane"
  # wants a peer — resolving to itself sends prompts into its own input).
  def find_agent_pane(session, params, opts) do
    find_agent_pane(session, caller_aware_opts(params, opts))
  end

  defp caller_aware_opts(params, opts) do
    case caller_pane(params) do
      nil ->
        opts

      caller ->
        opts
        |> Keyword.put(:exclude_pane, caller)
        |> Keyword.put(:prefer_window_of, caller)
    end
  end

  # `target == session` means no pane was supplied and tmux would pick the
  # session's active pane — which follows the attached operator's focus.
  def resolve_implicit_target(session, session), do: {implicit_active_pane(session), true}
  def resolve_implicit_target(_session, pane), do: {pane, false}

  defp implicit_active_pane(session) do
    snapshot = TmuxTopology.snapshot(session, tmux: tmux())

    case Map.get(snapshot, :active_pane_id) do
      pane_id when is_binary(pane_id) -> pane_id
      _ -> session
    end
  rescue
    _ -> session
  catch
    :exit, _ -> session
  end

  def put_next(payload, tool, args) do
    payload
    |> Map.put(:next_tool, tool)
    |> Map.put(:next_arguments, args)
  end

  def agent_command_next_args(session, params),
    do: compact(%{workspace_id: workspace_id(params), session: session})

  def put_lines(opts, n) when is_integer(n) and n > 0, do: [{:lines, min(n, 5000)} | opts]
  def put_lines(opts, _), do: opts

  def lines_param(params) do
    case Map.get(params, "lines") || Map.get(params, :lines) do
      lines when is_integer(lines) and lines > 0 -> lines
      _ -> nil
    end
  end

  def put_capture_metadata(payload, output, requested_lines) do
    line_count = output |> String.split("\n") |> length()
    requested = if is_integer(requested_lines) and requested_lines > 0, do: requested_lines

    payload
    |> Map.put(:line_count, line_count)
    |> Map.put(:truncated, is_integer(requested) and line_count >= requested)
    |> Map.put(:suggested_next_capture, %{lines: @default_capture_lines, ansi: false})
  end

  def capture_next_args(session, target, params) do
    base = %{
      workspace_id: workspace_id(params),
      session: session,
      lines: @default_capture_lines,
      ansi: false
    }

    if String.starts_with?(target, "%") do
      Map.put(base, :pane, target)
    else
      base
    end
    |> compact()
  end
end
