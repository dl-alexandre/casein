defmodule Casein.Deployment.DrainTest do
  use Casein.TestCase, async: false

  alias Casein.Deployment.Drain

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
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "deploy:updates")
    {:ok, holder} = start_supervised({Holder, []})
    assert :ok = Drain.track(holder)

    assert :ok = Drain.start_drain(3)
    assert Drain.draining?()

    assert_receive {:update_available, version, 3}
    assert is_binary(version)

    assert {:error, :already_draining} = Drain.start_drain(1)
  end

  test "auto_reconnect nudges still-attached clients to move off the draining node" do
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "deploy:updates")
    {:ok, holder} = start_supervised({Holder, []})
    assert :ok = Drain.track(holder)

    assert :ok = Drain.start_drain(0)
    assert_receive {:update_available, _version, 0}

    # Simulate the @auto_reconnect_ms timer firing without waiting it out.
    send(Process.whereis(Drain), :auto_reconnect)
    assert_receive {:deploy_reconnect}
  end

  test "auto_reconnect stays silent once connections have already drained" do
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "deploy:updates")

    assert :ok = Drain.start_drain(0)
    assert_receive {:update_available, _version, 0}

    # No tracked connections (count == 0): the grace/stop path owns shutdown,
    # so there is no one to nudge.
    send(Process.whereis(Drain), :auto_reconnect)
    refute_receive {:deploy_reconnect}, 200
  end

  test "guard_shared_write runs the callback when not draining" do
    assert Drain.guard_shared_write(fn -> :ran end) == :ran
  end

  test "guard_shared_write returns :noop while draining" do
    assert :ok = Drain.start_drain(0)
    assert Drain.guard_shared_write(fn -> flunk("should not run") end) == :noop
  end
end
