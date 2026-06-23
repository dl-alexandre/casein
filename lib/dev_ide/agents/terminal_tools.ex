defmodule DevIDE.Agents.TerminalTools do
  @moduledoc """
  Narrow agent-facing tmux operations.

  This is the terminal counterpart to `DevIDE.Agents.PreviewTools`: it lets
  external coding agents (Grok, Claude, Codex, opencode) drive DevIDE's tmux
  sessions the way a human would from the CLI — discover live sessions, read a
  pane's scrollback to debug a server, and send keys/commands — without
  arbitrary shell access on the host.

  Every session-scoped tool is guarded to `devide_`-prefixed sessions
  (`DevIDE.Terminals.Tmux.session_name/2`'s shape), so agents can only see and
  touch DevIDE-managed sessions, never unrelated tmux sessions that happen to
  share the host's tmux server.

  Pass `workspace_id` on every call to scope discovery and mutation to one
  workspace's sessions. After applying the built-in `agent_pair` template, use
  `terminal_topology` and target the `agent` pane explicitly.
  """

  alias DevIDE.Agents.{AnnotationTools, TerminalOutputFormat}
  alias DevIDE.Labels
  alias DevIDE.Runtimes
  alias DevIDE.Terminals.SessionDirectory
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxTopology
  alias DevIDE.Workspaces
  alias McpCtl.{Params, Tool}

  @session_prefix "devide_"

  @type tool :: McpCtl.Tool.t()

  @doc "Tool definitions exposed to agent runtimes."
  @spec definitions() :: [tool()]
  def definitions do
    workspace_props = Params.terminal_workspace_props()

    [
      Tool.define(
        "terminal_list_sessions",
        "List live DevIDE-managed tmux sessions (name, whether a client is " <>
          "attached, last activity). Start here to discover a session name to " <>
          "operate on. Pass `workspace_id` to scope to one workspace. Optional " <>
          "`contains` filters by substring.",
        Tool.object(Map.merge(workspace_props, %{contains: Params.contains()}))
      ),
      Tool.define(
        "terminal_topology",
        "Inspect a session's structure: its windows and panes with geometry, " <>
          "the running command per pane, and which window/pane is active. Use " <>
          "this to find the agent pane id after applying the agent_pair template.",
        Tool.object(Map.merge(workspace_props, %{session: Params.session()}), ["session"])
      ),
      Tool.define(
        "terminal_capture",
        "Capture a pane's scrollback to read a server log or command output. " <>
          "By default reads the session's active pane and full history; pass " <>
          "`pane` (a pane id from terminal_topology, e.g. \"%3\") to read a " <>
          "specific non-focused pane, `lines` to tail only the last N lines, " <>
          "and `ansi: false` (default) for plain text (fewer tokens).",
        Tool.object(
          Map.merge(workspace_props, %{
            session: Params.session(),
            pane: Params.pane(),
            lines: Params.lines(),
            ansi: Params.ansi()
          }),
          ["session"]
        )
      ),
      Tool.define(
        "terminal_agent_pane",
        "Find the dedicated agent pane from the agent_pair template. The MCP URL can " <>
          "pre-scope workspace_id; `session` may be omitted when exactly one workspace " <>
          "session matches. When multiple sessions match, returns ambiguous: true and " <>
          "candidate_sessions. Mutating agent-pane shortcut tools require the agent_pair marker.",
        Tool.object(Map.merge(workspace_props, %{session: Params.session()}))
      ),
      Tool.define(
        "terminal_capture_agent",
        "Capture scrollback from the dedicated agent pane. Avoids reading the operator pane.",
        Tool.object(
          Map.merge(workspace_props, %{
            session: Params.session(),
            lines: Params.lines(),
            ansi: Params.ansi()
          })
        )
      ),
      Tool.define(
        "terminal_send_agent_keys",
        "Send raw keystrokes to the dedicated agent pane only. Requires the agent_pair " <>
          "marker — does not fall back to agent process detection.",
        Tool.object(
          Map.merge(workspace_props, %{session: Params.session(), keys: Params.keys()}),
          ["keys"]
        )
      ),
      Tool.define(
        "terminal_send_agent_command",
        "Type a shell command into the dedicated agent pane and press Enter. " <>
          "Requires the agent_pair marker. Use terminal_send_command for explicit pane ids.",
        Tool.object(
          Map.merge(workspace_props, %{session: Params.session(), command: Params.command()}),
          ["command"]
        )
      ),
      Tool.define(
        "terminal_send_keys",
        "Send raw keystrokes to a pane WITHOUT a trailing Enter. Use tmux key " <>
          "names for control keys (e.g. \"C-c\", \"Up\", \"Enter\"). Defaults to " <>
          "the active pane; pass `pane` to target the agent pane from " <>
          "terminal_topology. For running a shell command, prefer terminal_send_command.",
        Tool.object(
          Map.merge(workspace_props, %{
            session: Params.session(),
            keys: Params.keys(),
            pane: Params.pane()
          }),
          ["session", "keys"]
        )
      ),
      Tool.define(
        "terminal_send_command",
        "Type a shell command into a pane and press Enter. Target the agent " <>
          "pane from terminal_topology — do not use the operator's focused pane. " <>
          "Read the result afterward with terminal_capture.",
        Tool.object(
          Map.merge(workspace_props, %{
            session: Params.session(),
            command: Params.command(),
            pane: Params.pane()
          }),
          ["session", "command"]
        )
      ),
      Tool.define(
        "terminal_set_agent_label",
        "Set a short conversation label for a pane in DevIDE chrome (does not rename " <>
          "tmux windows). Defaults to the dedicated agent pane when pane is omitted. " <>
          "Pass freeze: true to keep the label until the pane closes.",
        Tool.object(
          Map.merge(workspace_props, %{
            session: Params.session(),
            pane: Params.pane(),
            label: %{type: "string"},
            freeze: %{
              type: "boolean",
              description: "When true, keep this label until the pane is closed."
            }
          }),
          ["workspace_id", "label"]
        )
      ),
      Tool.define(
        "terminal_report_worktree",
        "Report an agent-created Git worktree so DevIDE can show it under the " <>
          "owning workspace. Call after creating or switching to a worktree. " <>
          "Requires workspace_id and worktree_path; optional fields include " <>
          "branch, agent, runner_id, session_id, and tmux_session_id.",
        Tool.object(
          Map.merge(workspace_props, %{
            worktree_path: %{type: "string"},
            branch: %{type: "string"},
            agent: %{type: "string"},
            runner_id: %{type: "string"},
            session_id: %{type: "string"},
            tmux_session_id: %{type: "string"}
          }),
          ["workspace_id", "worktree_path"]
        )
      )
    ]
    |> Kernel.++(AnnotationTools.definitions())
  end

  @doc "Dispatch a named agent terminal tool."
  @spec invoke(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(tool_name, params) when is_map(params) do
    case tool_name do
      "terminal_list_sessions" -> list_sessions(params)
      "terminal_topology" -> topology(params)
      "terminal_capture" -> capture(params)
      "terminal_agent_pane" -> agent_pane(params)
      "terminal_capture_agent" -> capture_agent(params)
      "terminal_send_agent_keys" -> send_agent_keys(params)
      "terminal_send_agent_command" -> send_agent_command(params)
      "terminal_send_keys" -> send_keys(params)
      "terminal_send_command" -> send_command(params)
      "terminal_report_worktree" -> report_worktree(params)
      "terminal_set_agent_label" -> set_agent_label(params)
      "annotation_list" -> AnnotationTools.invoke(tool_name, params)
      "annotation_propose" -> AnnotationTools.invoke(tool_name, params)
      _ -> {:error, :unknown_tool}
    end
  end

  @doc "List live DevIDE-managed tmux sessions."
  @spec list_sessions(map()) :: {:ok, map()}
  def list_sessions(params \\ %{}) do
    contains = Map.get(params, "contains") || Map.get(params, :contains)

    sessions =
      tmux().list_sessions()
      |> Enum.filter(&String.starts_with?(&1.session, @session_prefix))
      |> filter_workspace(params)
      |> filter_contains(contains)

    {:ok, compact(%{sessions: sessions, workspace_id: workspace_id(params)})}
  end

  @doc "Return a session's window/pane topology."
  @spec topology(map()) :: {:ok, map()} | {:error, term()}
  def topology(params) do
    with {:ok, session} <- session_arg(params) do
      {:ok, TmuxTopology.snapshot(session, tmux: tmux())}
    end
  end

  @doc "Capture a pane's scrollback for a session (defaults to the active pane)."
  @spec capture(map()) :: {:ok, map()} | {:error, term()}
  def capture(params) do
    with {:ok, session} <- session_arg(params),
         {:ok, target} <- target_arg(session, params) do
      ansi? = Map.get(params, "ansi", false) == true
      opts = [ansi: ansi?] |> put_lines(Map.get(params, "lines"))
      output = tmux().capture_scrollback(target, opts) |> TerminalOutputFormat.format(ansi: ansi?)

      {:ok, %{session: session, target: target, output: output}}
    end
  end

  @doc "Find the dedicated agent pane for a session or scoped workspace."
  @spec agent_pane(map()) :: {:ok, map()} | {:error, term()}
  def agent_pane(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, pane} <- find_agent_pane(session, allow_process_fallback: true) do
      {:ok, %{session: session, pane: pane.id, reason: pane.agent_match}}
    end
  end

  @doc "Capture the dedicated agent pane's scrollback."
  @spec capture_agent(map()) :: {:ok, map()} | {:error, term()}
  def capture_agent(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, pane} <- find_agent_pane(session, allow_process_fallback: true) do
      ansi? = Map.get(params, "ansi", false) == true
      opts = [ansi: ansi?] |> put_lines(Map.get(params, "lines"))

      output =
        session
        |> then(&tmux().capture_scrollback(&1, Keyword.put(opts, :target, pane.id)))
        |> TerminalOutputFormat.format(ansi: ansi?)

      {:ok, %{session: session, target: pane.id, output: output}}
    end
  end

  @doc "Send raw keys to the dedicated agent pane."
  @spec send_agent_keys(map()) :: {:ok, map()} | {:error, term()}
  def send_agent_keys(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, keys} <- string_arg(params, "keys"),
         {:ok, pane} <- find_agent_pane(session, allow_process_fallback: false) do
      case tmux().send_keys(session, keys, target: pane.id) do
        {_out, 0} -> {:ok, %{session: session, target: pane.id, status: "sent"}}
        :ok -> {:ok, %{session: session, target: pane.id, status: "sent"}}
        {:error, reason} -> {:error, reason}
        {out, _code} -> {:error, String.trim(out)}
      end
    end
  end

  @doc "Send a command + Enter to the dedicated agent pane."
  @spec send_agent_command(map()) :: {:ok, map()} | {:error, term()}
  def send_agent_command(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, command} <- string_arg(params, "command"),
         {:ok, pane} <- find_agent_pane(session, allow_process_fallback: false) do
      case tmux().send_command(session, command, target: pane.id) do
        :ok -> {:ok, %{session: session, target: pane.id, status: "sent"}}
        {:error, reason} -> {:error, reason}
        {out, _code} -> {:error, String.trim(out)}
      end
    end
  end

  @doc "Send raw keys to a pane (defaults to the active pane)."
  @spec send_keys(map()) :: {:ok, map()} | {:error, term()}
  def send_keys(params) do
    with {:ok, session} <- session_arg(params),
         {:ok, keys} <- string_arg(params, "keys"),
         {:ok, target} <- target_arg(session, params) do
      case tmux().send_keys(target, keys) do
        {_out, 0} -> {:ok, %{session: session, target: target, status: "sent"}}
        {out, _code} -> {:error, String.trim(out)}
      end
    end
  end

  @doc "Send a command + Enter to a pane (defaults to the active pane)."
  @spec send_command(map()) :: {:ok, map()} | {:error, term()}
  def send_command(params) do
    with {:ok, session} <- session_arg(params),
         {:ok, command} <- string_arg(params, "command"),
         {:ok, target} <- target_arg(session, params) do
      case tmux().send_command(target, command) do
        :ok -> {:ok, %{session: session, target: target, status: "sent"}}
        {:error, reason} -> {:error, reason}
        {out, _code} -> {:error, String.trim(out)}
      end
    end
  end

  @doc "Set a DevIDE chrome label for an agent pane."
  @spec set_agent_label(map()) :: {:ok, map()} | {:error, term()}
  def set_agent_label(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, session} <- session_or_default_arg(params),
         {:ok, label} <- string_arg(params, "label"),
         {:ok, pane} <- label_target_pane(session, params) do
      freeze? = truthy?(Map.get(params, "freeze") || Map.get(params, :freeze))

      :ok =
        Labels.set_agent_label(workspace_id, session, pane.id, label, freeze: freeze?)

      {:ok,
       %{
         session: session,
         target: pane.id,
         label: label,
         frozen: freeze?,
         status: "set"
       }}
    end
  end

  @doc "Report an agent-created Git worktree for workspace-local UX."
  @spec report_worktree(map()) :: {:ok, map()} | {:error, term()}
  def report_worktree(params) do
    case workspace_id(params) do
      id when is_binary(id) ->
        with {:ok, runtime} <- Runtimes.observe_worktree(id, params) do
          :ok = SessionDirectory.refresh_worktrees(id)
          {:ok, %{workspace_id: id, worktree: Runtimes.payload(runtime)}}
        end

      _ ->
        {:error, :workspace_id_required}
    end
  end

  defp session_arg(params) do
    with {:ok, session} <- string_arg(params, "session"), do: validate_session(session, params)
  end

  defp session_or_default_arg(params) do
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
        {:error, ambiguous_sessions_error(sessions)}
    end
  end

  defp target_arg(session, params) do
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

  defp find_agent_pane(session, opts) do
    allow_process_fallback = Keyword.get(opts, :allow_process_fallback, true)
    panes = tmux().list_session_panes(session)

    pane =
      marker_agent_pane(session, panes) ||
        if(allow_process_fallback, do: process_agent_pane(panes), else: nil)

    case pane do
      nil ->
        message =
          if allow_process_fallback do
            "Apply the agent_pair template, then retry. Refusing to target the operator pane."
          else
            "Apply the agent_pair template before using terminal_send_agent_* tools."
          end

        {:error,
         %{
           error: :agent_pane_not_found,
           message: message,
           candidate_panes:
             Enum.map(panes, &Map.take(&1, [:id, :active, :current_command, :current_path]))
         }}

      pane ->
        {:ok, pane}
    end
  end

  defp marker_agent_pane(session, panes) do
    Enum.find_value(panes, fn pane ->
      if pane_has_agent_marker?(session, pane),
        do: Map.put(pane, :agent_match, "agent_pair_marker")
    end)
  end

  defp process_agent_pane(panes) do
    Enum.find_value(panes, fn pane ->
      if agent_process?(pane), do: Map.put(pane, :agent_match, "agent_process")
    end)
  end

  defp pane_has_agent_marker?(session, %{id: pane_id}) do
    session
    |> then(&tmux().capture_scrollback(&1, target: pane_id, lines: 50, ansi: false))
    |> String.contains?("DevIDE agent pane")
  end

  defp agent_process?(%{current_command: command}) when is_binary(command) do
    command = String.downcase(command)
    Enum.any?(~w(claude grok codex opencode), &String.contains?(command, &1))
  end

  defp agent_process?(_), do: false

  defp put_lines(opts, n) when is_integer(n) and n > 0, do: [{:lines, min(n, 5000)} | opts]
  defp put_lines(opts, _), do: opts

  defp workspace_id_arg(params) do
    case workspace_id(params) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :missing_workspace_id}
    end
  end

  defp label_target_pane(session, params) do
    case Map.get(params, "pane") || Map.get(params, :pane) do
      pane_id when is_binary(pane_id) and pane_id != "" ->
        if pane_id in pane_ids(session), do: {:ok, %{id: pane_id}}, else: {:error, :invalid_pane}

      _ ->
        find_agent_pane(session, allow_process_fallback: true)
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp string_arg(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_argument, key}}
    end
  end

  defp workspace_id(params) do
    case Map.get(params, "workspace_id") || Map.get(params, :workspace_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp workspace_matches?(session, params) do
    case workspace_prefixes(params) do
      [] -> true
      prefixes -> Enum.any?(prefixes, &String.starts_with?(session, &1))
    end
  end

  defp filter_workspace(sessions, params) do
    case workspace_prefixes(params) do
      [] ->
        sessions

      prefixes ->
        Enum.filter(sessions, fn %{session: name} ->
          Enum.any?(prefixes, &String.starts_with?(name, &1))
        end)
    end
  end

  defp sessions_for(params) do
    tmux().list_sessions()
    |> Enum.filter(&String.starts_with?(&1.session, @session_prefix))
    |> filter_workspace(params)
  end

  defp ambiguous_sessions_error(sessions) do
    %{
      error: :ambiguous_workspace_sessions,
      ambiguous: true,
      message: "Multiple workspace sessions match. Pass session explicitly.",
      candidate_sessions: Enum.map(sessions, &session_candidate/1)
    }
  end

  defp session_candidate(%{session: name} = session) do
    %{
      session: name,
      attached: Map.get(session, :attached),
      activity: Map.get(session, :activity)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

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

  defp filter_contains(sessions, nil), do: sessions
  defp filter_contains(sessions, ""), do: sessions

  defp filter_contains(sessions, needle) when is_binary(needle),
    do: Enum.filter(sessions, &String.contains?(&1.session, needle))

  defp tmux, do: Application.get_env(:dev_ide, :tmux_adapter, Tmux)

  defp session_exists?(session) do
    adapter = tmux()
    Code.ensure_loaded(adapter)

    cond do
      function_exported?(adapter, :session_exists?, 1) -> adapter.session_exists?(session)
      function_exported?(adapter, :session_alive?, 1) -> adapter.session_alive?(session)
      true -> false
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
