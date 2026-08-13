defmodule CaseinWeb.WorkspaceLive.Show.PtyEvents do
  # PTY / terminal-recovery handle_info clauses extracted verbatim from
  # CaseinWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  #
  # Owns: :pty_data, :pane_frame, :pty_exit, :terminal_recovery,
  # :auto_apply_recovery_template, :auto_reattach_pane.
  #
  # Constraints (do not "fix" as a side effect of this split):
  # - Behaviour-preserving only. A bug found while splitting is a new issue,
  #   not a change in this PR.
  # - Do not touch Show's handle_event dispatch table or authz_gate/3.
  # - Do not "fix" LiveView change tracking. `<.workspace_shell {assigns}>`
  #   and `{terminal_tab_attrs(assigns)}` disable tracking for any
  #   assigns-dependent dynamic part; adding :__changed__ to a Map.take
  #   does not restore it. That is a separate, already-understood problem.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  alias Casein.Terminals
  alias CaseinWeb.TerminalTelemetry
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.ClipboardDrawerEvents
  alias CaseinWeb.WorkspaceLive.Show.TerminalState

  @osc52_prefix "\x1b]52;"
  @osc52_max_base64_bytes 256 * 1024
  @osc52_max_buffer_bytes @osc52_max_base64_bytes + 256
  @osc52_max_matches 4

  @pane_auto_retry_limit 3
  @pane_auto_retry_backoff_ms 750

  # Tagged PTY output from a specific pane's worker, already coalesced to one
  # message per ~16ms frame by the worker. The worker has *already* written
  # these bytes into its own term and will send a `{:pane_frame, ...}` with the
  # rendered grid; here we only run the cheap byte-stream side channels whose
  # state lives on the LiveView. Preview panes are owned by the agent/tool that
  # creates them, so generic terminal output does not create preview prompts.
  # We do NOT touch the term on this path — that work runs in the worker process
  # so a pane streaming heavy output can't block the LiveView channel into a
  # reload.
  def handle_info({:pty_data, pane_id, data}, socket) when is_binary(data) do
    :telemetry.span(
      [:casein, :workspace_live, :pty_data],
      %{pane_id: pane_id, bytes: byte_size(data)},
      fn ->
        # OSC52: a program (or tmux with set-clipboard on) requesting that text
        # be placed on the system clipboard, embedded in the PTY byte stream.
        # The browser only receives the rendered cell grid, so we extract it
        # here and push it down for navigator.clipboard.writeText. Best-effort:
        # writeText needs a focused secure context (works on Chrome; Safari may
        # gate it on a gesture).
        socket = push_osc52_clipboard(socket, pane_id, data)

        {{:noreply, socket}, %{}}
      end
    )
  end

  # A finished render frame built by the pane's worker (off the LiveView
  # process). Forwarding it to the browser is a cheap `push_event` — no
  # synchronous term call — so it never stalls the channel regardless of how
  # much output the pane is producing.
  def handle_info({:pane_frame, pane_id, payload}, socket) do
    socket =
      if Show.get_pane_data(socket, pane_id) do
        emit_terminal_push_telemetry(pane_id, payload)
        push_event(socket, "ghostty:render", payload)
      else
        # Pane closed between the worker building the frame and us receiving
        # it — drop the stale frame.
        socket
      end

    {:noreply, socket}
  end

  # PaneWorker reports its own death (or its PTY's) — clear the pane's pids
  # (and record the exit reason in `error`) so the next render shows a
  # diagnostic error state + Retry button instead of an infinite
  # "starting terminal…" placeholder. This surfaces PTY/tmux launch
  # failures (bad TERM, missing binary, permission issues, etc.) that
  # used to leave the raw Ghostty pane stuck.
  def handle_info({:pty_exit, pane_id, status}, socket) do
    status = normalize_pane_exit_reason(status)

    # Output buffering/draining lives in the (now dead) PaneWorker, so there
    # is no LV-side buffer to clear. Only touch pane_data if the pane still
    # exists (prevents update_pane from inserting `pane_id => nil` for a
    # just-closed or unknown pane).
    socket =
      if Show.get_pane_data(socket, pane_id) do
        Show.update_pane(socket, pane_id, fn p ->
          %{p | ghostty_pty: nil, ghostty_term: nil, worker: nil, backend: nil, error: status}
        end)
      else
        socket
      end

    # Auto-reattach instead of forcing a manual Retry click. The tmux session
    # persists (`tmux new-session -A`), so a dropped client/PTY is recoverable
    # by re-attaching — the scrollback is still there. We bound this to
    # @pane_auto_retry_limit attempts (per pane) so a genuinely broken launch
    # (e.g. a workspace image lacking tmux) degrades to the manual Retry button
    # instead of looping forever. A successful start resets the counter (see
    # start_ghostty_for_pane).
    socket = maybe_auto_reattach_pane(socket, pane_id, status)

    {:noreply, socket}
  end

  # tmux server/session wipe: Session/SessionOwner emitted a recovery notice.
  # Banner the operator and best-effort re-apply the last session template so
  # agent_pair layout comes back without a manual template click.
  #
  # The notice is broadcast workspace-wide, but the template is only ever
  # applied to *this* LiveView's primary session. Ignore notices about any
  # other session: re-applying then appends layout to a healthy session that
  # was never wiped, and a session that flaps (e.g. one whose worktree is gone
  # recreates-and-dies every drift tick) would grow a `work` window on every
  # tick, forever.
  def handle_info({:terminal_recovery, %{type: :session_recreated} = notice}, socket) do
    if recovery_notice_for_current_session?(socket, notice) do
      history =
        if notice.history_restored?,
          do: " Recent scrollback was restored from archive.",
          else: " Pane history may be empty."

      socket =
        put_flash(
          socket,
          :error,
          "Terminal session was recreated after a tmux reset.#{history}"
        )

      socket =
        case notice.template_id do
          id when is_binary(id) and id != "" ->
            # Fire-and-forget best effort; don't block UI on template failure.
            Process.send_after(self(), {:auto_apply_recovery_template, id}, 500)
            socket

          _ ->
            socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:auto_apply_recovery_template, template_id}, socket)
      when is_binary(template_id) do
    # Applying a template is purely additive (every window step is `new_window`),
    # so only auto-apply onto a session that really came back empty. A session
    # that already carries layout keeps it instead of gaining a duplicate set of
    # template windows.
    if TerminalState.tmux_mutations_allowed?(socket) and recovered_session_empty?(socket) do
      Show.apply_session_template(socket, template_id, recovery?: true)
    else
      {:noreply, socket}
    end
  end

  def handle_info({:auto_reattach_pane, pane_id, attempt}, socket) do
    pane = Show.get_pane_data(socket, pane_id)

    # Only reattach if the pane still exists, is still in an error state (the
    # user didn't already click Retry or close it), and this is the most recent
    # scheduled attempt (avoid double-starts if several exits raced).
    socket =
      if pane && pane.error != nil && Map.get(pane, :auto_retry_count, 0) == attempt do
        socket
        |> Show.update_pane(pane_id, fn p -> %{p | error: nil} end)
        |> Show.start_ghostty_for_pane(pane_id)
      else
        socket
      end

    {:noreply, socket}
  end

  defp emit_terminal_push_telemetry(pane_id, payload) do
    :telemetry.execute(
      [:casein, :terminal, :live_view, :push_frame],
      %{
        count: 1,
        changed_rows: TerminalTelemetry.changed_row_count(payload)
      }
      |> Map.merge(TerminalTelemetry.sampled_payload_measurements(payload)),
      %{
        pane_id: pane_id,
        id: Map.get(payload, :id),
        full_frame?: Map.get(payload, :full_frame) == true,
        frame_seq: Map.get(payload, :frame_seq),
        frame_epoch: Map.get(payload, :frame_epoch)
      }
    )
  end

  # OSC 52 set-clipboard: ESC ] 52 ; <sel> ; <base64> (BEL | ST). PTY reads can
  # split that escape sequence anywhere, and agent CLIs often copy much more
  # than the old single-regex 48 KB ceiling. Keep a bounded partial buffer so
  # `/copy` commands from Claude/Codex/etc. survive chunk boundaries without
  # allowing unbounded terminal output to become clipboard state.
  # Buffer is keyed by pane_id so concurrent panes don't merge partial sequences.
  # Cap is 256 KB of base64 (~192 KB decoded) — real clipboard text is far smaller;
  # the previous 4 MB ceiling inflated socket assign diffs for no practical gain.
  defp push_osc52_clipboard(socket, pane_id, data) when is_binary(pane_id) do
    buffers = socket.assigns[:osc52_clipboard_buffers] || %{}
    buffer = Map.get(buffers, pane_id, "")

    if buffer == "" and :binary.match(data, @osc52_prefix) == :nomatch do
      maybe_store_osc52_prefix_tail(socket, pane_id, buffers, data)
    else
      do_push_osc52_clipboard(socket, pane_id, buffers, buffer <> data)
    end
  end

  defp do_push_osc52_clipboard(socket, pane_id, buffers, data) do
    {payloads, rest} = extract_osc52_payloads(data, [], @osc52_max_matches)
    rest = bounded_osc52_buffer(rest)

    buffers =
      if rest == "" do
        Map.delete(buffers, pane_id)
      else
        Map.put(buffers, pane_id, rest)
      end

    socket = assign(socket, :osc52_clipboard_buffers, buffers)

    Enum.reduce(payloads, socket, fn b64, s ->
      case Base.decode64(b64) do
        {:ok, text} when text != "" ->
          # Retain it before asking the browser to write it: on iOS that write
          # is frequently refused, and the drawer is how the copy stays
          # recoverable instead of being lost with the toast.
          s = ClipboardDrawerEvents.record(s, pane_id, text)
          push_event(s, "clipboard:write", %{"text" => text})

        _ ->
          s
      end
    end)
  end

  defp extract_osc52_payloads(_data, acc, 0), do: {Enum.reverse(acc), ""}

  defp extract_osc52_payloads(data, acc, remaining) do
    case :binary.match(data, @osc52_prefix) do
      :nomatch ->
        {Enum.reverse(acc), osc52_prefix_tail(data)}

      {start, prefix_len} ->
        sequence = binary_part(data, start, byte_size(data) - start)
        after_prefix = binary_part(data, start + prefix_len, byte_size(data) - start - prefix_len)
        take_osc52_payload(sequence, after_prefix, acc, remaining)
    end
  end

  defp take_osc52_payload(sequence, after_prefix, acc, remaining) do
    case :binary.match(after_prefix, ";") do
      :nomatch ->
        {Enum.reverse(acc), sequence}

      {selector_len, 1} ->
        b64_start = selector_len + 1

        after_selector =
          binary_part(after_prefix, b64_start, byte_size(after_prefix) - b64_start)

        decode_osc52_payload(sequence, after_selector, acc, remaining)
    end
  end

  defp decode_osc52_payload(sequence, after_selector, acc, remaining) do
    case split_osc52_terminator(after_selector) do
      :incomplete ->
        {Enum.reverse(acc), sequence}

      {b64, after_terminator} ->
        acc = if byte_size(b64) <= @osc52_max_base64_bytes, do: [b64 | acc], else: acc
        extract_osc52_payloads(after_terminator, acc, remaining - 1)
    end
  end

  defp maybe_store_osc52_prefix_tail(socket, pane_id, buffers, data) do
    case osc52_prefix_tail(data) do
      "" ->
        socket

      tail ->
        assign(socket, :osc52_clipboard_buffers, Map.put(buffers, pane_id, tail))
    end
  end

  defp bounded_osc52_buffer(buffer) when byte_size(buffer) > @osc52_max_buffer_bytes,
    do: osc52_prefix_tail(buffer)

  defp bounded_osc52_buffer(buffer), do: buffer

  defp osc52_prefix_tail(data) do
    max = min(byte_size(data), byte_size(@osc52_prefix) - 1)
    if max <= 0, do: "", else: longest_osc52_prefix_tail(data, max)
  end

  defp longest_osc52_prefix_tail(data, max) do
    Enum.reduce_while(max..1//-1, "", fn len, _acc ->
      tail = binary_part(data, byte_size(data) - len, len)

      if binary_part(@osc52_prefix, 0, len) == tail,
        do: {:halt, tail},
        else: {:cont, ""}
    end)
  end

  defp split_osc52_terminator(data) do
    case earliest_binary_match(data, ["\x07", "\x1b\\"]) do
      nil ->
        :incomplete

      {idx, len} ->
        after_offset = idx + len

        {binary_part(data, 0, idx),
         binary_part(data, after_offset, byte_size(data) - after_offset)}
    end
  end

  defp earliest_binary_match(data, patterns) do
    patterns
    |> Enum.map(&:binary.match(data, &1))
    |> Enum.reject(&(&1 == :nomatch))
    |> Enum.min_by(fn {idx, _len} -> idx end, fn -> nil end)
  end

  # A recovery notice concerns this LiveView only when it names the session the
  # template would be applied to.
  defp recovery_notice_for_current_session?(socket, notice) do
    session = socket.assigns[:tmux_session]

    is_binary(session) and session != "" and Map.get(notice, :tmux_session) == session
  end

  # A freshly recreated tmux session (`new-session -A`) holds a single window
  # with a single pane. Anything richer already has a layout worth keeping.
  defp recovered_session_empty?(socket) do
    case socket.assigns[:tmux_session] do
      session when is_binary(session) and session != "" ->
        case Terminals.tmux_topology_snapshot(session, tmux: TerminalState.tmux_adapter()) do
          %{windows: [window]} -> length(Map.get(window, :pane_list, [])) <= 1
          %{windows: []} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  # Schedule a single bounded reattach for a pane that just exited, if it still
  # exists and hasn't exhausted its retry budget. The actual restart happens in
  # the `{:auto_reattach_pane, pane_id, attempt}` handler after a short backoff,
  # so transient teardown (server restart drain, tmux respawn) has settled.
  defp maybe_auto_reattach_pane(socket, pane_id, status) do
    pane = Show.get_pane_data(socket, pane_id)

    attempts = if pane, do: Map.get(pane, :auto_retry_count, 0), else: 0

    if pane && recoverable_pane_exit?(status) && attempts < @pane_auto_retry_limit do
      next = attempts + 1

      Process.send_after(
        self(),
        {:auto_reattach_pane, pane_id, next},
        @pane_auto_retry_backoff_ms
      )

      Show.update_pane(socket, pane_id, fn p -> Map.put(p, :auto_retry_count, next) end)
    else
      socket
    end
  end

  # Recover process/PTY death and SessionOwner recover exhaustion. Do NOT
  # reattach on clean integer exit statuses (shell `exit`, normalized
  # `{:exit_status, n}`) — those are intentional pane ends and are covered by
  # WorkspacePaneSplitTest. SessionOwner reattaches the backend on term_exit
  # without tearing the PaneWorker when possible.
  defp recoverable_pane_exit?(reason)
       when reason in [
              :pty_died,
              :process_died,
              :terminal_died,
              :backend_recover_failed,
              :process_exit,
              :signal
            ],
       do: true

  defp recoverable_pane_exit?(_), do: false

  defp normalize_pane_exit_reason({:exit_status, status}) when is_integer(status), do: status
  defp normalize_pane_exit_reason(reason), do: reason
end
