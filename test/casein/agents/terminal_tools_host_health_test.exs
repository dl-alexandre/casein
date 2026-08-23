defmodule Casein.Agents.TerminalToolsHostHealthTest do
  use ExUnit.Case, async: false

  alias Casein.Agents.TerminalTools
  alias Casein.Terminals.HostHealth

  test "terminal_host_health is advertised as a read-only snapshot" do
    tool = Enum.find(TerminalTools.definitions(), &(&1.name == "terminal_host_health"))

    assert tool
    assert tool.description =~ "Host health"
    assert {:ok, snapshot} = TerminalTools.invoke("terminal_host_health", %{})
    assert snapshot.state in ~w(healthy warning pressure stuck stale unknown)
    assert snapshot.uri == "casein://host/health"
  end

  test "the tool returns the same snapshot HostHealth.snapshot/1 builds" do
    previous = Application.get_env(:casein, :host_health)

    path =
      Path.join(
        System.tmp_dir!(),
        "casein-host-health-tool-#{System.unique_integer([:positive])}.json"
      )

    sampled_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Application.put_env(:casein, :host_health,
      status_path: path,
      alerts_path: path <> ".alerts",
      host: "milc-devbox",
      stale_after_seconds: 720,
      max_alerts: 5
    )

    on_exit(fn ->
      File.rm(path)

      if previous,
        do: Application.put_env(:casein, :host_health, previous),
        else: Application.delete_env(:casein, :host_health)
    end)

    File.write!(
      path,
      Jason.encode!(%{
        "timestamp" => sampled_at,
        "load1" => 1.25,
        "runnable" => 3,
        "cpu_idle_pct" => 90,
        "mem_available_kb" => 8_000_000,
        "swap_used_kb" => 0,
        "d_state_processes" => 0,
        "d_state_streak" => 0,
        "opencode_processes" => 2,
        "beam_processes" => 1,
        "warning" => 0,
        "alert" => "none"
      })
    )

    {:ok, tool} = TerminalTools.host_health(%{})
    direct = HostHealth.snapshot()

    assert tool.state == direct.state
    assert tool.sampled_at == direct.sampled_at
    assert tool.host == direct.host
    assert tool.state == "healthy"
    assert tool.sampled_at == sampled_at
  end
end
