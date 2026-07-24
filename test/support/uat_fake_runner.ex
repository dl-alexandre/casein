defmodule Casein.UAT.FakeRunner do
  @moduledoc """
  In-memory `Casein.UAT.Instance.Runner` for tests. Records launch/seed/kill into
  the *calling* process dictionary (Instance drives the runner synchronously), so
  a test can assert teardown killed the exact handle — never a broad pattern —
  and that probe retries behave, without booting a real instance.

  Configure the probe outcome before boot with `set_probe/1`:

      Casein.UAT.FakeRunner.set_probe(:ok)
      Casein.UAT.FakeRunner.set_probe({:error, :econnrefused})
  """

  @behaviour Casein.UAT.Instance.Runner

  @os_pid 4242

  def set_probe(result), do: Process.put({__MODULE__, :probe}, result)
  def launched, do: Process.get({__MODULE__, :launched})
  def seeded, do: Process.get({__MODULE__, :seeded})
  def killed, do: Process.get({__MODULE__, :killed}, [])
  def os_pid, do: @os_pid

  @impl true
  def launch(spec) do
    Process.put({__MODULE__, :launched}, spec)
    {:ok, %{os_pid: @os_pid}}
  end

  @impl true
  def probe(_base_url), do: Process.get({__MODULE__, :probe}, :ok)

  @impl true
  def seed(seed_cmd, workspaces_root) do
    Process.put({__MODULE__, :seeded}, {seed_cmd, workspaces_root})
    :ok
  end

  @impl true
  def kill(handle) do
    Process.put({__MODULE__, :killed}, [handle | killed()])
    :ok
  end
end
