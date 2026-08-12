defmodule Casein.Deployment.DrainClockPrototypeTest do
  use Casein.TestCase, async: false

  alias Casein.Clock
  alias Casein.Deployment.Drain

  defmodule Holder do
    use GenServer

    def start, do: GenServer.start(__MODULE__, [])
    def init(_opts), do: {:ok, %{}}
  end

  setup do
    prev_stop = Application.get_env(:casein, :drain_stop_system)
    parent = self()

    Application.put_env(:casein, :drain_stop_system, fn status ->
      send(parent, {:drain_stopped, status, Clock.now_ms()})
      :ok
    end)

    start_supervised!(Casein.Clock.Scheduler)
    Drain.reset_for_test!()

    on_exit(fn ->
      Drain.reset_for_test!()
      restore(:drain_stop_system, prev_stop)
    end)

    :ok
  end

  test "scripted drain replay is identical across 20 isolated runs" do
    traces = for _ <- 1..20, do: scripted_two_drop()
    assert [_] = Enum.uniq(traces)
  end

  test "same seed replays the same timer-and-script sequence" do
    first = replay_seed(42)
    second = replay_seed(42)
    other = replay_seed(43)

    assert first == second
    refute first == other
  end

  test "DOWN vs auto_reconnect at one logical instant is not uniquely ordered" do
    reconnect_first = interleave(:reconnect_then_down)
    down_first = interleave(:down_then_reconnect)

    refute reconnect_first == down_first
    assert reconnect_first.reconnect?
    refute down_first.reconnect?
    assert reconnect_first.grace? == down_first.grace?
  end

  test "sys.get_state is not a safe barrier after step" do
    drain = Process.whereis(Drain)
    assert :ok = Drain.start_drain(0)
    Clock.sync(Drain)
    :ok = :sys.suspend(drain)
    assert {:ok, %{msg: :grace_timeout}} = Clock.step()

    stale = :sys.get_state(drain)
    assert stale.draining
    assert is_reference(stale.grace_ref)
    refute_receive {:drain_stopped, _, _}, 20

    :ok = :sys.resume(drain)
    Clock.sync(Drain)
    assert_receive {:drain_stopped, 0, 5_000}
  end

  defp scripted_two_drop do
    reset_run()
    {h1, h2} = track_two()

    events = [snap(:tracked)]
    :ok = Drain.start_drain(0)
    assert_receive {:update_available, _version, 0}
    events = events ++ [snap(:draining)]

    assert {:ok, []} = Clock.advance_to(1_000)
    stop_holder(h1)
    events = events ++ [snap(:drop_h1)]

    assert {:ok, []} = Clock.advance_to(2_000)
    stop_holder(h2)
    events = events ++ [snap(:drop_h2)]

    assert {:ok, %{msg: :grace_timeout, due_ms: 7_000}} = Clock.step()
    Clock.sync(Drain)
    assert_receive {:drain_stopped, 0, 7_000}
    events ++ [snap(:stopped)]
  end

  defp replay_seed(seed) do
    reset_run()
    :rand.seed(:exsss, {seed, seed, seed})
    t1 = 1_000 + :rand.uniform(4_000)
    t2 = t1 + 1_000 + :rand.uniform(4_000)
    {h1, h2} = track_two()

    :ok = Drain.start_drain(0)
    assert_receive {:update_available, _version, 0}

    assert {:ok, []} = Clock.advance_to(t1)
    stop_holder(h1)
    assert {:ok, []} = Clock.advance_to(t2)
    stop_holder(h2)

    assert {:ok, %{msg: :grace_timeout, due_ms: due}} = Clock.step()
    Clock.sync(Drain)
    assert_receive {:drain_stopped, 0, ^due}
    {t1, t2, due, snap(:stopped)}
  end

  defp interleave(order) do
    reset_run()
    {:ok, holder} = Holder.start()
    Drain.track(holder)
    Clock.sync(Drain)
    :ok = Drain.start_drain(0)
    assert_receive {:update_available, _version, 0}

    Clock.sync(Drain)
    state = :sys.get_state(Process.whereis(Drain))
    if state.auto_ref, do: Clock.cancel_timer(state.auto_ref)
    assert {:ok, []} = Clock.advance_to(90_000)

    reconnect? =
      case order do
        :reconnect_then_down ->
          send(Process.whereis(Drain), :auto_reconnect)
          Clock.sync(Drain)
          assert_receive {:deploy_reconnect}
          stop_holder(holder)
          true

        :down_then_reconnect ->
          stop_holder(holder)
          send(Process.whereis(Drain), :auto_reconnect)
          Clock.sync(Drain)
          refute_receive {:deploy_reconnect}, 50
          false
      end

    snap = snap(:end)
    %{order: order, reconnect?: reconnect?, grace?: elem(snap, 2).grace?}
  end

  defp reset_run do
    Drain.reset_for_test!()
    Clock.reset()
    Phoenix.PubSub.unsubscribe(Casein.PubSub, "deploy:updates")
    flush_deploy_updates()
    flush_stops()
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "deploy:updates")
  end

  defp flush_stops do
    receive do
      {:drain_stopped, _, _} -> flush_stops()
    after
      0 -> :ok
    end
  end

  defp track_two do
    {:ok, h1} = Holder.start()
    {:ok, h2} = Holder.start()
    Drain.track(h1)
    Drain.track(h2)
    Clock.sync(Drain)
    {h1, h2}
  end

  defp stop_holder(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    Clock.sync(Drain)
  end

  defp snap(tag) do
    Clock.sync(Drain)
    state = :sys.get_state(Process.whereis(Drain))

    {tag, Clock.now_ms(),
     %{
       count: state.count,
       draining: state.draining,
       grace?: is_reference(state.grace_ref),
       auto?: is_reference(state.auto_ref),
       hard?: is_reference(state.hard_ref)
     }}
  end

  defp flush_deploy_updates do
    receive do
      {:update_available, _, _} -> flush_deploy_updates()
      {:deploy_reconnect} -> flush_deploy_updates()
    after
      0 -> :ok
    end
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)
end
