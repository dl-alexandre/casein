defmodule DevIDE.Previews.SocketDetector do
  @moduledoc """
  Detects dev-server ports by inspecting **listening TCP sockets** inside the
  workspace, instead of scraping them from printed terminal output.

  This is the reliable counterpart to `DevIDE.Previews.Detector` (which regexes
  `localhost:PORT` out of scrollback): a server that never prints its URL, or
  whose banner has scrolled away, is still found here.

  The probe runs `ss` (falling back to `lsof`) through
  `WorkspaceSource.prepare_local_argv/2`, so it executes **inside the workspace
  container** in on-host mode (where the dev server's ports live in the
  container's network namespace) and directly on the host for local workspaces.

  Returns numeric ports only; the caller maps them to preview surfaces.
  Best-effort: any failure (no `ss`/`lsof`, container down, no host path)
  yields `[]` and the caller falls back to regex detection.
  """

  require Logger

  alias DevIDE.WorkspaceSource.Manager, as: WorkspaceSource
  alias DevIDE.Workspaces

  @max_ports 8

  @attached_probe "ss -Htlnp 2>/dev/null || ss -ltnp 2>/dev/null || true"

  # Listening ports we never surface as browser previews: databases, caches,
  # message brokers, and host infra. Dev HTTP servers live elsewhere.
  @deny MapSet.new([
          22,
          25,
          53,
          111,
          123,
          631,
          2049,
          3306,
          5432,
          5672,
          6379,
          9092,
          11_211,
          27_017
        ])

  # Try `ss` first (fast, present in most images), then a header-ful `ss`, then
  # `lsof`. `|| true` keeps the shell exit status clean so System.cmd never
  # surfaces a non-zero code for "tool missing". Parsing keys off the "LISTEN"
  # token so header lines from the fallbacks are ignored.
  @probe "ss -Htln 2>/dev/null || ss -ltn 2>/dev/null || lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null || true"

  @port_regex ~r/:(\d{2,5})\b/
  @pid_regex ~r/pid=(\d+)/

  @doc """
  Returns sorted, de-duplicated listening dev-server ports for a workspace.

  System/infra ports are filtered out and the result is capped. Never raises.
  """
  @spec discover_ports(map()) :: [integer()]
  def discover_ports(workspace) when is_map(workspace) do
    with {:ok, cwd} <- host_cwd(workspace) do
      workspace
      |> probe_ports(cwd)
      |> normalize_ports()
    else
      _ -> []
    end
  end

  def discover_ports(_), do: []

  @doc false
  # Exposed for tests: parse `ss`/`lsof` output into listening ports.
  @spec parse_ports(String.t()) :: [integer()]
  def parse_ports(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "LISTEN"))
    |> Enum.flat_map(fn line ->
      @port_regex
      |> Regex.scan(line)
      |> Enum.map(fn [_, port] -> String.to_integer(port) end)
    end)
    |> Enum.filter(&(&1 > 0 and &1 < 65_536))
  end

  def parse_ports(_), do: []

  @doc false
  @spec ports_for_workspace_cwd(String.t(), String.t(), (integer() -> String.t() | nil)) :: [
          integer()
        ]
  def ports_for_workspace_cwd(output, cwd, read_cwd_fun \\ &process_cwd/1)

  def ports_for_workspace_cwd(output, cwd, read_cwd_fun)
      when is_binary(output) and is_binary(cwd) and is_function(read_cwd_fun, 1) do
    workspace_cwd = Path.expand(cwd)

    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "LISTEN"))
    |> Enum.flat_map(fn line ->
      with [_, port] <- Regex.run(@port_regex, line),
           [_, pid] <- Regex.run(@pid_regex, line),
           {port, ""} <- Integer.parse(port),
           {pid, ""} <- Integer.parse(pid),
           proc_cwd when is_binary(proc_cwd) <- read_cwd_fun.(pid),
           true <- under_path?(Path.expand(proc_cwd), workspace_cwd) do
        [port]
      else
        _ -> []
      end
    end)
  end

  def ports_for_workspace_cwd(_, _, _), do: []

  defp host_cwd(workspace) do
    case Workspaces.safe_host_path(workspace) do
      {:ok, path} -> {:ok, path}
      _ -> {:error, :no_host_path}
    end
  end

  # sobelow_skip ["CI.System"]
  defp run_probe(argv, cwd) do
    case argv do
      [cmd | args] ->
        {out, _code} =
          System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true, env: [{"TERM", "dumb"}])

        {:ok, out}

      _ ->
        {:error, :no_argv}
    end
  rescue
    e in [ErlangError, File.Error] ->
      Logger.debug("socket port probe failed: #{inspect(e)}")
      {:error, :probe_failed}
  catch
    :exit, reason ->
      Logger.debug("socket port probe exited: #{inspect(reason)}")
      {:error, :probe_exit}
  end

  defp probe_ports(workspace, cwd) do
    if attached_folder?(workspace) do
      host_cwd_ports(cwd, true)
    else
      source_ports =
        case run_probe(probe_argv(workspace), cwd) do
          {:ok, output} -> parse_ports(output)
          _ -> []
        end

      source_ports ++ host_cwd_ports(cwd, WorkspaceSource.on_host?())
    end
  end

  defp host_cwd_ports(cwd, enabled?) do
    if enabled? do
      case run_probe(["sh", "-c", @attached_probe], cwd) do
        {:ok, output} -> ports_for_workspace_cwd(output, cwd)
        _ -> []
      end
    else
      []
    end
  end

  @doc false
  def probe_argv(workspace) do
    if attached_folder?(workspace) do
      ["sh", "-c", @attached_probe]
    else
      argv = ["sh", "-c", @probe]
      WorkspaceSource.prepare_local_argv(argv)
    end
  end

  defp attached_folder?(%{metadata: %{attached_folder: true}}), do: true
  defp attached_folder?(%{metadata: %{"attached_folder" => true}}), do: true
  defp attached_folder?(_), do: false

  defp normalize_ports(ports) do
    ports
    |> Enum.filter(&is_integer/1)
    |> Enum.filter(&(&1 > 0 and &1 < 65_536))
    |> Enum.reject(&MapSet.member?(@deny, &1))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_ports)
  end

  defp process_cwd(pid) when is_integer(pid) do
    case File.read_link("/proc/#{pid}/cwd") do
      {:ok, cwd} -> cwd
      _ -> nil
    end
  end

  defp under_path?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end
end
