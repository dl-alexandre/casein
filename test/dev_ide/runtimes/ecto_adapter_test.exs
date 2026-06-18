defmodule DevIDE.Runtimes.EctoAdapterTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Runtimes

  setup do
    DevIDE.Runtimes.EctoAdapter.clear()

    prev_runtime = Application.get_env(:dev_ide, :runtimes_adapter)
    Application.put_env(:dev_ide, :runtimes_adapter, DevIDE.Runtimes.EctoAdapter)

    on_exit(fn ->
      DevIDE.Runtimes.EctoAdapter.clear()

      if prev_runtime,
        do: Application.put_env(:dev_ide, :runtimes_adapter, prev_runtime),
        else: Application.delete_env(:dev_ide, :runtimes_adapter)
    end)

    :ok
  end

  test "hosts, runtime projections, and lifecycle events persist through Ecto" do
    {:ok, host} =
      Runtimes.register_host(%{
        "host_id" => "ecto-host",
        "os" => "linux",
        "tools" => ["mix"],
        "capabilities" => ["workspace-command:v1"],
        "concurrency_limit" => 2
      })

    assert host.id == "ecto-host"

    {:ok, runtime} =
      Runtimes.request_runtime("ws-ecto-runtime", %{
        "runtime_id" => "rt-ecto",
        "host_id" => "ecto-host",
        "repo" => "onebackend-v3",
        "branch" => "main",
        "worktree_path" => "/tmp/ws-ecto-runtime/.devide/runtimes/rt-ecto"
      })

    {:ok, provisioned} = Runtimes.provision_runtime(runtime.id)
    {:ok, bound} = Runtimes.bind_runtime(runtime.id, %{"assignment_id" => "asgn-ecto"})

    assert provisioned.status == "provisioned"
    assert bound.status == "bound"

    assert {:ok, fetched} = Runtimes.get_runtime(runtime.id)
    assert fetched.repo == "onebackend-v3"

    events = Runtimes.events_for(runtime.id)
    assert Enum.map(events, & &1.event) == ~w(runtime_requested runtime_provisioned runtime_bound)
    assert {:ok, "bound"} = Runtimes.project_lifecycle(events)
  end
end
