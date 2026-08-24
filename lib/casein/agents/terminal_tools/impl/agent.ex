defmodule Casein.Agents.TerminalTools.Impl.Agent do
  @moduledoc false

  alias Casein.Agents.{AuthProfile, Inbox, TerminalOutputFormat, Transcripts}
  alias Casein.Agents.Inbox.Address
  alias Casein.AgentSessions.GrokACP.Attachments
  alias Casein.Labels
  alias Casein.Mobile.Clarification
  alias Casein.Runs.AgentLifecycle
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.IssueBinding
  alias Casein.Terminals.NextPrompt
  alias Casein.Terminals.PaneProcessLiveness
  alias Casein.Terminals.PaneSubmit
  alias Casein.Terminals.PaneWriteReceipt
  alias Casein.Terminals.TmuxTopology
  alias Casein.Terminals.WorkHandles

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
       |> put_pending_next_prompt(session, pane.id)
       |> put_next("terminal_send_agent_command", agent_command_next_args(session, params))}
    end
  end

  @doc "Read the dedicated agent pane's live CLI transcript."
  @spec agent_transcript(map()) :: {:ok, map()} | {:error, term()}
  def agent_transcript(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, pane} <- label_target_pane(session, params),
         {:ok, path} <- transcript_path_for(session, pane, params),
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

          note_lifecycle_send_command(
            params,
            session,
            pane.id,
            command,
            "terminal_send_agent_command"
          )

          confirm_sent(session, pane.id, params, enter_already_sent: true)

        {:error, reason} ->
          {:error, reason}

        {out, _code} ->
          {:error, String.trim(out)}
      end
    end
  end

  @doc """
  Paste literal text into an agent pane.

  When `pane` is omitted, requires the role-marked agent_pair pane. When an
  explicit pane id is supplied, that pane is used without the agent_pair
  marker — fleet orchestrators targeting a known worker pane.

  On `submit: true`, Enter is **not** folded into the paste. The paste lands
  first; `PaneSubmit` then settles, presses Enter, and re-presses once if the
  agent did not consume it. Folding Enter into `paste-buffer` is the OpenCode
  double-Enter race: the TUI is still draining the buffer when the keystroke
  arrives and treats it as a newline mid-composer rather than a submit.
  """
  @spec paste_agent_text(map()) :: {:ok, map()} | {:error, term()}
  def paste_agent_text(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, text} <- string_arg(params, "text"),
         {:ok, pane} <- paste_target_pane(session, params) do
      submit? = truthy?(Map.get(params, "submit") || Map.get(params, :submit))

      # Always paste without Enter. Submit ownership stays in PaneSubmit so the
      # settle + retry contract is identical for agent_pair and explicit panes.
      case tmux().paste_text(session, text, target: pane.id, submit: false) do
        :ok ->
          if submit? do
            report_dispatch_working(params, session, pane.id, text, "terminal_paste_agent_text")
            # paste_bytes scales PaneSubmit settle so large OpenCode briefs are
            # not Enter'd while the composer is still draining (#886).
            confirm_sent(session, pane.id, params,
              enter_already_sent: false,
              paste_bytes: byte_size(text)
            )
          else
            {:ok, sent_payload(session, pane.id, "terminal_capture_agent", params)}
          end

        {:error, reason} ->
          {:error, reason}

        {out, _code} ->
          {:error, String.trim(out)}
      end
    end
  end

  # Explicit pane id wins and skips the agent_pair marker. Without a pane, the
  # dedicated agent pane is required (marker only — no process-name guessing on
  # a mutating paste path).
  defp paste_target_pane(session, params) do
    case Map.get(params, "pane") || Map.get(params, :pane) do
      pane_id when is_binary(pane_id) and pane_id != "" ->
        case Enum.find(tmux().list_session_panes(session), &(&1.id == pane_id)) do
          nil -> {:error, :invalid_pane}
          pane -> {:ok, pane}
        end

      _ ->
        find_agent_pane(session, params, allow_process_fallback: false)
    end
  end

  # tmux accepting an Enter is not the agent consuming it. `PaneSubmit` watches
  # the pane afterwards and re-presses once if nothing happened, so the tool's
  # `status: "sent"` stops meaning "we wrote bytes at a pty" and starts meaning
  # "the agent took the input". Callers that genuinely only want the keystroke
  # (a TUI menu, a y/n prompt) pass `confirm: false`.
  #
  # When paste deferred Enter (`enter_already_sent: false`) and the caller opts
  # out of confirmation, still press Enter once — otherwise `submit: true` +
  # `confirm: false` would leave text sitting unsent in the composer.
  defp confirm_sent(session, pane_id, params, opts) do
    confirm? = Map.get(params, "confirm") != false and Map.get(params, :confirm) != false
    payload = sent_payload(session, pane_id, "terminal_capture_agent", params)

    if confirm? do
      confirm_opts =
        opts
        |> Keyword.put(:confirm, true)
        # Agent orchestration needs a hard delivery boundary. Returning
        # `status: sent` while the text is still sitting in a TUI composer is
        # the silent-loss failure this tool is meant to prevent. Callers that
        # only need a keystroke can still opt out with `confirm: false`.
        |> Keyword.put_new(:strict, true)
        |> Keyword.put_new(:paste_bytes, 0)

      case PaneSubmit.confirm_submit(session, pane_id, confirm_opts) do
        {:ok, confirmation} ->
          {:ok, Map.merge(payload, stringify_confirmation(confirmation))}

        {:error, error} ->
          {:error, Map.merge(payload, stringify_confirmation(error))}
      end
    else
      presses = press_enter_if_needed(session, pane_id, opts)

      {:ok,
       Map.merge(
         payload,
         stringify_confirmation(%{
           submitted: nil,
           delivery: :skipped,
           confirmation: :unavailable,
           enter_presses: presses
         })
       )}
    end
  end

  defp press_enter_if_needed(session, pane_id, opts) do
    if Keyword.get(opts, :enter_already_sent, false) do
      1
    else
      _ = tmux().send_keys(session, "Enter", target: pane_id)
      1
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

  @doc """
  Leave a message for another agent at an address.

  Resolution happens against the live topology so an orchestrator can address a
  window by name, but an ambiguous name is returned as an error with its
  candidates rather than delivered to a guess.
  """
  @spec say(map()) :: {:ok, map()} | {:error, term()}
  def say(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, session} <- session_or_default_arg(params),
         {:ok, recipient} <- string_arg(params, "to"),
         {:ok, body} <- string_arg(params, "body"),
         {:ok, address} <- resolve_address(recipient, session),
         {:ok, event, status} <-
           Inbox.send(%{
             workspace_id: workspace_id,
             to: address,
             from: sender_address(params),
             body: body,
             message_id: string_param(params, "message_id"),
             tmux_session_id: session,
             pane_id: caller_pane(params) || string_param(params, "from_pane")
           }) do
      {:ok,
       %{
         message_event_id: event.id,
         to: address,
         from: event.payload["from"],
         session: session,
         status: if(status == :inserted, do: "sent", else: "duplicate"),
         note:
           "Left at an address, not typed into a pane. The recipient sees it on its next " <>
             "terminal_inbox call; it stays uncollected until then."
       }}
    end
  end

  @doc """
  Read messages left for a pane, defaulting to the caller's own mailbox.

  #911 lifecycle: each message carries `status` (`queued`|`collected`),
  `unread?`, and stable `message_id`. Collect clears unread — peek does not.
  This is an addressed store; it never writes into panes.
  """
  @spec inbox(map()) :: {:ok, map()} | {:error, term()}
  def inbox(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, session} <- session_or_default_arg(params),
         {:ok, address} <- inbox_address(params, session) do
      limit = integer_param(params, "limit", 50)

      include_collected? =
        truthy?(Map.get(params, "include_collected") || Map.get(params, :include_collected))

      collect? = truthy?(Map.get(params, "collect") || Map.get(params, :collect))
      before = Inbox.summary(workspace_id, address)

      messages =
        Inbox.list(workspace_id, address,
          limit: limit,
          include_collected: include_collected?
        )

      collect_results =
        if collect? do
          Enum.map(messages, fn message ->
            # Prefer stable message_id so double-collect is idempotent across
            # retries that only retained the send-side id (#911 / #872 pattern).
            ref = message.message_id || message.id

            case Inbox.collect(workspace_id, ref, %{
                   to: address,
                   tmux_session_id: session,
                   pane_id: caller_pane(params)
                 }) do
              {:ok, _receipt, outcome} ->
                %{message_id: message.message_id, message_event_id: message.id, outcome: outcome}

              {:error, reason} ->
                %{
                  message_id: message.message_id,
                  message_event_id: message.id,
                  outcome: :error,
                  error: reason
                }
            end
          end)
        else
          []
        end

      # After collect, re-list so wire status reflects cleared unread — never
      # report collected:true while messages still show unread?/queued.
      messages_after =
        if collect? do
          Inbox.list(workspace_id, address,
            limit: limit,
            include_collected: include_collected?
          )
        else
          messages
        end

      after_summary = Inbox.summary(workspace_id, address)

      payload = %{
        address: address,
        session: session,
        collected: collect?,
        messages: Enum.map(messages_after, &inbox_message/1),
        count: length(messages_after),
        pending: after_summary.pending,
        unread: after_summary.unread,
        # Snapshot before collect so the caller can see what became read.
        pending_before: before.pending,
        unread_before: before.unread
      }

      payload =
        if collect? do
          Map.put(payload, :collect_results, collect_results)
        else
          payload
        end

      {:ok, payload}
    end
  end

  defp inbox_message(message) do
    status = Map.get(message, :status) || :queued
    unread? = Map.get(message, :unread?)
    unread? = if is_boolean(unread?), do: unread?, else: status == :queued

    %{
      message_event_id: message.id,
      message_id: message.message_id,
      from: message.from,
      body: message.body,
      sent_at: message.sent_at,
      # Honest lifecycle — never "collected" while still queued (#911).
      status: Atom.to_string(status),
      unread?: unread?,
      collected_at: Map.get(message, :collected_at)
    }
    |> compact()
  end

  # An explicit address wins; otherwise an agent reading "my mail" means the
  # pane it is running in.
  defp inbox_address(params, session) do
    cond do
      is_binary(string_param(params, "address")) ->
        resolve_address(string_param(params, "address"), session)

      is_binary(string_param(params, "pane")) ->
        {:ok, Address.for_pane(string_param(params, "pane"))}

      is_binary(caller_pane(params)) ->
        {:ok, Address.for_pane(caller_pane(params))}

      true ->
        {:error, :no_inbox_address}
    end
  end

  defp sender_address(params) do
    case caller_pane(params) || string_param(params, "from_pane") do
      pane when is_binary(pane) and pane != "" -> Address.for_pane(pane)
      _ -> nil
    end
  end

  # Ambiguity is surfaced with its candidates so the caller can retry with an
  # exact pane id — never resolved to a best match.
  defp resolve_address(recipient, session) do
    topology = TmuxTopology.snapshot(session, tmux: tmux())

    case Address.resolve(recipient, topology) do
      {:ok, address} ->
        {:ok, address}

      {:error, {:ambiguous, candidates}} ->
        {:error,
         %{
           error: :ambiguous_recipient,
           recipient: recipient,
           candidates: candidates,
           note: "More than one agent window matches. Re-send with an exact pane address."
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp integer_param(params, key, default) do
    case Map.get(params, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  @doc "Create a durable typed Needs Me request for an exact role-marked agent pane."
  @spec request_human_input(map()) :: {:ok, map()} | {:error, term()}
  def request_human_input(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, session} <- session_or_default_arg(params),
         {:ok, pane_id} <- string_arg(params, "pane"),
         {:ok, request_id} <- string_arg(params, "request_id"),
         {:ok, agent_session_id} <- string_arg(params, "agent_session_id"),
         {:ok, kind} <- string_arg(params, "kind"),
         {:ok, prompt} <- string_arg(params, "prompt"),
         {:ok, event, status} <-
           Clarification.request(%{
             workspace_id: workspace_id,
             tmux_session_id: session,
             pane_id: pane_id,
             request_id: request_id,
             agent_session_id: agent_session_id,
             request_kind: kind,
             question: prompt,
             choices: Map.get(params, "choices") || Map.get(params, :choices) || []
           }) do
      {:ok,
       %{
         request_event_id: event.id,
         revision: event.id,
         kind: kind,
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

  # Design fallback: first send_command opens a Run when `:working` is never
  # reported (Grok/OpenCode). Idempotent when observe_state already opened one.
  defp note_lifecycle_send_command(params, session, pane_id, message, tool) do
    case workspace_id(params) do
      id when is_binary(id) and id != "" ->
        AgentLifecycle.note_send_command(%{
          workspace_id: id,
          tmux_session: session,
          pane_id: pane_id,
          actor_id: string_param(params, "actor_id") || "agent",
          tool: tool,
          message: message,
          source: :send_command
        })

      _ ->
        :ok
    end
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

  @doc """
  Bind (or clear) the GitHub issue a pane is working.

  Passing no issue — or an explicit null — clears the binding, so the same tool
  handles claim and release rather than needing a second verb the caller might
  forget on the way out.
  """
  @spec bind_issue(map()) :: {:ok, map()} | {:error, term()}
  def bind_issue(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, session} <- session_or_default_arg(params),
         {:ok, pane} <- label_target_pane(session, params) do
      raw = Map.get(params, "issue") || Map.get(params, :issue)

      case raw do
        nil ->
          :ok = IssueBinding.clear(workspace_id, session, pane.id)
          {:ok, %{session: session, target: pane.id, issue: nil, status: "cleared"}}

        value ->
          case IssueBinding.bind(workspace_id, session, pane.id, value,
                 url: Map.get(params, "url") || Map.get(params, :url),
                 title: Map.get(params, "title") || Map.get(params, :title)
               ) do
            {:ok, entry} ->
              {:ok,
               %{
                 session: session,
                 target: pane.id,
                 issue: entry.issue,
                 url: entry.url,
                 status: "bound"
               }}

            {:error, :invalid_issue} ->
              {:error, {:invalid_issue, value}}
          end
      end
    end
  end

  @doc """
  Create a durable work handle, or reattach an existing one after pane respawn.

  When `handle_id` is present the id is preserved and only the pane pointer
  moves — that is the respawn path. Otherwise a new handle is minted.
  """
  @spec work_handle_create(map()) :: {:ok, map()} | {:error, term()}
  def work_handle_create(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params) do
      case string_param(params, "handle_id") do
        handle_id when is_binary(handle_id) ->
          reattach_work_handle(handle_id, workspace_id, params)

        nil ->
          mint_work_handle(workspace_id, params)
      end
    end
  end

  @doc "Resolve a durable work handle to its current pane and recorded status."
  @spec work_handle_get(map()) :: {:ok, map()} | {:error, term()}
  def work_handle_get(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, handle_id} <- string_arg(params, "handle_id"),
         {:ok, resolved} <- WorkHandles.get(handle_id),
         true <- resolved.workspace_id == workspace_id || {:error, :unknown_handle} do
      {:ok, work_handle_payload(resolved)}
    else
      {:error, :unknown_handle} -> {:error, :unknown_handle}
      other -> other
    end
  end

  @doc "List durable work handles for a workspace."
  @spec work_handle_list(map()) :: {:ok, map()} | {:error, term()}
  def work_handle_list(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params) do
      handles = Enum.map(WorkHandles.list(workspace_id), &work_handle_payload/1)
      {:ok, %{workspace_id: workspace_id, handles: handles, count: length(handles)}}
    end
  end

  defp mint_work_handle(workspace_id, params) do
    opts =
      [
        session: optional_session(params),
        pane_id: string_param(params, "pane"),
        label: string_param(params, "label"),
        status: string_param(params, "status"),
        message: string_param(params, "message")
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case maybe_validate_session_for_handle(opts, params) do
      {:error, _} = err ->
        err

      :ok ->
        {:ok, handle} = WorkHandles.create(workspace_id, opts)
        {:ok, resolved} = WorkHandles.get(handle.handle_id)
        {:ok, Map.put(work_handle_payload(resolved), :status_action, "created")}
    end
  end

  defp reattach_work_handle(handle_id, workspace_id, params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, pane} <- required_pane_arg(params),
         {:ok, _handle} <- WorkHandles.attach(handle_id, workspace_id, session, pane) do
      case string_param(params, "status") do
        status when is_binary(status) ->
          _ = WorkHandles.record_status(handle_id, status, string_param(params, "message"))

        nil ->
          :ok
      end

      {:ok, resolved} = WorkHandles.get(handle_id)
      {:ok, Map.put(work_handle_payload(resolved), :status_action, "reattached")}
    else
      {:error, :unknown_handle} -> {:error, :unknown_handle}
      {:error, :workspace_mismatch} -> {:error, :unknown_handle}
      {:error, _} = err -> err
    end
  end

  defp required_pane_arg(params) do
    case string_param(params, "pane") do
      pane when is_binary(pane) -> {:ok, pane}
      _ -> {:error, :missing_pane}
    end
  end

  defp optional_session(params) do
    case Map.get(params, "session") || Map.get(params, :session) do
      session when is_binary(session) and session != "" -> session
      _ -> nil
    end
  end

  defp maybe_validate_session_for_handle(opts, params) do
    case Keyword.get(opts, :session) do
      session when is_binary(session) ->
        case session_or_default_arg(Map.put(params, "session", session)) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end

      _ ->
        :ok
    end
  end

  defp work_handle_payload(resolved) do
    compact(%{
      handle_id: resolved.handle_id,
      workspace_id: resolved.workspace_id,
      label: resolved.label,
      session: resolved.session,
      pane_id: resolved.pane_id,
      pane: resolved.pane,
      status: resolved.status,
      created_at: resolved.created_at,
      updated_at: resolved.updated_at,
      attached_at: resolved.attached_at
    })
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

  @doc """
  Stage the sticky next operator prompt for an agent pane.

  Replaces whatever was pending for that pane — one slot, latest wins. When the
  pane is already in the requested state the message is injected immediately
  instead of waiting for an edge that has already gone by.
  """
  @spec set_next_prompt(map()) :: {:ok, map()} | {:error, term()}
  def set_next_prompt(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, session} <- session_or_default_arg(params),
         {:ok, text} <- string_arg(params, "text"),
         {:ok, pane} <- label_target_pane(session, params, :other),
         {:ok, deliver_when} <- deliver_when_arg(params) do
      {current_state, _message} = current_agent_state(session, pane.id)
      runtime = pane_runtime(pane)

      opts = [
        workspace_id: workspace_id,
        deliver_when: deliver_when,
        coalesce_key: string_param(params, "coalesce_key"),
        agent_session_id: bound_agent_session_id(session, pane.id, params),
        expires_at: NextPrompt.expires_at(expires_in_param(params)),
        set_by: string_param(params, "actor_id"),
        current_state: current_state,
        runtime: runtime
      ]

      case NextPrompt.set(session, pane.id, text, opts) do
        {:ok, %{status: status, entry: entry, replaced: replaced}} ->
          {:ok,
           %{
             session: session,
             target: pane.id,
             status: Atom.to_string(status),
             agent_state: Atom.to_string(current_state),
             replaced_pending: replaced != nil,
             replaced_coalesce_key: replaced && replaced.coalesce_key
           }
           |> Map.merge(entry_payload(entry))
           |> put_next(
             "terminal_get_next_prompt",
             next_prompt_next_args(session, pane.id, params)
           )
           |> compact()}

        {:error, :state_edges_unavailable} ->
          {:error, state_edges_unavailable_error(pane.id, runtime, deliver_when)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Drop the pending sticky prompt for an agent pane."
  @spec clear_next_prompt(map()) :: {:ok, map()} | {:error, term()}
  def clear_next_prompt(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, pane} <- label_target_pane(session, params, :other) do
      cleared =
        NextPrompt.clear(session, pane.id, coalesce_key: string_param(params, "coalesce_key"))

      {:ok,
       %{
         session: session,
         target: pane.id,
         status: if(cleared, do: "cleared", else: "not_pending")
       }
       |> Map.merge(if(cleared, do: entry_payload(cleared), else: %{}))
       |> compact()}
    end
  end

  @doc "Read the pending sticky prompt for an agent pane, if any."
  @spec get_next_prompt(map()) :: {:ok, map()} | {:error, term()}
  def get_next_prompt(params) do
    with {:ok, session} <- session_or_default_arg(params),
         {:ok, pane} <- label_target_pane(session, params, :other) do
      entry = NextPrompt.get(session, pane.id)

      {:ok,
       %{
         session: session,
         target: pane.id,
         pending_next_prompt: entry != nil
       }
       |> Map.merge(if(entry, do: entry_payload(entry), else: %{}))
       |> compact()}
    end
  end

  # Only the truthy flag is written, so the common "nothing staged" payload is
  # byte-identical to what callers see today.
  defp put_pending_next_prompt(payload, session, pane_id) do
    case NextPrompt.get(session, pane_id) do
      nil ->
        payload

      entry ->
        Map.merge(payload, %{
          pending_next_prompt: true,
          pending_next_prompt_deliver_when: Atom.to_string(entry.deliver_when)
        })
    end
  end

  defp entry_payload(entry) do
    compact(%{
      text: entry.text,
      deliver_when: Atom.to_string(entry.deliver_when),
      coalesce_key: entry.coalesce_key,
      agent_session_id: entry.agent_session_id,
      set_at: DateTime.to_iso8601(entry.set_at),
      expires_at: entry.expires_at && DateTime.to_iso8601(entry.expires_at)
    })
  end

  defp next_prompt_next_args(session, pane_id, params) do
    compact(%{workspace_id: workspace_id(params), session: session, pane: pane_id})
  end

  defp deliver_when_arg(params) do
    case NextPrompt.parse_deliver_when(string_param(params, "deliver_when")) do
      {:ok, deliver_when} -> {:ok, deliver_when}
      :error -> {:error, :invalid_deliver_when}
    end
  end

  defp pane_runtime(pane) do
    command = Map.get(pane, :current_command) || Map.get(pane, "current_command")
    PaneProcessLiveness.runtime_from_command(command)
  end

  defp state_edges_unavailable_error(pane_id, runtime, deliver_when) do
    runtime_name = runtime || "unknown"

    %{
      error: :state_edges_unavailable,
      refused: true,
      pane: pane_id,
      runtime: runtime_name,
      deliver_when: Atom.to_string(deliver_when),
      remedy: "terminal_paste_agent_text",
      message:
        "Refused: #{runtime_name} does not report agent-state edges, so a sticky " <>
          "next_prompt with deliver_when=#{deliver_when} can never be released. " <>
          "This is not pending — it was not accepted. Paste now with " <>
          "terminal_paste_agent_text when the pane is idle."
    }
  end

  defp expires_in_param(params) do
    case Map.get(params, "expires_in_seconds") || Map.get(params, :expires_in_seconds) do
      seconds when is_integer(seconds) -> seconds
      _ -> nil
    end
  end

  # Binding the runtime session id is what makes "drop when the agent restarts"
  # possible. An explicit argument wins so an orchestrator that already knows
  # which session it is addressing is not at the mercy of report timing; absent
  # that, the pane's last report is the best available answer, and nil (no hooks
  # wired) simply means the entry is never dropped for this reason.
  defp bound_agent_session_id(session, pane_id, params) do
    case string_param(params, "agent_session_id") do
      id when is_binary(id) ->
        id

      nil ->
        case AgentState.get(session, pane_id) do
          %{agent_session_id: id} when is_binary(id) and id != "" -> id
          _ -> nil
        end
    end
  end

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
    pane =
      session
      |> tmux().list_session_panes()
      |> Enum.find(&(&1.id == pane_id))

    case transcript_path_for(session, pane || %{id: pane_id}, %{}) do
      {:ok, path} -> Transcripts.final_assistant_message(path)
      _ -> nil
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

  defp transcript_path_for(session, pane, params) do
    pane_id = Map.get(pane, :id) || Map.get(pane, "id")
    report = if is_binary(pane_id), do: AgentState.get(session, pane_id)

    case Transcripts.resolve_for_pane(pane, transcript_resolve_opts(report, params)) do
      {:ok, path} ->
        {:ok, path}

      {:error, reason} ->
        {:error, %{error: :no_transcript, reason: reason}}
    end
  end

  defp transcript_resolve_opts(report, params) do
    workspace = workspace_id(params)

    [
      report: report,
      owner: workspace,
      claude_home: transcript_claude_home(workspace)
    ]
  end

  defp transcript_claude_home(workspace) when is_binary(workspace) and workspace != "",
    do: AuthProfile.active_profile_dir(workspace, :claude)

  defp transcript_claude_home(_workspace), do: nil

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
    written =
      string_param(params, "command") || string_param(params, "text") ||
        string_param(params, "keys")

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
    |> PaneWriteReceipt.attach(session, target, written)
  end
end
