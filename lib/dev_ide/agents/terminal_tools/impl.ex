defmodule DevIDE.Agents.TerminalTools.Impl do
  @moduledoc false

  alias DevIDE.Agents.{AgentPane, PaneEnv, TerminalOutputFormat, Transcripts}
  alias DevIDE.AgentSessions.GrokACP.Attachments
  alias DevIDE.Audit
  alias DevIDE.Export.Sanitizer
  alias DevIDE.Labels
  alias DevIDE.Operator.SituationServer
  alias DevIDE.Runtimes
  alias DevIDE.Runtimes.Runtime
  alias DevIDE.Terminals.AgentState
  alias DevIDE.Terminals.SessionDirectory
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxTopology
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.Scratch
  alias DevIDE.Workspaces.State

  @session_prefix "devide_"
  @default_capture_lines 120

  @doc "List live DevIDE-managed tmux sessions."
  @spec list_sessions(map()) :: {:ok, map()}
  def list_sessions(params \\ %{}) do
    contains = Map.get(params, "contains") || Map.get(params, :contains)

    sessions =
      tmux().list_sessions()
      |> Enum.filter(&String.starts_with?(&1.session, @session_prefix))
      |> filter_workspace(params)
      |> filter_contains(contains)

    {:ok,
     %{sessions: sessions, workspace_id: workspace_id(params)}
     |> put_session_guidance(params, sessions)
     |> compact()}
  end

  @doc "Return a self-routing terminal context for agent planning."
  @spec context(map()) :: {:ok, map()} | {:error, term()}
  def context(params \\ %{}) do
    sessions = sessions_for(params)

    case session_or_default_arg(params) do
      {:ok, session} ->
        snapshot = enriched_snapshot(session)

        payload =
          %{
            workspace_id: workspace_id(params),
            sessions: Enum.map(sessions, &session_candidate/1),
            recommended_session: session,
            topology: snapshot
          }
          |> put_agent_pane_guidance(session, params)
          |> compact()

        {:ok, payload}

      {:error, %{error: :ambiguous_workspace_sessions} = error} ->
        {:ok,
         error
         |> Map.put(:workspace_id, workspace_id(params))
         |> Map.put(:sessions, error.candidate_sessions)
         |> Map.put(:safe_to_mutate, false)
         |> put_ambiguous_recommendation(params)}

      {:error, :no_workspace_sessions} ->
        {:ok,
         %{
           workspace_id: workspace_id(params),
           sessions: [],
           safe_to_mutate: false,
           reason: "no_workspace_sessions",
           next_tool: "terminal_list_sessions",
           next_arguments: compact(%{workspace_id: workspace_id(params)})
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Return a session's window/pane topology."
  @spec topology(map()) :: {:ok, map()} | {:error, term()}
  def topology(params) do
    with {:ok, session} <- session_arg(params) do
      payload =
        session
        |> enriched_snapshot()
        |> put_agent_pane_guidance(session, params)

      {:ok, payload}
    end
  end

  # Direct tmux snapshot plus the semantic agent-state layer. The watcher path
  # (`TmuxTopology.get/2`) stays heuristic-only; enriching here keeps reported
  # :blocked/:done/:idle states visible to MCP consumers without touching it.
  defp enriched_snapshot(session) do
    session
    |> TmuxTopology.snapshot(tmux: tmux())
    |> AgentState.enrich_topology(session)
  end

  @doc "Capture a pane's scrollback for a session (defaults to the active pane)."
  @spec capture(map()) :: {:ok, map()} | {:error, term()}
  def capture(params) do
    with {:ok, session} <- session_arg(params),
         {:ok, target} <- target_arg(session, params) do
      ansi? = Map.get(params, "ansi", false) == true
      opts = [ansi: ansi?] |> put_lines(lines_param(params))
      output = tmux().capture_scrollback(target, opts) |> TerminalOutputFormat.format(ansi: ansi?)

      {:ok,
       %{session: session, target: target, output: output}
       |> put_capture_metadata(output, lines_param(params))
       |> put_next("terminal_capture", capture_next_args(session, target, params))}
    end
  end

  @doc "Find the dedicated agent pane for a session or scoped workspace."
  @spec agent_pane(map()) :: {:ok, map()} | {:error, term()}
  def agent_pane(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, pane} <- find_agent_pane(session, allow_process_fallback: true) do
      {:ok,
       %{
         session: session,
         pane: pane.id,
         reason: pane.agent_match,
         safe_to_mutate: pane.agent_match == "agent_pair_marker"
       }
       |> put_next("terminal_send_agent_command", agent_command_next_args(session, params))}
    end
  end

  @doc "Read the dedicated agent pane's live CLI transcript."
  @spec agent_transcript(map()) :: {:ok, map()} | {:error, term()}
  def agent_transcript(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, pane} <- label_target_pane(session, params),
         {:ok, path} <- transcript_path_for(session, pane.id),
         {:ok, transcript} <-
           Transcripts.read(path,
             since: string_param(params, "since"),
             tail: tail_param(params),
             full_text: truthy?(Map.get(params, "full_text") || Map.get(params, :full_text))
           ) do
      {:ok,
       %{
         session: session,
         target: pane.id,
         transcript_path: path,
         entries: transcript.entries,
         cursor: transcript.cursor,
         total_on_branch: transcript.total_on_branch
       }
       |> put_next("terminal_agent_transcript", transcript_next_args(session, pane.id, params))}
    end
  end

  @doc "Capture the dedicated agent pane's scrollback."
  @spec capture_agent(map()) :: {:ok, map()} | {:error, term()}
  def capture_agent(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, pane} <- find_agent_pane(session, allow_process_fallback: true) do
      ansi? = Map.get(params, "ansi", false) == true
      requested_lines = lines_param(params) || @default_capture_lines
      opts = [ansi: ansi?] |> put_lines(requested_lines)

      output =
        session
        |> then(&tmux().capture_scrollback(&1, Keyword.put(opts, :target, pane.id)))
        |> TerminalOutputFormat.format(ansi: ansi?)

      {:ok,
       %{session: session, target: pane.id, output: output}
       |> put_capture_metadata(output, requested_lines)
       |> put_next("terminal_send_agent_command", agent_command_next_args(session, params))}
    end
  end

  @doc "Send raw keys to the dedicated agent pane."
  @spec send_agent_keys(map()) :: {:ok, map()} | {:error, term()}
  def send_agent_keys(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, keys} <- string_arg(params, "keys"),
         {:ok, pane} <- find_agent_pane(session, allow_process_fallback: false) do
      case tmux().send_keys(session, keys, target: pane.id) do
        {_out, 0} -> {:ok, sent_payload(session, pane.id, "terminal_capture_agent", params)}
        :ok -> {:ok, sent_payload(session, pane.id, "terminal_capture_agent", params)}
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
        :ok ->
          report_dispatch_working(
            params,
            session,
            pane.id,
            command,
            "terminal_send_agent_command"
          )

          {:ok, sent_payload(session, pane.id, "terminal_capture_agent", params)}

        {:error, reason} ->
          {:error, reason}

        {out, _code} ->
          {:error, String.trim(out)}
      end
    end
  end

  @doc "Paste literal text into the dedicated agent pane."
  @spec paste_agent_text(map()) :: {:ok, map()} | {:error, term()}
  def paste_agent_text(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, text} <- string_arg(params, "text"),
         {:ok, pane} <- find_agent_pane(session, allow_process_fallback: false) do
      submit? = truthy?(Map.get(params, "submit") || Map.get(params, :submit))
      opts = [target: pane.id, submit: submit?]

      case tmux().paste_text(session, text, opts) do
        :ok ->
          if submit? do
            report_dispatch_working(params, session, pane.id, text, "terminal_paste_agent_text")
          end

          {:ok, sent_payload(session, pane.id, "terminal_capture_agent", params)}

        {:error, reason} ->
          {:error, reason}

        {out, _code} ->
          {:error, String.trim(out)}
      end
    end
  end

  # Runtime-agnostic `working` edge: dispatching work into the agent pane means
  # the agent is working, regardless of whether its runtime reports state
  # hooks. Codex has no turn-start notify event, so without this its panes sit
  # at their last state until the turn-complete report; Claude/Grok hook
  # reports simply land moments later and supersede this one.
  defp report_dispatch_working(params, session, pane_id, message, tool) do
    AgentState.report(workspace_id(params), session, pane_id, :working, message,
      source: :dispatch,
      tool: tool
    )
  end

  @doc "Send raw keys to a pane (defaults to the active pane)."
  @spec send_keys(map()) :: {:ok, map()} | {:error, term()}
  def send_keys(params) do
    with {:ok, session} <- session_arg(params),
         {:ok, keys} <- string_arg(params, "keys"),
         {:ok, target} <- target_arg(session, params) do
      case tmux().send_keys(target, keys) do
        {_out, 0} -> {:ok, raw_sent_payload(session, target, params)}
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
        :ok -> {:ok, raw_sent_payload(session, target, params)}
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

  @doc "Record an explicit semantic-state report for an agent pane."
  @spec report_agent_state(map()) :: {:ok, map()} | {:error, term()}
  def report_agent_state(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, session} <- session_or_default_arg(params),
         {:ok, state} <- agent_state_arg(params),
         {:ok, pane} <- label_target_pane(session, params) do
      message = truncated_message(params)

      transcript_path = string_param(params, "transcript_path")
      agent_session_id = string_param(params, "agent_session_id")
      agent_runtime = string_param(params, "agent_runtime")
      grok_leader_socket = string_param(params, "grok_leader_socket")
      grok_bundle_dir = string_param(params, "grok_bundle_dir")
      grok_bundle_digest = string_param(params, "grok_bundle_digest")
      report_source = agent_state_source(params)

      attachment = %{
        workspace_id: workspace_id,
        tmux_session_id: session,
        pane_id: pane.id,
        cwd: pane_current_path(pane),
        transcript_path: transcript_path,
        agent_session_id: agent_session_id,
        agent_runtime: agent_runtime,
        source: report_source,
        grok_leader_socket: grok_leader_socket,
        grok_bundle_dir: grok_bundle_dir,
        grok_bundle_digest: grok_bundle_digest
      }

      with :ok <- validate_grok_attachment(agent_runtime, attachment) do
        :ok =
          AgentState.report(workspace_id, session, pane.id, state, message,
            source: report_source,
            tool: "terminal_report_agent_state",
            transcript_path: transcript_path,
            agent_session_id: agent_session_id
          )

        {:ok,
         %{
           session: session,
           target: pane.id,
           state: Atom.to_string(state),
           message: message,
           transcript_path: transcript_path,
           agent_session_id: agent_session_id,
           agent_runtime: agent_runtime,
           grok_leader_socket: grok_leader_socket,
           grok_bundle_dir: grok_bundle_dir,
           grok_bundle_digest: grok_bundle_digest,
           status: "reported"
         }}
      end
    end
  end

  defp validate_grok_attachment("grok", attrs) do
    case Attachments.observe(attrs) do
      :ok -> :ok
      :disabled -> :ok
      {:error, reason} -> {:error, {:invalid_grok_attachment, reason}}
    end
  end

  defp validate_grok_attachment(_runtime, _attrs), do: :ok

  @doc "Block until an agent pane reaches one of the requested semantic states."
  @spec wait_agent_state(map()) :: {:ok, map()} | {:error, term()}
  def wait_agent_state(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, session} <- session_or_default_arg(params),
         {:ok, states} <- wait_states_arg(params),
         {:ok, pane} <- label_target_pane(session, params) do
      timeout_ms = clamped_timeout(params)
      :ok = AgentState.subscribe(workspace_id)
      started = System.monotonic_time(:millisecond)

      {state, message, matched} =
        await_agent_state(session, pane.id, states, started + timeout_ms)

      {:ok,
       %{
         session: session,
         target: pane.id,
         state: Atom.to_string(state),
         message: message,
         matched: matched,
         timed_out: not matched,
         waited_ms: System.monotonic_time(:millisecond) - started
       }
       |> put_wait_answer(session, pane.id, state, matched, params)}
    end
  end

  defp put_wait_answer(payload, session, pane_id, :done, true, params) do
    if truthy?(Map.get(params, "include_answer") || Map.get(params, :include_answer)) do
      case transcript_answer(session, pane_id) do
        answer when is_binary(answer) -> Map.put(payload, :answer, answer)
        _ -> payload
      end
    else
      payload
    end
  end

  defp put_wait_answer(payload, _session, _pane_id, _state, _matched, _params), do: payload

  defp transcript_answer(session, pane_id) do
    case AgentState.get(session, pane_id) do
      %{transcript_path: path} when is_binary(path) and path != "" ->
        Transcripts.final_assistant_message(path)

      _ ->
        nil
    end
  end

  defp await_agent_state(session, pane_id, states, deadline) do
    {state, message} = current_agent_state(session, pane_id)
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      state in states ->
        {state, message, true}

      remaining <= 0 ->
        {state, message, false}

      true ->
        recheck = min(remaining, agent_state_recheck_ms())

        receive do
          {:agent_state_updated, ^session, ^pane_id, _entry} ->
            await_agent_state(session, pane_id, states, deadline)
        after
          recheck ->
            await_agent_state(session, pane_id, states, deadline)
        end
    end
  end

  defp current_agent_state(session, pane_id) do
    AgentState.resolve(AgentState.get(session, pane_id), agent_pane_heuristic(session, pane_id))
  end

  # Prefer the cached watcher topology (300ms refresh while observed) over a fresh
  # tmux read on every recheck.
  defp agent_pane_heuristic(session, pane_id) do
    topology = TmuxTopology.get(session)

    case Enum.find(topology.panes, fn pane -> pane_id_of(pane) == pane_id end) do
      nil -> :unknown
      pane -> Map.get(pane, :pane_state) || :unknown
    end
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  defp pane_id_of(pane), do: Map.get(pane, :id) || Map.get(pane, "id")

  defp agent_state_recheck_ms do
    Application.get_env(:dev_ide, :agent_state_wait_recheck_ms, 1_000)
  end

  @doc """
  The operator situation digest for the scoped workspace — served from the
  live `SituationServer` when `:situation_server` is on, cold-built otherwise.
  """
  @spec workspace_digest(map()) :: {:ok, map()} | {:error, term()}
  def workspace_digest(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params) do
      SituationServer.get_digest(workspace_id)
    end
  end

  @doc "Report an agent-created Git worktree for workspace-local UX."
  @spec report_worktree(map()) :: {:ok, map()} | {:error, term()}
  def report_worktree(params) do
    case workspace_id(params) do
      id when is_binary(id) ->
        with {:ok, runtime} <- Runtimes.observe_worktree(id, params),
             :ok <- refresh_reported_worktree_env(runtime, params) do
          :ok = SessionDirectory.refresh_worktrees(id)
          {:ok, %{workspace_id: id, worktree: Runtimes.payload(runtime)}}
        end

      _ ->
        {:error, :workspace_id_required}
    end
  end

  @doc """
  Record a pre-push gate run verdict as a durable `gate.passed` /
  `gate.failed` audit row. Called (fail-open) by scripts/pre-push-check.sh;
  the MCP layer additionally persists the tool call itself since gate_report
  is classified mutating in `DevIDE.Agents.MCPAudit`.
  """
  @spec gate_report(map()) :: {:ok, map()} | {:error, term()}
  def gate_report(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, passed} <- gate_passed_arg(params) do
      action = if passed, do: "gate.passed", else: "gate.failed"

      _ =
        Audit.emit!(%{
          workspace_id: workspace_id,
          actor_id: "pre_push_gate",
          action: action,
          source: "gate",
          target_type: "git_sha",
          target_ref: string_param(params, "sha"),
          metadata: gate_metadata(params)
        })

      {:ok, %{workspace_id: workspace_id, action: action, recorded: true}}
    end
  end

  # `false` is a legitimate (and load-bearing) value — no `||` fallback here.
  defp gate_passed_arg(params) do
    cond do
      is_boolean(Map.get(params, "passed")) -> {:ok, Map.get(params, "passed")}
      is_boolean(Map.get(params, :passed)) -> {:ok, Map.get(params, :passed)}
      true -> {:error, :passed_required}
    end
  end

  defp gate_metadata(params) do
    %{
      branch: string_param(params, "branch"),
      sha: string_param(params, "sha"),
      duration_s: number_param(params, "duration_s"),
      # Free text destined for a persisted row — redact like every other
      # exported string.
      failed_step: redact(string_param(params, "failed_step"))
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp number_param(params, key) do
    case Map.get(params, key) do
      value when is_number(value) -> value
      _ -> nil
    end
  end

  defp redact(value) when is_binary(value), do: Sanitizer.redact_text(value)
  defp redact(value), do: value

  defp refresh_reported_worktree_env(%Runtime{} = runtime, params) do
    case string_param(params, "tmux_session_id") do
      nil ->
        :ok

      _reported_session ->
        tmux_session = runtime.tmux_session_id
        workspace = runtime_env_workspace(runtime)

        PaneEnv.ensure_for_session(tmux_session, workspace, checkout: runtime.worktree_path)
    end
  end

  defp runtime_env_workspace(%Runtime{} = runtime) do
    base =
      case State.get(runtime.workspace_id) do
        {:ok, record} ->
          %{
            id: record.external_id,
            name: record.name || record.external_id,
            path: record.host_path
          }

        :error ->
          %{id: runtime.workspace_id, name: runtime.workspace_id, path: nil}
      end

    %{base | path: runtime.worktree_path || base.path}
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
    AgentPane.find(session, tmux(), opts)
  end

  defp put_lines(opts, n) when is_integer(n) and n > 0, do: [{:lines, min(n, 5000)} | opts]
  defp put_lines(opts, _), do: opts

  defp lines_param(params) do
    case Map.get(params, "lines") || Map.get(params, :lines) do
      lines when is_integer(lines) and lines > 0 -> lines
      _ -> nil
    end
  end

  defp workspace_id_arg(params) do
    case workspace_id(params) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :missing_workspace_id}
    end
  end

  defp label_target_pane(session, params) do
    panes = tmux().list_session_panes(session)

    case Map.get(params, "pane") || Map.get(params, :pane) do
      pane_id when is_binary(pane_id) and pane_id != "" ->
        case Enum.find(panes, &(&1.id == pane_id)) do
          nil -> {:error, :invalid_pane}
          pane -> {:ok, pane}
        end

      _ ->
        find_agent_pane(session, allow_process_fallback: true)
    end
  end

  defp pane_current_path(pane) do
    case Map.get(pane, :current_path) || Map.get(pane, "current_path") do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp agent_state_arg(params) do
    case parse_agent_state(Map.get(params, "state") || Map.get(params, :state)) do
      :error -> {:error, :invalid_state}
      state -> {:ok, state}
    end
  end

  defp wait_states_arg(params) do
    case Map.get(params, "states") || Map.get(params, :states) do
      states when is_list(states) and states != [] ->
        parsed = Enum.map(states, &parse_agent_state/1)
        if :error in parsed, do: {:error, :invalid_state}, else: {:ok, Enum.uniq(parsed)}

      _ ->
        {:error, :invalid_states}
    end
  end

  defp parse_agent_state("working"), do: :working
  defp parse_agent_state("blocked"), do: :blocked
  defp parse_agent_state("done"), do: :done
  defp parse_agent_state("idle"), do: :idle
  defp parse_agent_state(_), do: :error

  defp agent_state_source(params) do
    case Map.get(params, "source") || Map.get(params, :source) do
      "hook" -> :hook
      _ -> :mcp
    end
  end

  defp truncated_message(params) do
    case string_param(params, "message") do
      nil -> nil
      message -> String.slice(message, 0, 200)
    end
  end

  defp transcript_path_for(session, pane_id) do
    case AgentState.get(session, pane_id) do
      %{transcript_path: path} when is_binary(path) and path != "" ->
        if Transcripts.allowed_path?(path),
          do: {:ok, path},
          else: {:error, :invalid_transcript_path}

      _ ->
        {:error, :no_transcript}
    end
  end

  defp tail_param(params) do
    case Map.get(params, "tail") || Map.get(params, :tail) do
      tail when is_integer(tail) and tail > 0 -> min(tail, 200)
      _ -> 30
    end
  end

  defp transcript_next_args(session, pane_id, params) do
    compact(%{
      workspace_id: workspace_id(params),
      session: session,
      pane: pane_id,
      since: string_param(params, "since")
    })
  end

  defp clamped_timeout(params) do
    case Map.get(params, "timeout_ms") || Map.get(params, :timeout_ms) do
      ms when is_integer(ms) -> ms |> max(0) |> min(55_000)
      _ -> 30_000
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp string_arg(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_argument, key}}
    end
  end

  defp string_param(params, key) do
    case Map.get(params, key) || Map.get(params, atom_key(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp atom_key("tmux_session_id"), do: :tmux_session_id
  defp atom_key("workspace_id"), do: :workspace_id
  defp atom_key("session"), do: :session
  defp atom_key("pane"), do: :pane
  defp atom_key("freeze"), do: :freeze
  defp atom_key(_), do: nil

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
        # Unscoped MCP listing must not leak synthetic scratch shells
        # (`devide___scratch___*`). Scoped workspace_id calls already exclude
        # them via prefix matching.
        Enum.reject(sessions, &scratch_session?/1)

      prefixes ->
        Enum.filter(sessions, fn %{session: name} ->
          Enum.any?(prefixes, &String.starts_with?(name, &1))
        end)
    end
  end

  defp scratch_session?(%{session: name}) when is_binary(name) do
    String.starts_with?(name, Tmux.workspace_session_prefix(Scratch.id()))
  end

  defp scratch_session?(_), do: false

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
      candidate_sessions: Enum.map(sessions, &session_candidate/1),
      safe_to_mutate: false,
      next_tool: "terminal_context"
    }
  end

  # Ambiguity stays safe-by-default (never an implicit mutation target), but
  # agents still need a starting point: the operator's attached session beats
  # any detached leftover, and recency breaks the remaining ties.
  defp put_ambiguous_recommendation(payload, params) do
    case recommend_session(payload.candidate_sessions) do
      {session, reason} ->
        payload
        |> Map.put(:recommended_session, session)
        |> Map.put(:recommendation_reason, reason)
        |> Map.put(
          :next_arguments,
          compact(%{workspace_id: workspace_id(params), session: session})
        )

      nil ->
        payload
    end
  end

  defp recommend_session(candidates) do
    {pool, reason} =
      case Enum.filter(candidates, &(Map.get(&1, :attached) == true)) do
        [] -> {candidates, "most_recent_activity"}
        [only] -> {[only], "only_attached_session"}
        attached -> {attached, "most_recently_active_attached_session"}
      end

    case Enum.max_by(pool, &(Map.get(&1, :activity) || 0), fn -> nil end) do
      %{session: session} -> {session, reason}
      _ -> nil
    end
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

  defp put_session_guidance(payload, params, [session]) do
    session_name = session.session

    payload
    |> Map.put(:recommended_session, session_name)
    |> put_next(
      "terminal_context",
      compact(%{workspace_id: workspace_id(params), session: session_name})
    )
  end

  defp put_session_guidance(payload, _params, []),
    do: Map.merge(payload, %{safe_to_mutate: false, reason: "no_workspace_sessions"})

  defp put_session_guidance(payload, _params, sessions) do
    Map.merge(payload, %{
      ambiguous: true,
      safe_to_mutate: false,
      reason: "multiple_sessions",
      candidate_sessions: Enum.map(sessions, &session_candidate/1),
      next_tool: "terminal_context"
    })
  end

  defp put_agent_pane_guidance(payload, session, params) do
    case find_agent_pane(session, allow_process_fallback: false) do
      {:ok, pane} ->
        payload
        |> Map.put(:recommended_session, session)
        |> Map.put(:recommended_agent_pane, pane.id)
        |> Map.put(:agent_pane_reason, pane.agent_match)
        |> Map.put(:safe_to_mutate, true)
        |> put_next("terminal_send_agent_command", agent_command_next_args(session, params))

      {:error, reason} ->
        payload
        |> Map.put(:recommended_session, session)
        |> Map.put(:safe_to_mutate, false)
        |> Map.put(:reason, "agent_pair_marker_not_found")
        |> Map.put(:agent_pane_error, error_label(reason))
        |> put_next(
          "terminal_agent_pane",
          compact(%{workspace_id: workspace_id(params), session: session})
        )
    end
  end

  defp put_next(payload, tool, args) do
    payload
    |> Map.put(:next_tool, tool)
    |> Map.put(:next_arguments, args)
  end

  defp sent_payload(session, target, next_tool, params) do
    %{session: session, target: target, status: "sent", safe_to_mutate: true}
    |> put_next(
      next_tool,
      compact(%{
        workspace_id: workspace_id(params),
        session: session,
        lines: @default_capture_lines,
        ansi: false
      })
    )
  end

  defp raw_sent_payload(session, target, params) do
    payload =
      %{session: session, target: target, status: "sent"}
      |> put_next("terminal_capture", capture_next_args(session, target, params))

    if pane_arg_present?(params) do
      Map.put(payload, :safe_to_mutate, true)
    else
      Map.merge(payload, %{
        safe_to_mutate: false,
        target_was_active_pane: true,
        targeting_warning:
          "No pane was supplied; tmux targeted the session active pane. Prefer terminal_send_agent_command or pass an explicit pane id."
      })
    end
  end

  defp put_capture_metadata(payload, output, requested_lines) do
    line_count = output |> String.split("\n") |> length()
    requested = if is_integer(requested_lines) and requested_lines > 0, do: requested_lines

    payload
    |> Map.put(:line_count, line_count)
    |> Map.put(:truncated, is_integer(requested) and line_count >= requested)
    |> Map.put(:suggested_next_capture, %{lines: @default_capture_lines, ansi: false})
  end

  defp capture_next_args(session, target, params) do
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

  defp agent_command_next_args(session, params),
    do: compact(%{workspace_id: workspace_id(params), session: session})

  defp pane_arg_present?(params) do
    case Map.get(params, "pane") || Map.get(params, :pane) do
      pane when is_binary(pane) and pane != "" -> true
      _ -> false
    end
  end

  defp error_label(%{error: error}), do: to_string(error)
end
