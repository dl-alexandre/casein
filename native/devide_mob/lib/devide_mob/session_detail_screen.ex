defmodule DevideMob.SessionDetailScreen do
  @moduledoc """
  Focused supervisory view for one workspace. Subscribes to its
  `session:<workspace_id>` channel via `DevideMob.SessionClient` and renders the
  live `DevIDE.Session.Snapshot`: mode + connection status, the current run,
  recent policy/audit activity, and active agents.

  Pure projection consumer — it never mutates session state (that stays on the
  runtime, gated by policy). Snapshot payloads arrive JSON-decoded, so map keys
  and enum values are strings ("review", "deny", ...).
  """
  use Mob.Screen

  alias DevideMob.PairingScreen
  alias DevideMob.SessionConfig
  alias DevideMob.SessionClient

  @transition_notice_ms 1_600

  def mount(params, _session, socket) do
    workspace_id = params[:workspace_id] || params["workspace_id"]

    if is_binary(workspace_id), do: SessionClient.watch(workspace_id, self())

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

  def handle_info({:clear_notice, message}, %{assigns: %{notice: message}} = socket) do
    {:noreply, Mob.Socket.assign(socket, :notice, nil)}
  end

  def handle_info({:clear_notice, _message}, socket), do: {:noreply, socket}

  def handle_info(_message, socket), do: {:noreply, socket}

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
            %{
              type: :column,
              props: %{fill_width: true, padding: :space_md, gap: 10},
              children:
                [
                  status_banner(snap, assigns.status),
                  transition_notice(assigns.notice)
                  | body(snap, assigns.status)
                ]
                |> Enum.reject(&is_nil/1)
            }
          ]
        },
        pin_bar(assigns)
      ]
    }
  end

  defp body(nil, status) do
    case status_state(status) do
      state when state in [:disconnected, :error] -> recovery_panel(status)
      _ -> connecting_panel()
    end
  end

  defp body(snap, _status) do
    [
      supervision_summary(snap),
      current_run_card(get(snap, "current_run")),
      section_label("Recent runs"),
      runs_section(get(snap, "recent_runs", [])),
      section_label("Recent activity"),
      activity_section(get(snap, "recent_audit", [])),
      section_label("Active agents"),
      agents_section(get(snap, "active_agents", []))
    ]
  end

  defp recovery_panel(status) do
    [
      %{
        type: :column,
        props: %{fill_width: true, background: :surface, padding: :space_lg, gap: 8},
        children:
          [
            %{
              type: :text,
              props: %{
                text: offline_title(status),
                text_color: :on_surface,
                text_size: :lg,
                font_weight: "bold"
              },
              children: []
            },
            %{
              type: :text,
              props: %{
                text: problem_body(status),
                text_color: :muted,
                text_size: :sm
              },
              children: []
            },
            recovery_buttons(status)
          ]
          |> List.flatten()
          |> Enum.reject(&is_nil/1)
      }
    ]
  end

  defp connecting_panel do
    [
      %{
        type: :column,
        props: %{fill_width: true, background: :surface, padding: :space_lg, gap: 8},
        children: [
          %{type: :progress, props: %{color: :primary}, children: []},
          %{
            type: :text,
            props: %{
              text: "Connecting to session...",
              text_color: :muted,
              text_align: "center"
            },
            children: []
          }
        ]
      }
    ]
  end

  # ── Header ──────────────────────────────────────────────────────────────────

  defp top_header(workspace_id, status) do
    %{
      type: :row,
      props: %{fill_width: true, background: :primary, padding: :space_sm, gap: 8},
      children: [
        %{
          type: :button,
          props: %{
            text: "Back",
            background: :surface_raised,
            text_color: :on_surface,
            padding: :space_sm,
            height: 44.0,
            on_tap: {self(), :back}
          },
          children: []
        },
        %{
          type: :text,
          props: %{
            text: display_workspace(workspace_id),
            text_size: :lg,
            text_color: :on_primary,
            font_weight: "bold",
            weight: 1
          },
          children: []
        },
        chip(status_label(status), status_color(status))
      ]
    }
  end

  defp status_banner(snap, status) do
    mode = if snap, do: get(snap, "mode"), else: nil

    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_md, gap: 6},
      children: [
        %{
          type: :text,
          props: %{
            text: "Workspace status",
            text_size: :sm,
            text_color: :muted,
            font_weight: "bold"
          },
          children: []
        },
        %{
          type: :row,
          props: %{fill_width: true, gap: 8, padding_top: :space_xs},
          children: [
            chip(mode_label(mode), mode_color(mode)),
            chip(status_label(status), status_color(status))
          ]
        }
      ]
    }
  end

  defp transition_notice(nil), do: nil

  defp transition_notice(message) do
    %{
      type: :text,
      props: %{
        text: message,
        fill_width: true,
        background: :surface_raised,
        text_color: :on_surface,
        text_size: :sm,
        padding: :space_sm
      },
      children: []
    }
  end

  # ── Current run ─────────────────────────────────────────────────────────────

  defp supervision_summary(snap) do
    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_md, gap: 6},
      children: [
        %{
          type: :text,
          props: %{text: "Now", text_color: :muted, text_size: :sm, font_weight: "bold"},
          children: []
        },
        %{
          type: :text,
          props: %{text: summary_line(snap), text_color: :on_surface, text_size: :lg},
          children: []
        }
      ]
    }
  end

  defp summary_line(snap) do
    [
      run_summary_count(get(snap, "current_run")),
      count_summary(get(snap, "active_agents", []), "agent", "agents"),
      review_summary(get(snap, "pending_reviews", 0))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
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
    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_md, gap: 6},
      children: [
        %{type: :text, props: %{text: "No active run", text_color: :muted}, children: []}
      ]
    }
  end

  defp current_run_card(run) do
    status = get(run, "status")

    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_md, gap: 6},
      children:
        [
          %{
            type: :row,
            props: %{fill_width: true, gap: 8},
            children: [
              %{
                type: :text,
                props: %{text: "Current run", text_color: :muted, text_size: :sm, weight: 1},
                children: []
              },
              chip(run_status_label(run), run_status_color(status))
            ]
          },
          maybe_text(run_title(run), :on_surface, :lg),
          maybe_text(run_time_line(run), :muted, :xs),
          maybe_text(run_context_line(run), :muted, :xs),
          maybe_text(run_reference_line(run), :muted, :xs),
          maybe_text(run_result_line(run), :muted, :xs)
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  # ── Recent runs ─────────────────────────────────────────────────────────────

  defp runs_section([]), do: empty_row("No recent runs")

  defp runs_section(runs) do
    %{
      type: :column,
      props: %{fill_width: true},
      children: runs |> List.wrap() |> Enum.take(4) |> Enum.map(&run_row/1)
    }
  end

  defp run_row(run) do
    status = get(run, "status")

    %{
      type: :column,
      props: %{
        fill_width: true,
        background: :surface,
        padding_top: 10,
        padding_bottom: 10,
        padding_left: :space_md,
        padding_right: :space_md,
        gap: 6
      },
      children:
        [
          %{
            type: :row,
            props: %{fill_width: true, gap: 8},
            children: [
              %{
                type: :text,
                props: %{text: run_title(run), text_color: :on_surface, weight: 1},
                children: []
              },
              chip(run_status_label(run), run_status_color(status))
            ]
          },
          maybe_text(run_time_line(run), :muted, :xs)
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  # ── Recent activity ─────────────────────────────────────────────────────────

  defp activity_section([]) do
    empty_row("No recent activity")
  end

  defp activity_section(rows) do
    %{
      type: :column,
      props: %{fill_width: true},
      children: Enum.map(rows, &activity_row/1)
    }
  end

  defp activity_row(row) do
    decision = get(row, "decision")
    color = decision_color(decision)
    reason = get(row, "reason")

    %{
      type: :column,
      props: %{
        fill_width: true,
        background: :surface,
        padding_top: 10,
        padding_bottom: 10,
        padding_left: :space_md,
        padding_right: :space_md,
        gap: 8
      },
      children:
        [
          %{
            type: :row,
            props: %{fill_width: true, gap: 8},
            children:
              [
                %{
                  type: :text,
                  props: %{text: get(row, "action", "—"), text_color: :on_surface, weight: 1},
                  children: []
                },
                decision && chip(to_string(decision), color)
              ]
              |> Enum.reject(&is_nil/1)
          },
          reason_text(reason)
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp reason_text(nil), do: nil

  defp reason_text(reason) do
    %{
      type: :text,
      props: %{text: to_string(reason), text_size: :xs, text_color: :muted},
      children: []
    }
  end

  # ── Active agents ───────────────────────────────────────────────────────────

  defp agents_section([]) do
    empty_row("No active agents")
  end

  defp agents_section(agents) do
    %{
      type: :column,
      props: %{fill_width: true},
      children: Enum.map(agents, &agent_row/1)
    }
  end

  defp agent_row(agent) do
    %{
      type: :column,
      props: %{
        fill_width: true,
        background: :surface,
        padding_top: 10,
        padding_bottom: 10,
        padding_left: :space_md,
        padding_right: :space_md,
        gap: 6
      },
      children:
        [
          %{
            type: :row,
            props: %{fill_width: true, gap: 8},
            children: [
              %{
                type: :text,
                props: %{text: agent_title(agent), text_color: :on_surface, weight: 1},
                children: []
              },
              chip(agent_status_label(agent), agent_status_color(get(agent, "status")))
            ]
          },
          maybe_text(get(agent, "summary"), :muted, :sm),
          maybe_text(agent_meta_line(agent), :muted, :xs)
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

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

  defp section_label(text) do
    %{
      type: :text,
      props: %{
        text: text,
        text_size: :sm,
        text_color: :muted,
        padding_top: :space_sm,
        padding_bottom: :space_xs
      },
      children: []
    }
  end

  defp chip(text, color) do
    %{
      type: :text,
      props: %{
        text: text,
        text_size: :xs,
        text_color: :on_surface,
        background: color,
        padding_left: :space_sm,
        padding_right: :space_sm,
        padding_top: 4,
        padding_bottom: 4
      },
      children: []
    }
  end

  defp empty_row(text) do
    %{
      type: :text,
      props: %{text: text, text_color: :muted, padding: :space_md},
      children: []
    }
  end

  defp maybe_text(nil, _color, _size), do: nil
  defp maybe_text("", _color, _size), do: nil

  defp maybe_text(text, color, size) do
    %{
      type: :text,
      props: %{text: to_string(text), text_color: color, text_size: size},
      children: []
    }
  end

  defp pin_bar(assigns) do
    pin_label = if assigns.pinned?, do: "Unpin", else: "Pin"
    pin_tap = if assigns.pinned?, do: :unpin, else: :pin

    %{
      type: :column,
      props: %{fill_width: true, background: :surface_raised, padding: :space_sm},
      children: [
        %{
          type: :button,
          props: %{
            text: pin_label,
            fill_width: true,
            background: :surface,
            text_color: :on_surface,
            text_size: :lg,
            padding: :space_sm,
            height: 44.0,
            on_tap: {self(), pin_tap}
          },
          children: []
        }
      ]
    }
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

  defp mode_color("manual"), do: :blue_400
  defp mode_color("review"), do: :amber_400
  defp mode_color("agent_write_locked"), do: :muted
  defp mode_color("shared_stage_guarded"), do: :red_400
  defp mode_color(_), do: :surface_raised

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

  defp status_color(status) do
    case status_state(status) do
      :joined -> :green_400
      :connecting -> :amber_400
      :disconnected -> :surface_raised
      :error -> :red_400
      _ -> :surface_raised
    end
  end

  defp run_status_color("succeeded"), do: :green_400
  defp run_status_color("started"), do: :amber_400
  defp run_status_color("running"), do: :amber_400
  defp run_status_color("queued"), do: :amber_400
  defp run_status_color("approval_requested"), do: :amber_400
  defp run_status_color("approval_granted"), do: :blue_400
  defp run_status_color("approval_denied"), do: :red_400
  defp run_status_color("timed_out"), do: :red_400
  defp run_status_color("failed"), do: :red_400
  defp run_status_color(_), do: :surface_raised

  defp agent_status_color("ok"), do: :green_400
  defp agent_status_color(:ok), do: :green_400
  defp agent_status_color("error"), do: :red_400
  defp agent_status_color(:error), do: :red_400
  defp agent_status_color(_), do: :surface_raised

  defp decision_color("deny"), do: :red_400
  defp decision_color(:deny), do: :red_400
  defp decision_color("allow"), do: :green_400
  defp decision_color(:allow), do: :green_400
  defp decision_color(_), do: :surface_raised

  defp recovery_buttons(status) do
    retry = recovery_button("Retry", :retry, :surface_raised, :on_surface)
    pair_again = recovery_button("Pair again", :pair_again, :primary, :on_primary)

    case status_reason(status) do
      reason
      when reason in [:workspace_scope_mismatch, :unauthorized, :auth_expired, :token_revoked] ->
        [pair_again, retry]

      _ ->
        [retry]
    end
  end

  defp recovery_button(label, tap, background, text_color) do
    %{
      type: :button,
      props: %{
        text: label,
        fill_width: true,
        background: background,
        text_color: text_color,
        padding: :space_sm,
        height: 44.0,
        on_tap: {self(), tap}
      },
      children: []
    }
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
