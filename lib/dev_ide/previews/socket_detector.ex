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

  alias DevIDE.Integrations.Manager.WorkspaceSource
  alias DevIDE.Workspaces

  @max_ports 8

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

  @doc """
  Returns sorted, de-duplicated listening dev-server ports for a workspace.

  System/infra ports are filtered out and the result is capped. Never raises.
  """
  @spec discover_ports(map()) :: [integer()]
  def discover_ports(workspace) when is_map(workspace) do
    with {:ok, cwd} <- host_cwd(workspace),
         {:ok, output} <- run_probe(cwd) do
      output
      |> parse_ports()
      |> Enum.reject(&MapSet.member?(@deny, &1))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(@max_ports)
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

  defp host_cwd(workspace) do
    case Workspaces.safe_host_path(workspace) do
      {:ok, path} -> {:ok, path}
      _ -> {:error, :no_host_path}
    end
  end

  # sobelow_skip ["CI.System"]
  defp run_probe(cwd) do
    case WorkspaceSource.prepare_local_argv(["sh", "-c", @probe]) do
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
end
