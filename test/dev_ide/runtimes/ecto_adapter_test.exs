defmodule DevIDE.Runtimes.EctoAdapterTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Runtimes
  alias DevIDE.Test.RuntimeSeed

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
      RuntimeSeed.seed_runtime("ws-ecto-runtime",
        runtime_id: "rt-ecto",
        host_id: "ecto-host",
        status: "provisioned",
        repo: "onebackend-v3",
        branch: "main",
        worktree_path: "/tmp/ws-ecto-runtime/.devide/runtimes/rt-ecto"
      )

    assert runtime.status == "provisioned"

    assert {:ok, fetched} = Runtimes.get_runtime(runtime.id)
    assert fetched.repo == "onebackend-v3"
    assert fetched.status == "provisioned"

    events = Runtimes.events_for(runtime.id)
    assert Enum.map(events, & &1.event) == ~w(runtime_requested)
    assert {:ok, "requested"} = Runtimes.project_lifecycle(events)
  end
end
