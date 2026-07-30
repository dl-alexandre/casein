defmodule Casein.Agents.TerminalTools.Impl.Agent do
  @moduledoc false

  alias Casein.Agents.{TerminalOutputFormat, Transcripts}
  alias Casein.AgentSessions.GrokACP.Attachments
  alias Casein.Labels
  alias Casein.Mobile.Clarification
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.TmuxTopology

  import Casein.Agents.TerminalTools.Impl.Shared

  @default_capture_lines 120

  @doc "Find the dedicated agent pane for a session or scoped workspace."
  @spec agent_pane(map()) :: {:ok, map()} | {:error, term()}
  def agent_pane(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, pane} <- find_agent_pane(session, params, allow_process_fallback: true) do
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
         {:ok, pane} <- find_agent_pane(session, params, allow_process_fallback: true) do
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
         {:ok, pane} <- find_agent_pane(session, params, allow_process_fallback: false) do
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
         {:ok, pane} <- find_agent_pane(session, params, allow_process_fallback: false) do
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
         {:ok, pane} <- find_agent_pane(session, params, allow_process_fallback: false) do
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

  @doc "Create a durable clarification request for an exact role-marked agent pane."
  @spec request_clarification(map()) :: {:ok, map()} | {:error, term()}
  def request_clarification(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, session} <- session_or_default_arg(params),
         {:ok, pane_id} <- string_arg(params, "pane"),
         {:ok, request_id} <- string_arg(params, "request_id"),
         {:ok, agent_session_id} <- string_arg(params, "agent_session_id"),
         {:ok, question} <- string_arg(params, "question"),
         {:ok, event, status} <-
           Clarification.request(%{
             workspace_id: workspace_id,
             tmux_session_id: session,
             pane_id: pane_id,
             request_id: request_id,
             agent_session_id: agent_session_id,
             question: question
           }) do
      {:ok,
       %{
         request_event_id: event.id,
         revision: event.id,
         session: session,
         target: pane_id,
         target_role: "agent",
         status: if(status == :inserted, do: "created", else: "duplicate")
       }}
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

  @doc "Set a Casein chrome label for an agent pane."
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
         {:ok, pane} <- label_target_pane(session, params, :other) do
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
    Application.get_env(:casein, :agent_state_wait_recheck_ms, 1_000)
  end

  # Default target when `pane` is omitted. `:self` tools (labels, state
  # reports, transcripts) act on the calling agent's own pane when the caller
  # is known; `:other` tools (waiting on a peer) must never resolve to self.
  defp label_target_pane(session, params, default \\ :self) do
    panes = tmux().list_session_panes(session)

    case Map.get(params, "pane") || Map.get(params, :pane) do
      pane_id when is_binary(pane_id) and pane_id != "" ->
        case Enum.find(panes, &(&1.id == pane_id)) do
          nil -> {:error, :invalid_pane}
          pane -> {:ok, pane}
        end

      _ ->
        caller = caller_pane(params)
        caller_pane_struct = if default == :self, do: Enum.find(panes, &(&1.id == caller))

        if caller_pane_struct do
          {:ok, caller_pane_struct}
        else
          find_agent_pane(session, params, allow_process_fallback: true)
        end
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
end
