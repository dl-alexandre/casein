defmodule DevideMob.HostBridge do
  @moduledoc """
  Host-side **Model-B-over-the-wire**: run a real shell on the dev host and stream
  its VT bytes to a `DevideMob.TerminalScreen` running on a device, over Mob
  distribution. The device renders the grid; the shell never runs on-device.

  The device's current screen is registered as `:mob_screen` on the device node,
  and `TerminalScreen` handles `{:vt_bytes, binary}` — so streaming is just
  `send({:mob_screen, device_node}, {:vt_bytes, bytes})`. Device → host input is
  `input/2` (written into the PTY).

      # from the host (mix), with the device node connected (see mix mob.connect):
      {:ok, b} = DevideMob.HostBridge.start(:"devide_mob_android_xxx@127.0.0.1")
      DevideMob.HostBridge.input(b, "ls\\n")

  Host-only dev tooling — `Ghostty.PTY` (forkpty) needs a real OS shell, which the
  device deliberately doesn't have.
  """

  use GenServer

  @spec start(node(), keyword()) :: GenServer.on_start()
  def start(device_node, opts \\ []) when is_atom(device_node) do
    GenServer.start(__MODULE__, {device_node, opts})
  end

  @doc "Send input bytes to the shell (e.g. a typed command + newline)."
  @spec input(pid(), iodata()) :: :ok
  def input(bridge, bytes), do: GenServer.cast(bridge, {:input, IO.iodata_to_binary(bytes)})

  @doc "Resize the PTY (and ask the device terminal to resize to match)."
  @spec resize(pid(), pos_integer(), pos_integer()) :: :ok
  def resize(bridge, cols, rows), do: GenServer.cast(bridge, {:resize, cols, rows})

  @impl true
  def init({device_node, opts}) do
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    # PTY owner is this GenServer, so {:data, _}/{:exit, _} arrive in handle_info.
    {:ok, pty} = Ghostty.PTY.start_link(cmd: shell(), cols: cols, rows: rows)
    # Announce ourselves as the device screen's input sink, so the device Send
    # button can route keystrokes back to this shell.
    send({:mob_screen, device_node}, {:vt_host, self()})
    {:ok, %{pty: pty, device: device_node}}
  end

  @impl true
  def handle_info({:data, bytes}, state) when is_binary(bytes) do
    send({:mob_screen, state.device}, {:vt_bytes, bytes})
    {:noreply, state}
  end

  # Input from the device screen — write it to the PTY. We do NOT echo it
  # ourselves; the line discipline echoes it back as {:data}, rendered once.
  def handle_info({:vt_input, bytes}, state) when is_binary(bytes) do
    Ghostty.PTY.write(state.pty, bytes)
    {:noreply, state}
  end

  # The device measured its viewport and picked a grid — match the PTY to it so
  # `stty size` and reflow agree with what's rendered.
  def handle_info({:vt_resize, cols, rows}, state)
      when is_integer(cols) and is_integer(rows) do
    Ghostty.PTY.resize(state.pty, cols, rows)
    {:noreply, state}
  end

  def handle_info({:exit, _status}, state), do: {:stop, :normal, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:input, bytes}, state) do
    Ghostty.PTY.write(state.pty, bytes)
    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) do
    Ghostty.PTY.resize(state.pty, cols, rows)
    send({:mob_screen, state.device}, {:resize_terminal, cols, rows})
    {:noreply, state}
  end

  defp shell, do: System.get_env("SHELL") || "/bin/sh"
end
