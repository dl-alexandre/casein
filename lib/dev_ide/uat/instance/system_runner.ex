defmodule DevIDE.UAT.Instance.SystemRunner do
  @moduledoc """
  Default `DevIDE.UAT.Instance.Runner` — boots a real dev instance from the
  working tree via `scripts/dev-preview-instance.sh` and tears it down by PID.

  > **Not exercised by the unit suite.** Booting a real Phoenix instance can't be
  > done safely or deterministically in CI-of-this-repo, so the lifecycle *logic*
  > is tested against a fake runner (`DevIDE.UAT.InstanceTest`) and this module is
  > verified by the Phase 2 live-smoke step (still open in the plan). Keep side
  > effects here thin and obvious.

  The launch handle retains the `Port` so teardown can close it after killing the
  OS process — and we kill the launched PID explicitly, never a broad pattern
  (see the devbox process-safety lesson).
  """

  @behaviour DevIDE.UAT.Instance.Runner

  @script "scripts/dev-preview-instance.sh"
  @probe_timeout 2_000

  @impl true
  def launch(%{port: port, workspaces_root: root, env: env}) do
    script = Path.join(File.cwd!(), @script)
    bash = System.find_executable("bash") || "/usr/bin/bash"

    port_ref =
      Port.open({:spawn_executable, bash}, [
        :binary,
        :exit_status,
        {:args, [script, "--foreground"]},
        {:cd, root},
        {:env, to_env_charlists(Map.put(env, "PORT", Integer.to_string(port)))}
      ])

    case Port.info(port_ref, :os_pid) do
      {:os_pid, os_pid} ->
        {:ok, %{port: port_ref, os_pid: os_pid}}

      nil ->
        if Port.info(port_ref), do: Port.close(port_ref)
        {:error, :no_os_pid}
    end
  end

  @impl true
  def probe(base_url) do
    _ = Application.ensure_all_started(:inets)
    url = String.to_charlist(base_url <> "/")

    case :httpc.request(:get, {url, []}, [{:timeout, @probe_timeout}], []) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def seed(seed_cmd, workspaces_root) do
    case System.cmd("bash", ["-lc", seed_cmd], cd: workspaces_root, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:seed_exit, code, out}}
    end
  end

  @impl true
  def kill(%{os_pid: os_pid} = handle) do
    _ = System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true)
    close_port(handle)
    :ok
  end

  defp close_port(%{port: port}) when is_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp close_port(_), do: :ok

  defp to_env_charlists(env) do
    Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end
end
