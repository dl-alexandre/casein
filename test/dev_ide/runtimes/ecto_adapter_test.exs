defmodule Casein.Runtimes.EctoAdapterTest do
  use Casein.DataCase, async: false

  alias Casein.Runtimes
  alias Casein.Test.RuntimeSeed

  setup do
    Casein.Runtimes.EctoAdapter.clear()

    prev_runtime = Application.get_env(:casein, :runtimes_adapter)
    Application.put_env(:casein, :runtimes_adapter, Casein.Runtimes.EctoAdapter)

    on_exit(fn ->
      Casein.Runtimes.EctoAdapter.clear()

      if prev_runtime,
        do: Application.put_env(:casein, :runtimes_adapter, prev_runtime),
        else: Application.delete_env(:casein, :runtimes_adapter)
    end)

    :ok
  end

  test "runtime projections and lifecycle events persist through Ecto" do
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
