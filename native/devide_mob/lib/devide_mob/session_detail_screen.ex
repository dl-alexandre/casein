defmodule DevideMob.SessionDetailScreen do
  @moduledoc """
  Focused supervisory view for one workspace. Subscribes to its
  `session:<workspace_id>` channel via `DevideMob.SessionClient` and renders the
  live `DevIDE.Session.Snapshot`: mode + connection status, the current run,
  recent policy/audit activity, and active agents.

  Snapshot payloads arrive JSON-decoded, so map keys and enum values are
  strings ("review", "deny", ...).

  The one thing this screen *does* send is an agent instruction: free text (or
  a quick reply) typed here is pushed to the workspace's agent pane through
  `DevideMob.SessionClient.send_instruction/3`. The server resolves the target
  pane and audits the send — the phone never names a pane. Everything else here
  stays a read-only projection; run state is mutated only through policy-gated
  card actions.
  """
  use Mob.Screen

  alias DevideMob.Outbox
  alias DevideMob.PairingScreen
  alias DevideMob.SessionConfig
  alias DevideMob.UI
  alias DevideMob.SessionClient

  @transition_notice_ms 1_600
  @instruction_max_length 4_000

  # One tap covers the instructions worth giving from a phone; anything longer
  # is faster to type in the cockpit.
  @quick_replies [
    {"Continue", "Continue with the plan."},
    {"Run tests", "Run the test suite and report what fails."},
    {"Explain", "Explain what you are doing and why, briefly."},
    {"Stop", "Stop what you are doing and wait for instructions."}
  ]

  def mount(params, _session, socket) do
    workspace_id = params[:workspace_id] || params["workspace_id"]
    session_id = params[:session_id] || params["session_id"]
    source = params[:source] || params["source"] || :workspace

    if is_binary(workspace_id) do
      SessionConfig.put_resume_context(workspace_id, session_id: session_id, source: source)
      SessionClient.watch(workspace_id, self())
    end

    socket =
      socket
      |> Mob.Socket.assign(:workspace_id, workspace_id)
      |> Mob.Socket.assign(:snapshot, nil)
      |> Mob.Socket.assign(:status, :connecting)
      |> Mob.Socket.assign(:notice, nil)
      |> Mob.Socket.assign(
        :pinned?,
        is_binary(workspace_id) and SessionConfig.pinned?(workspace_id)
      )
      |> Mob.Socket.assign(:instruction, "")
      |> Mob.Socket.assign(:instruction_state, :idle)
      |> Mob.Socket.assign(:instruction_notice, nil)
      |> Mob.Socket.assign(
        :queued_instructions,
        if(is_binary(workspace_id), do: Outbox.count(workspace_id), else: 0)
      )

    {:ok, socket}
  end

  # ── Live updates from the channel ───────────────────────────────────────────

  def handle_info({:session_snapshot, wid, payload}, %{assigns: %{workspace_id: wid}} = socket) do
    {:noreply, Mob.Socket.assign(socket, :snapshot, payload)}
  end

  def handle_info({:session_status, wid, status}, %{assigns: %{workspace_id: wid}} = socket) do
    previous_status = socket.assigns.status

    {:noreply,
     socket
     |> Mob.Socket.assign(:status, status)
     |> transition_notice(previous_status, status)}
  end

  def handle_info({:session_alert, wid, payload}, %{assigns: %{workspace_id: wid}} = socket) do
    title = Map.get(payload, "title", "Session alert")
    reason = Map.get(payload, "reason")
    message = if is_binary(reason) and reason != "", do: "#{title} (#{reason})", else: title
    {:noreply, Mob.Alert.toast(socket, message)}
  end

  # ── User actions ────────────────────────────────────────────────────────────

  def handle_info({:tap, :back}, socket) do
    if is_binary(socket.assigns.workspace_id),
      do: SessionClient.unwatch(socket.assigns.workspace_id, self())

    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info({:tap, :pin}, socket) do
    if is_binary(socket.assigns.workspace_id),
      do: SessionConfig.pin_workspace(socket.assigns.workspace_id)

    {:noreply, Mob.Socket.assign(socket, :pinned?, true)}
  end

  def handle_info({:tap, :unpin}, socket) do
    if is_binary(socket.assigns.workspace_id),
      do: SessionConfig.unpin_workspace(socket.assigns.workspace_id)

    {:noreply, Mob.Socket.assign(socket, :pinned?, false)}
  end

  def handle_info({:tap, :retry}, socket) do
    if is_binary(socket.assigns.workspace_id),
      do: SessionClient.watch(socket.assigns.workspace_id, self())

    {:noreply,
     socket
     |> Mob.Socket.assign(:status, :connecting)
     |> Mob.Socket.assign(:notice, reconnecting_notice())}
  end

  def handle_info({:tap, :pair_again}, socket) do
    {:noreply, Mob.Socket.push_screen(socket, PairingScreen)}
  end

  # ── Instructing the agent ───────────────────────────────────────────────────

  def handle_info({:change, :instruction, value}, socket) when is_binary(value) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:instruction, String.slice(value, 0, @instruction_max_length))
     |> Mob.Socket.assign(:instruction_notice, nil)}
  end

  def handle_info({:tap, :send_instruction}, socket) do
    {:noreply, send_instruction(socket, socket.assigns.instruction)}
  end

  def handle_info({:tap, {:quick_reply, text}}, socket) when is_binary(text) do
    {:noreply, send_instruction(socket, text)}
  end

  def handle_info(
        {:agent_instruction_result, wid, result},
        %{assigns: %{workspace_id: wid}} = socket
      ) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:instruction_state, :idle)
     |> Mob.Socket.assign(:instruction_notice, instruction_notice(result))
     |> Mob.Socket.assign(:queued_instructions, Outbox.count(wid))
     |> clear_instruction_on_success(result)}
  end

  def handle_info({:tap, :retry_outbox}, socket) do
    SessionClient.flush_outbox(self())
    {:noreply, Mob.Socket.assign(socket, :instruction_notice, "Retrying queued instructions...")}
  end

  def handle_info({:clear_notice, message}, %{assigns: %{notice: message}} = socket) do
    {:noreply, Mob.Socket.assign(socket, :notice, nil)}
  end

  def handle_info({:clear_notice, _message}, socket), do: {:noreply, socket}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp send_instruction(socket, text) do
    workspace_id = socket.assigns.workspace_id
    trimmed = String.trim(text || "")

    cond do
      not is_binary(workspace_id) ->
        socket

      trimmed == "" ->
        Mob.Socket.assign(socket, :instruction_notice, "Type an instruction first")

      socket.assigns.instruction_state == :sending ->
        socket

      true ->
        SessionClient.send_instruction(workspace_id, trimmed, subscriber: self())

        socket
        |> Mob.Socket.assign(:instruction_state, :sending)
        |> Mob.Socket.assign(:instruction_notice, nil)
    end
  end

  # A queued instruction is *accepted* from the user's point of view — the text
  # is safely in the outbox, so the field clears just as it would on a send.
  defp clear_instruction_on_success(socket, {:ok, _payload}),
    do: Mob.Socket.assign(socket, :instruction, "")

  defp clear_instruction_on_success(socket, {:queued, _details}),
    do: Mob.Socket.assign(socket, :instruction, "")

  defp clear_instruction_on_success(socket, _result), do: socket

  defp instruction_notice({:ok, payload}) when is_map(payload) do
    case Map.get(payload, "submitted") do
      false -> "Pasted into the agent pane — press Enter there to send"
      _ -> "Sent to the agent"
    end
  end

  defp instruction_notice({:ok, _payload}), do: "Sent to the agent"

  defp instruction_notice({:queued, _details}),
    do: "Queued — it will send when the phone reconnects"

  defp instruction_notice({:error, reason}), do: "Could not send: #{instruction_error(reason)}"

  defp instruction_error("agent_pane_not_found"),
    do: "no agent pane is running in this workspace"

  defp instruction_error("instruction_too_long"), do: "that instruction is too long"
  defp instruction_error("unauthorized"), do: "this device is not allowed to instruct that agent"
  defp instruction_error(:not_connected), do: "the phone is offline"
  defp instruction_error(reason) when is_binary(reason), do: String.replace(reason, "_", " ")
  defp instruction_error(reason), do: inspect(reason)

  # ── Render ──────────────────────────────────────────────────────────────────

  def render(assigns) do
    snap = assigns.snapshot

    %{
      type: :column,
      props: %{background: :background, fill_width: true, fill_height: true},
      children: [
        top_header(assigns.workspace_id, assigns.status),
        %{
          type: :scroll,
          props: %{fill_width: true, weight: 1},
          children: [
            UI.stack(
              [
                transition_notice(assigns.notice),
                status_banner(snap, assigns.status)
                | body(assigns, snap, assigns.status)
              ],
              gap: 12,
              padding_left: 16,
              padding_right: 16,
              padding_top: 12,
              padding_bottom: 20
            )
          ]
        },
        pin_bar(assigns)
      ]
    }
  end

  defp body(_assigns, nil, status) do
    case status_state(status) do
      state when state in [:disconnected, :error] -> recovery_panel(status)
      _ -> connecting_panel()
    end
  end

  defp body(assigns, snap, _status) do
    [
      supervision_summary(snap),
      instruction_card(assigns, snap),
      current_run_card(get(snap, "current_run")),
      UI.section_label("Active agents"),
      agents_section(get(snap, "active_agents", [])),
      UI.section_label("Work log"),
      work_log_section(snap)
    ]
  end

  defp recovery_panel(status) do
    [
      UI.card(
        [
          UI.row(
            [
              UI.icon("warning", text_color: UI.tone_fg(:failed), text_size: 18),
              UI.text(offline_title(status),
                text_size: :lg,
                font_weight: "semibold",
                text_color: :on_surface,
                weight: 1
              )
            ],
            gap: 8
          ),
          UI.body(problem_body(status), text_color: :muted),
          UI.row(List.flatten(recovery_buttons(status)), gap: 8)
        ],
        tone: :failed,
        padding: 16
      )
    ]
  end

  defp connecting_panel do
    [
      UI.card(
        [
          UI.row(
            [
              UI.spinner(),
              UI.body("Connecting to session...", text_color: :muted, weight: 1)
            ],
            gap: 10
          )
        ],
        padding: 16
      )
    ]
  end

  # ── Header ──────────────────────────────────────────────────────────────────

  defp top_header(workspace_id, status) do
    UI.header(display_workspace(workspace_id),
      leading: UI.icon_button("back", {self(), :back}, label: "Back", background: :surface),
      actions: [UI.chip(status_label(status), status_tone(status))]
    )
  end

  # Mode and connection state — the two facts that decide whether anything else
  # on this screen can be trusted.
  defp status_banner(snap, status) do
    mode = if snap, do: get(snap, "mode"), else: nil

    UI.card(
      [
        UI.section_label("Workspace status"),
        UI.row(
          [
            UI.chip(mode_label(mode), mode_tone(mode)),
            UI.chip(status_label(status), status_tone(status))
          ],
          gap: 6
        )
      ],
      gap: 8,
      padding: 12
    )
  end

  defp transition_notice(nil), do: nil

  defp transition_notice(message) do
    UI.tinted([UI.body(message)], :neutral, padding: 10)
  end

  # ── Instructing the agent ───────────────────────────────────────────────────

  # Only offered when the workspace actually has agents in flight: pasting into
  # a workspace with no agent pane fails server-side, and an input that can only
  # fail is worse than no input.
  defp instruction_card(assigns, snap) do
    agents = snap |> get("active_agents", []) |> List.wrap()

    if agents == [] do
      nil
    else
      UI.stack(
        [UI.section_label("Instruct the agent"), instruction_body(assigns)],
        gap: 8
      )
    end
  end

  defp instruction_body(assigns) do
    sending? = assigns[:instruction_state] == :sending

    UI.card(
      [
        quick_replies(sending?),
        %{
          type: :text_field,
          props: %{
            value: assigns[:instruction] || "",
            placeholder: "Tell the agent what to do next",
            keyboard: :default,
            return_key: :send,
            background: :surface_raised,
            text_color: :on_surface,
            placeholder_color: :muted,
            border_color: :border,
            corner_radius: :radius_md,
            padding: 12,
            on_change: {self(), :instruction},
            on_submit: {self(), :send_instruction}
          },
          children: []
        },
        outbox_row(assigns),
        instruction_status(assigns, sending?),
        UI.button(
          if(sending?, do: "Sending...", else: "Send to agent"),
          {self(), :send_instruction},
          :primary,
          disabled: sending?
        )
      ],
      gap: 10
    )
  end

  # The queue is only worth mentioning when it has something in it — an empty
  # outbox is the normal case and needs no chrome.
  defp outbox_row(assigns) do
    case assigns[:queued_instructions] || 0 do
      0 ->
        nil

      count ->
        UI.tinted(
          [
            UI.row(
              [
                UI.icon("history", text_color: UI.tone_fg(:attention), text_size: 14),
                UI.body(
                  "#{count} #{plural(count, "instruction", "instructions")} waiting to send",
                  weight: 1
                ),
                UI.button("Retry", {self(), :retry_outbox}, :secondary, fill_width: false)
              ],
              gap: 8
            )
          ],
          :attention,
          padding: 10
        )
    end
  end

  defp instruction_status(_assigns, true) do
    UI.row([UI.spinner(), UI.meta("Pasting into the agent pane", weight: 1)], gap: 8)
  end

  defp instruction_status(assigns, false) do
    case assigns[:instruction_notice] do
      notice when is_binary(notice) and notice != "" ->
        UI.meta(notice, text_color: instruction_notice_color(notice))

      _ ->
        nil
    end
  end

  defp instruction_notice_color("Could not send" <> _rest), do: UI.tone_fg(:failed)
  defp instruction_notice_color("Type an instruction" <> _rest), do: UI.tone_fg(:attention)
  defp instruction_notice_color("Queued" <> _rest), do: UI.tone_fg(:attention)
  defp instruction_notice_color("Retrying" <> _rest), do: UI.tone_fg(:attention)
  defp instruction_notice_color(_notice), do: UI.tone_fg(:done)

  # Chips carry a tap here (unlike the decorative status chips), which is why
  # they are the one place a chip gets an `on_tap`.
  defp quick_replies(sending?) do
    UI.row(
      Enum.map(@quick_replies, fn {label, text} ->
        UI.chip(label, :accent, on_tap: unless(sending?, do: {self(), {:quick_reply, text}}))
      end),
      gap: 6
    )
  end

  # ── Current run ─────────────────────────────────────────────────────────────

  defp supervision_summary(snap) do
    UI.card(
      [
        UI.section_label("Now"),
        UI.row(
          [
            stat_tile(run_summary_count(get(snap, "current_run"))),
            stat_tile(count_summary(get(snap, "active_agents", []), "agent", "agents")),
            stat_tile(review_summary(get(snap, "pending_reviews", 0)))
          ],
          gap: 8
        )
      ],
      gap: 10,
      padding: 12
    )
  end

  # Splits "2 agents" into a big count and a small unit so the three tiles read
  # as a dashboard at a glance instead of one long sentence.
  defp stat_tile(text) do
    {value, unit} =
      case String.split(text, " ", parts: 2) do
        [value, unit] -> {value, unit}
        [value] -> {value, ""}
      end

    UI.box(
      [
        UI.stack(
          [
            UI.text(value, text_size: :xl, font_weight: "bold", text_color: :on_surface),
            UI.meta(unit)
          ],
          gap: 2
        )
      ],
      weight: 1,
      background: :surface_raised,
      corner_radius: :radius_md,
      padding: 10
    )
  end

  defp run_summary_count(%{} = run) do
    if active_run?(run), do: "1 active run", else: "Last run #{run_status_label(run)}"
  end

  defp run_summary_count(_run), do: "No active run"

  defp count_summary(values, singular, plural) do
    count = values |> List.wrap() |> length()
    "#{count} #{plural(count, singular, plural)}"
  end

  defp review_summary(count) when is_integer(count) and count > 0 do
    "#{count} #{plural(count, "review", "reviews")}"
  end

  defp review_summary(_count), do: "0 reviews"

  defp current_run_card(nil) do
    UI.card([UI.body("No active run", text_color: :muted)], padding: 14)
  end

  defp current_run_card(run) do
    status = get(run, "status")

    UI.card(
      [
        UI.row(
          [
            UI.dot(run_status_tone(status)),
            UI.meta("Current run", weight: 1),
            UI.chip(run_status_label(run), run_status_tone(status))
          ],
          gap: 8
        ),
        UI.text(run_title(run), text_size: :lg, font_weight: "semibold", text_color: :on_surface),
        detail_lines([
          run_time_line(run),
          run_context_line(run),
          run_reference_line(run),
          run_result_line(run)
        ])
      ],
      tone: run_status_tone(status),
      gap: 8
    )
  end

  defp detail_lines(lines) do
    case lines |> Enum.reject(&(&1 in [nil, ""])) |> Enum.map(&to_string/1) do
      [] -> nil
      parts -> UI.stack(Enum.map(parts, &UI.meta/1), gap: 3)
    end
  end

  # ── Work log ────────────────────────────────────────────────────────────────
  #
  # Runs and policy decisions were two separate lists sorted independently, so
  # "what happened here" meant reading both and interleaving them by eye. One
  # reverse-chronological timeline answers it directly.
  #
  # Rendered through `LazyList` — a busy workspace's log is unbounded, and the
  # eager Column built every row whether or not it was ever scrolled to.

  @work_log_limit 40

  defp work_log_section(snap) do
    case work_log_entries(snap) do
      [] ->
        empty_row("Nothing has happened here yet")

      entries ->
        %{
          type: :lazy_list,
          props: %{fill_width: true, id: :work_log},
          children: Enum.map(entries, &work_log_row/1)
        }
    end
  end

  defp work_log_entries(snap) do
    runs =
      snap
      |> get("recent_runs", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn run ->
        %{
          kind: :run,
          at: run_at(run),
          title: run_title(run),
          chip: run_status_label(run),
          tone: run_status_tone(get(run, "status")),
          detail: run_time_line(run)
        }
      end)

    audit =
      snap
      |> get("recent_audit", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row ->
        decision = get(row, "decision")

        %{
          kind: :audit,
          at: get(row, "at"),
          title: get(row, "action", "—"),
          chip: decision && to_string(decision),
          tone: decision_tone(decision),
          detail: maybe_string(get(row, "reason"))
        }
      end)

    (runs ++ audit)
    |> Enum.sort_by(&sort_key/1, :desc)
    |> Enum.take(@work_log_limit)
  end

  # Undated entries sort last rather than crashing the comparison.
  defp sort_key(%{at: at}) do
    case at do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp run_at(run) do
    [
      get(run, "finished_at"),
      get(run, "started_at"),
      get(run, "requested_at"),
      get(run, "last_event_at")
    ]
    |> Enum.find(&present?/1)
  end

  defp work_log_row(entry) do
    UI.card(
      [
        UI.row(
          [
            UI.icon(work_log_icon(entry.kind), text_color: UI.tone_fg(entry.tone), text_size: 14),
            UI.text(to_string(entry.title),
              text_color: :on_surface,
              text_size: :sm,
              weight: 1
            ),
            entry.chip && UI.chip(entry.chip, entry.tone)
          ],
          gap: 8
        ),
        UI.meta(entry.detail || relative_at(entry.at))
      ],
      gap: 6,
      padding: 12
    )
  end

  defp work_log_icon(:run), do: "history"
  defp work_log_icon(_kind), do: "check"

  defp relative_at(at) when is_binary(at), do: relative_time(at)
  defp relative_at(_at), do: nil

  # ── Active agents ───────────────────────────────────────────────────────────

  defp agents_section([]) do
    empty_row("No active agents")
  end

  defp agents_section(agents) do
    UI.stack(Enum.map(agents, &agent_row/1), gap: 8)
  end

  defp agent_row(agent) do
    UI.card(
      [
        UI.row(
          [
            UI.dot(agent_status_tone(get(agent, "status"))),
            UI.text(agent_title(agent), text_color: :on_surface, text_size: :sm, weight: 1),
            UI.chip(agent_status_label(agent), agent_status_tone(get(agent, "status")))
          ],
          gap: 8
        ),
        UI.body(maybe_string(get(agent, "summary")), text_color: :muted),
        UI.meta(maybe_string(agent_meta_line(agent)))
      ],
      gap: 6,
      padding: 12
    )
  end

  defp maybe_string(nil), do: nil
  defp maybe_string(""), do: nil
  defp maybe_string(value), do: to_string(value)

  defp active_run?(%{} = run), do: get(run, "status") in ["started", "running", "queued"]

  defp run_title(%{} = run) do
    run
    |> get("command_id")
    |> case do
      nil -> get(run, "safe_action_id") || get(run, "id") || "run"
      value -> value
    end
    |> to_string()
    |> truncate(42)
  end

  defp run_title(_run), do: "run"

  defp run_status_label(run) do
    run
    |> get("status", "unknown")
    |> labelize()
  end

  defp run_time_line(run) do
    [
      {"finished", get(run, "finished_at")},
      {"started", get(run, "started_at")},
      {"requested", get(run, "requested_at")},
      {"updated", get(run, "last_event_at")}
    ]
    |> Enum.find(fn {_label, at} -> present?(at) end)
    |> case do
      {label, at} -> "#{label} #{relative_time(at)}"
      nil -> nil
    end
  end

  defp run_context_line(run) do
    run
    |> field_parts([
      {"source", "Source"},
      {"trigger", "Trigger"},
      {"plane", "Plane"},
      {"protocol", "Protocol"}
    ])
    |> join_parts()
  end

  defp run_reference_line(run) do
    run
    |> field_parts([
      {"assignment_id", "Assignment"},
      {"safe_action_id", "Safe action"}
    ])
    |> join_parts()
  end

  defp run_result_line(run) do
    case get(run, "exit_code") do
      nil -> nil
      value -> "Exit code #{value}"
    end
  end

  defp field_parts(map, fields) do
    Enum.flat_map(fields, fn {key, label} ->
      case get(map, key) do
        value when value in [nil, ""] -> []
        value -> ["#{label} #{labelize(value)}"]
      end
    end)
  end

  defp join_parts([]), do: nil
  defp join_parts(parts), do: Enum.join(parts, " · ")

  defp agent_title(agent) do
    agent
    |> get("tool", get(agent, "source", "agent"))
    |> to_string()
    |> truncate(38)
  end

  defp agent_status_label(agent), do: agent |> get("status", "active") |> labelize()

  defp agent_meta_line(agent) do
    [
      agent |> get("source") |> labelize(),
      agent_at_label(get(agent, "at"))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> join_parts()
  end

  defp agent_at_label(nil), do: nil
  defp agent_at_label(at), do: relative_time(at)

  # ── Small components ────────────────────────────────────────────────────────

  defp empty_row(text) do
    UI.card([UI.body(text, text_color: :muted)], padding: 14)
  end

  # A persistent bottom bar: pinning is the one action that changes what the
  # dashboard shows, so it stays reachable without scrolling back.
  defp pin_bar(assigns) do
    pin_label = if assigns.pinned?, do: "Unpin", else: "Pin"
    pin_tap = if assigns.pinned?, do: :unpin, else: :pin

    UI.stack(
      [
        UI.divider(),
        UI.button(pin_label, {self(), pin_tap}, if(assigns.pinned?, do: :ghost, else: :primary))
      ],
      gap: 10,
      background: :background,
      padding_left: 16,
      padding_right: 16,
      padding_top: 10,
      padding_bottom: 16
    )
  end

  defp offline_title(status), do: problem_title(status)

  defp transition_notice(socket, _previous_status, status) do
    case status_state(status) do
      :joined ->
        if socket.assigns.notice == reconnecting_notice() do
          temporary_notice(socket, "Workspace is live")
        else
          socket
        end

      state when state in [:disconnected, :error] ->
        if socket.assigns.notice == reconnecting_notice() do
          temporary_notice(socket, reconnect_resolution_notice(status))
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp temporary_notice(socket, message) do
    Process.send_after(self(), {:clear_notice, message}, @transition_notice_ms)
    Mob.Socket.assign(socket, :notice, message)
  end

  defp reconnecting_notice, do: "Reconnecting..."

  defp reconnect_resolution_notice(status) do
    case status_reason(status) do
      :workspace_not_found ->
        "Workspace was not found"

      :workspace_scope_mismatch ->
        "Pairing is for another workspace"

      reason when reason in [:unauthorized, :auth_expired, :token_revoked] ->
        "Pair again to restore access"

      :network_unavailable ->
        "Network still unavailable"

      _ ->
        "Still trying to reconnect"
    end
  end

  # ── Value mapping (payloads are JSON-decoded → string keys/values) ──────────

  defp get(map, key, default \\ nil)
  defp get(%{} = map, key, default), do: Map.get(map, key) || atom_key(map, key) || default
  defp get(_map, _key, default), do: default

  defp atom_key(map, key) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp atom_key(_map, _key), do: nil

  defp mode_label(nil), do: "—"
  defp mode_label(mode), do: mode |> to_string() |> String.replace("_", " ")

  defp mode_tone("manual"), do: :running
  defp mode_tone("review"), do: :attention
  defp mode_tone("agent_write_locked"), do: :neutral
  defp mode_tone("shared_stage_guarded"), do: :failed
  defp mode_tone(_), do: :neutral

  defp status_label(status) do
    case {status_state(status), status_reason(status)} do
      {:joined, _} -> "Live"
      {:connecting, _} -> "Connecting"
      {:disconnected, :network_unavailable} -> "Network"
      {:disconnected, _} -> "Offline"
      {:error, :workspace_not_found} -> "Missing"
      {:error, :workspace_scope_mismatch} -> "Pairing"
      {:error, reason} when reason in [:unauthorized, :auth_expired, :token_revoked] -> "Auth"
      {:error, :workspace_unavailable} -> "Unavailable"
      {:error, _} -> "Error"
      _ -> "—"
    end
  end

  defp status_tone(status) do
    case status_state(status) do
      :joined -> :done
      :connecting -> :neutral
      :disconnected -> :attention
      :error -> :failed
      _ -> :neutral
    end
  end

  defp run_status_tone("succeeded"), do: :done
  defp run_status_tone("started"), do: :running
  defp run_status_tone("running"), do: :running
  defp run_status_tone("queued"), do: :running
  defp run_status_tone("approval_requested"), do: :attention
  defp run_status_tone("approval_granted"), do: :done
  defp run_status_tone("approval_denied"), do: :failed
  defp run_status_tone("timed_out"), do: :failed
  defp run_status_tone("failed"), do: :failed
  defp run_status_tone(_), do: :neutral

  defp agent_status_tone("ok"), do: :done
  defp agent_status_tone(:ok), do: :done
  defp agent_status_tone("error"), do: :failed
  defp agent_status_tone(:error), do: :failed
  defp agent_status_tone(_), do: :neutral

  defp decision_tone("deny"), do: :failed
  defp decision_tone(:deny), do: :failed
  defp decision_tone("allow"), do: :done
  defp decision_tone(:allow), do: :done
  defp decision_tone(_), do: :neutral

  defp recovery_buttons(status) do
    retry = UI.button("Retry", {self(), :retry}, :secondary, weight: 1)
    pair_again = UI.button("Pair again", {self(), :pair_again}, :primary, weight: 1)

    case status_reason(status) do
      reason
      when reason in [:workspace_scope_mismatch, :unauthorized, :auth_expired, :token_revoked] ->
        [pair_again, retry]

      _ ->
        [retry]
    end
  end

  defp status_state({state, _reason}) when state in [:joined, :connecting, :disconnected, :error],
    do: state

  defp status_state(%{} = status), do: status |> get("state", :error) |> normalize_state()
  defp status_state(status), do: normalize_state(status)

  defp normalize_state("joined"), do: :joined
  defp normalize_state("connecting"), do: :connecting
  defp normalize_state("disconnected"), do: :disconnected
  defp normalize_state("error"), do: :error
  defp normalize_state(state), do: state

  defp status_reason({_state, reason}), do: normalize_reason(reason)
  defp status_reason(%{} = status), do: status |> get("reason") |> normalize_reason()
  defp status_reason(_status), do: nil

  defp normalize_reason("workspace_not_found"), do: :workspace_not_found
  defp normalize_reason("workspace_scope_mismatch"), do: :workspace_scope_mismatch
  defp normalize_reason("workspace_unavailable"), do: :workspace_unavailable
  defp normalize_reason("unauthorized"), do: :unauthorized
  defp normalize_reason("auth_expired"), do: :auth_expired
  defp normalize_reason("token_revoked"), do: :token_revoked
  defp normalize_reason("network_unavailable"), do: :network_unavailable
  defp normalize_reason("unknown"), do: :unknown
  defp normalize_reason(reason) when is_binary(reason), do: :unknown
  defp normalize_reason(reason), do: reason

  defp problem_title(status) do
    case {status_state(status), status_reason(status)} do
      {:disconnected, :network_unavailable} ->
        "Network unavailable"

      {:disconnected, _} ->
        "Session offline"

      {:error, :workspace_not_found} ->
        "Workspace not found"

      {:error, :workspace_scope_mismatch} ->
        "Wrong workspace paired"

      {:error, :workspace_unavailable} ->
        "Workspace unavailable"

      {:error, reason} when reason in [:unauthorized, :auth_expired, :token_revoked] ->
        "Pairing needs attention"

      {:error, _} ->
        "Session unavailable"

      _ ->
        "Session unavailable"
    end
  end

  defp problem_body(status) do
    case {status_state(status), status_reason(status)} do
      {:disconnected, :network_unavailable} ->
        "This phone cannot reach the DevIDE host. Check your connection and retry."

      {:disconnected, _} ->
        "The workspace may be offline or the network changed. Retry when the host is reachable."

      {:error, :workspace_not_found} ->
        "This workspace may have been deleted or moved. Unpin it from the bottom bar or pair again from the web cockpit."

      {:error, :workspace_scope_mismatch} ->
        "This phone is paired to a different workspace. Pair again from the correct web cockpit."

      {:error, :workspace_unavailable} ->
        "The workspace registry could not resolve this workspace. Retry or pair again."

      {:error, reason} when reason in [:unauthorized, :auth_expired, :token_revoked] ->
        "Your pairing may have expired or access was revoked. Pair again from the web cockpit."

      {:error, _} ->
        "The last connection could not join this workspace feed. Retry after refreshing the cockpit pairing code if it has expired."

      _ ->
        "The last connection could not join this workspace feed."
    end
  end

  defp display_workspace(workspace_id) when is_binary(workspace_id),
    do: truncate(workspace_id, 28)

  defp display_workspace(_workspace_id), do: "Workspace"

  defp truncate(value, limit) when is_binary(value) do
    if String.length(value) > limit do
      value |> String.slice(0, max(limit - 3, 1)) |> Kernel.<>("...")
    else
      value
    end
  end

  defp truncate(value, _limit), do: value

  defp labelize(nil), do: nil
  defp labelize(value), do: value |> to_string() |> String.replace("_", " ")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp relative_time(%DateTime{} = datetime), do: relative_time(DateTime.to_iso8601(datetime))

  defp relative_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

        cond do
          diff < 60 -> "just now"
          diff < 3_600 -> "#{div(diff, 60)}m ago"
          diff < 86_400 -> "#{div(diff, 3_600)}h ago"
          true -> "#{div(diff, 86_400)}d ago"
        end

      _ ->
        "unknown"
    end
  end

  defp relative_time(_value), do: "unknown"

  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural
end
