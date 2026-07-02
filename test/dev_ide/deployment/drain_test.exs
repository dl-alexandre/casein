defmodule DevIDE.Deployment.DrainTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Deployment.Drain

  setup do
    Drain.reset_for_test!()
    on_exit(fn -> Drain.reset_for_test!() end)
    :ok
  end

  defmodule Holder do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{}}
  end

  test "track increments and decrements the live connection count" do
    base = Drain.connection_count()
    {:ok, holder} = start_supervised({Holder, []})

    assert :ok = Drain.track(holder)
    assert Drain.connection_count() == base + 1

    ref = Process.monitor(holder)
    GenServer.stop(holder)

    assert_receive {:DOWN, ^ref, :process, ^holder, _reason}, 1_000
    assert Drain.connection_count() == base
  end

  test "start_drain broadcasts update availability while connections remain" do
    :ok = Phoenix.PubSub.subscribe(DevIde.PubSub, "deploy:updates")
    {:ok, holder} = start_supervised({Holder, []})
    assert :ok = Drain.track(holder)

    assert :ok = Drain.start_drain(3)
    assert Drain.draining?()

    assert_receive {:update_available, version, 3}
    assert is_binary(version)

    assert {:error, :already_draining} = Drain.start_drain(1)
  end
end
