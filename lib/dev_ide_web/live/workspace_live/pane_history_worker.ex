defmodule CaseinWeb.WorkspaceLive.PaneHistoryWorker do
  @moduledoc """
  Owner of a read-only `Ghostty.Terminal` seeded from one tmux pane's
  scrollback, for the per-pane history viewer.

  The live workspace surface renders the *composited* tmux screen through a
  single shared emulator, and full-screen agent TUIs repaint in place, so that
  emulator never accumulates scrollback. The browsable history for an agent
  pane lives only in tmux itself (`history-limit`). This worker captures it
  once (`capture-pane -e -J -S -` targeted at the pane id) and replays it into
  a dedicated emulator whose viewport the viewer can scroll — the existing
  `Ghostty.Terminal.scroll/2` + scrollbar frame path.

  Deliberately read-only and fully detached from the live render path: it
  never touches the SessionOwner, the shared PTY, tmux focus, or tmux sizes,
  so the terminal-screen convergence invariants (emulator size == tmux size
  after settle, attach/resize ends in a full repaint) are untouched no matter
  what the viewer does here. The capture is a static snapshot; reopening the
  viewer re-captures.

  Like `PaneWorker`, the worker links to its parent LiveView and traps exits,
  so an emulator crash reports `{:pane_history_down, pane_id}` instead of
  cascading into the LV. Seeding happens in `handle_continue`, off the LV
  process, because parsing a large history into the emulator is a synchronous
  native call; the LV shows a loading state until `{:pane_history_ready,
  pane_id, term}` arrives.
  """
  use GenServer

  @type opt ::
          {:parent, pid()}
          | {:pane_id, String.t()}
          | {:tmux_session, String.t()}
          | {:cols, pos_integer()}
          | {:rows, pos_integer()}
          | {:tmux_adapter, module()}

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Stop the worker without blocking the caller. Stopping synchronously from the
  LiveView would wait out an in-flight seed (`handle_continue` capturing a
  large history), stalling the channel on a close click — so the stop runs in
  a throwaway process.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(worker) do
    spawn(fn ->
      try do
        GenServer.stop(worker, :normal, 10_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  @impl true
  def init(opts) do
    parent = Keyword.fetch!(opts, :parent)
    pane_id = Keyword.fetch!(opts, :pane_id)
    tmux_session = Keyword.fetch!(opts, :tmux_session)
    cols = Keyword.fetch!(opts, :cols)
    rows = Keyword.fetch!(opts, :rows)
    adapter = Keyword.get(opts, :tmux_adapter, Casein.Terminals.tmux_adapter())

    Process.flag(:trap_exit, true)

    max_scrollback = Application.get_env(:dev_ide, :pane_history_max_scrollback, 10_000)

    case Ghostty.Terminal.start_link(cols: cols, rows: rows, max_scrollback: max_scrollback) do
      {:ok, term} ->
        state = %{
          parent: parent,
          pane_id: pane_id,
          tmux_session: tmux_session,
          rows: rows,
          adapter: adapter,
          max_scrollback: max_scrollback,
          term: term
        }

        {:ok, state, {:continue, :seed}}

      {:error, reason} ->
        {:stop, {:start_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:seed, state) do
    bytes =
      state.tmux_session
      |> capture(state)
      |> normalize_capture()

    if bytes != "", do: Ghostty.Terminal.write(state.term, bytes)
    send(state.parent, {:pane_history_ready, state.pane_id, state.term})
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _from, reason}, state) when reason in [:normal, :shutdown] do
    {:noreply, state}
  end

  def handle_info({:EXIT, _from, _reason}, state) do
    send(state.parent, {:pane_history_down, state.pane_id})
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The term does not trap exits, so this worker stopping `:normal` would
  # leave it alive (a normal exit signal does not kill a linked process) —
  # stop it explicitly or every closed history modal leaks an emulator.
  @impl true
  def terminate(_reason, %{term: term}) when is_pid(term) do
    if Process.alive?(term), do: GenServer.stop(term, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp capture(session, state) do
    if Code.ensure_loaded?(state.adapter) and
         function_exported?(state.adapter, :capture_scrollback, 2) do
      # Tail the capture to what the emulator can retain: viewport + scrollback.
      state.adapter.capture_scrollback(session,
        target: state.pane_id,
        ansi: true,
        lines: state.max_scrollback + state.rows
      )
    else
      ""
    end
  end

  # `capture-pane -p` joins lines with bare "\n". Written straight into an
  # emulator that would move the cursor down without returning to column 0
  # (staircase output), so re-terminate every line with CRLF. Trailing
  # newlines are dropped so the capture's last line sits at the viewport
  # bottom instead of a stray blank row.
  defp normalize_capture(text) when is_binary(text) do
    text
    |> String.trim_trailing("\n")
    |> String.replace("\r\n", "\n")
    |> String.replace("\n", "\r\n")
  end

  defp normalize_capture(_), do: ""
end
