defmodule DevIDE.LogsTest.FakeLogsAdapter do
  @moduledoc false
  @behaviour DevIDE.Logs.Adapter

  @impl true
  def start_stream(workspace_id, service, pid) do
    ref = make_ref()
    send(pid, {:fake_adapter_started, workspace_id, service, ref})
    {:ok, ref}
  end

  @impl true
  def stop_stream(ref) do
    # The behaviour only hands us the ref, so prove dispatch via the return
    # value instead of message passing.
    {:fake_adapter_stopped, ref}
  end
end

defmodule DevIDE.LogsTest.FakeWorkspaceSource do
  @moduledoc false

  def stream_logs("ws-down", _service, _pid), do: {:error, :backend_down}

  def stream_logs(workspace_id, service, pid) do
    ref = make_ref()
    send(pid, {:fake_source_streaming, workspace_id, service, ref})
    {:ok, ref, :fake_task}
  end
end

defmodule DevIDE.LogsTest do
  # async: false — these tests mutate global application env
  # (:logs_adapter / :workspace_source).
  use ExUnit.Case, async: false

  alias DevIDE.Logs.Adapter
  alias DevIDE.Logs.SSE
  alias DevIDE.LogsTest.FakeLogsAdapter
  alias DevIDE.LogsTest.FakeWorkspaceSource

  setup do
    prev_adapter = Application.get_env(:dev_ide, :logs_adapter)
    prev_source = Application.get_env(:dev_ide, :workspace_source)

    on_exit(fn ->
      restore_env(:logs_adapter, prev_adapter)
      restore_env(:workspace_source, prev_source)
    end)

    :ok
  end

  describe "DevIDE.Logs.Adapter dispatch" do
    test "start_stream dispatches to the configured adapter with an explicit pid" do
      Application.put_env(:dev_ide, :logs_adapter, FakeLogsAdapter)

      assert {:ok, ref} = Adapter.start_stream("ws-1", "web", self())
      assert is_reference(ref)
      assert_receive {:fake_adapter_started, "ws-1", "web", ^ref}
    end

    test "start_stream defaults the subscriber pid to the caller" do
      Application.put_env(:dev_ide, :logs_adapter, FakeLogsAdapter)

      assert {:ok, ref} = Adapter.start_stream("ws-2", "db")
      assert_receive {:fake_adapter_started, "ws-2", "db", ^ref}
    end

    test "stop_stream dispatches to the configured adapter" do
      Application.put_env(:dev_ide, :logs_adapter, FakeLogsAdapter)

      ref = make_ref()
      assert {:fake_adapter_stopped, ^ref} = Adapter.stop_stream(ref)
    end

    test "defaults to the SSE adapter when nothing is configured" do
      Application.delete_env(:dev_ide, :logs_adapter)
      Application.put_env(:dev_ide, :workspace_source, FakeWorkspaceSource)

      assert {:ok, ref} = Adapter.start_stream("ws-default", "web", self())
      assert_receive {:fake_source_streaming, "ws-default", "web", ^ref}
      assert :ok = Adapter.stop_stream(ref)
    end
  end

  describe "DevIDE.Logs.SSE" do
    test "start_stream maps a source {:ok, ref, task} to {:ok, ref}" do
      Application.put_env(:dev_ide, :workspace_source, FakeWorkspaceSource)

      assert {:ok, ref} = SSE.start_stream("ws-1", "web", self())
      assert_receive {:fake_source_streaming, "ws-1", "web", ^ref}
    end

    test "start_stream passes source errors through unchanged" do
      Application.put_env(:dev_ide, :workspace_source, FakeWorkspaceSource)

      assert {:error, :backend_down} = SSE.start_stream("ws-down", "web", self())
    end

    test "start_stream with the Local source is not supported" do
      Application.put_env(:dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local)

      assert {:error, :not_supported} = SSE.start_stream("ws-1", "web", self())
    end

    test "stop_stream is a no-op returning :ok" do
      assert :ok = SSE.stop_stream(make_ref())
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
