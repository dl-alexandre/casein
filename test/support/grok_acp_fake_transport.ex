defmodule Casein.Test.GrokACPFakeTransport do
  @behaviour Casein.AgentSessions.GrokACP.Transport

  @impl true
  def start(owner, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:grok_acp_transport_started, owner})
    {:ok, %{owner: owner, test_pid: test_pid}}
  end

  @impl true
  def write(%{owner: owner, test_pid: test_pid}, data) do
    send(test_pid, {:grok_acp_transport_write, owner, IO.iodata_to_binary(data)})
    :ok
  end

  @impl true
  def stop(%{owner: owner, test_pid: test_pid}) do
    send(test_pid, {:grok_acp_transport_stopped, owner})
    :ok
  end
end
