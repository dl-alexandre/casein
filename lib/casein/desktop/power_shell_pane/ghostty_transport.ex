defmodule Casein.Desktop.PowerShellPane.GhosttyTransport do
  @moduledoc false

  @behaviour Casein.Desktop.PowerShellPane.Transport

  @impl true
  def start(cwd, env, cols, rows, _opts) do
    with {:ok, term} <- Ghostty.Terminal.start_link(cols: cols, rows: rows),
         {:ok, pty} <- Ghostty.PTY.start_link(cwd: cwd, env: env, cols: cols, rows: rows) do
      {:ok, term, pty}
    end
  end

  @impl true
  def write(pty, data), do: Ghostty.PTY.write(pty, data)

  @impl true
  def resize(term, pty, cols, rows) do
    case Ghostty.Terminal.resize(term, cols, rows) do
      :ok -> Ghostty.PTY.resize(pty, cols, rows)
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def terminal_write(term, data), do: Ghostty.Terminal.write(term, data)

  @impl true
  def close(term, pty) do
    if is_pid(pty) and Process.alive?(pty), do: Ghostty.PTY.close(pty)
    if is_pid(term) and Process.alive?(term), do: GenServer.stop(term)
    :ok
  catch
    :exit, _ -> :ok
  end
end
