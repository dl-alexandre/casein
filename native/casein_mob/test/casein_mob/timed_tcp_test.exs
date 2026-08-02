defmodule CaseinMob.TimedTCPTest do
  use ExUnit.Case, async: true

  alias CaseinMob.TimedTCP

  @loopback {127, 0, 0, 1}
  @socket_options [:binary, active: false]

  test "connect strips the private timing option and reports start and success to its exact target" do
    {listener, port} = open_listener(:gen_tcp)
    relay = start_relay(self())
    generation = generation(1)
    before_connect = System.monotonic_time()

    assert {:ok, client} =
             TimedTCP.connect(
               @loopback,
               port,
               @socket_options ++ [casein_timing: {relay, generation}],
               1_000
             )

    after_connect = System.monotonic_time()
    assert {:ok, server} = :gen_tcp.accept(listener, 1_000)

    assert_receive {:relayed_timing,
                    {:casein_tcp_timing, ^generation, :tcp_connect_started, started_at}}

    assert_receive {:relayed_timing,
                    {:casein_tcp_timing, ^generation, :tcp_connected, connected_at}}

    assert is_integer(started_at)
    assert is_integer(connected_at)
    assert started_at >= before_connect
    assert connected_at >= started_at
    assert connected_at <= after_connect
    refute_received {:casein_tcp_timing, _, _, _}
    refute_receive {:relayed_timing, _}, 20

    close_sockets([client, server, listener])
    stop_supervised_task(relay)
  end

  test "OTP SSL cb_info invokes the wrapper before a bounded handshake failure" do
    {listener, port} = open_listener(:gen_tcp)
    acceptor = start_closing_acceptor(self(), listener)
    acceptor_monitor = Process.monitor(acceptor)
    relay = start_relay(self())
    generation = generation(4)
    before_connect = System.monotonic_time()

    assert {:error, _reason} =
             :ssl.connect(
               @loopback,
               port,
               @socket_options ++
                 [
                   verify: :verify_none,
                   cb_info: {TimedTCP, :tcp, :tcp_closed, :tcp_error, :tcp_passive},
                   casein_timing: {relay, generation}
                 ],
               1_000
             )

    after_connect = System.monotonic_time()

    assert_receive {:plain_tcp_closed, ^acceptor}
    assert_receive {:DOWN, ^acceptor_monitor, :process, ^acceptor, :normal}

    assert_receive {:relayed_timing,
                    {:casein_tcp_timing, ^generation, :tcp_connect_started, started_at}}

    assert_receive {:relayed_timing,
                    {:casein_tcp_timing, ^generation, :tcp_connected, connected_at}}

    assert started_at >= before_connect
    assert connected_at >= started_at
    assert connected_at <= after_connect
    refute_receive {:relayed_timing, _unexpected_timing}, 20

    stop_supervised_task(relay)
  end

  test "connect failure reports start without reporting a false success" do
    {listener, port} = open_listener(:gen_tcp)
    :ok = :gen_tcp.close(listener)

    relay = start_relay(self())
    generation = generation(2)
    before_connect = System.monotonic_time()

    assert {:error, _reason} =
             TimedTCP.connect(
               @loopback,
               port,
               @socket_options ++ [casein_timing: {relay, generation}],
               1_000
             )

    after_connect = System.monotonic_time()

    assert_receive {:relayed_timing,
                    {:casein_tcp_timing, ^generation, :tcp_connect_started, started_at}}

    assert is_integer(started_at)
    assert started_at >= before_connect
    assert started_at <= after_connect

    refute_receive {:relayed_timing, _unexpected_timing}, 50

    stop_supervised_task(relay)
  end

  test "missing and malformed private timing options are stripped and emit nothing" do
    {listener, port} = open_listener(:gen_tcp)

    timing_options = [
      [],
      [casein_timing: nil],
      [casein_timing: :malformed],
      [casein_timing: {self()}],
      [casein_timing: {:not_a_pid, generation(3)}]
    ]

    Enum.each(timing_options, fn timing_option ->
      assert {:ok, client} =
               TimedTCP.connect(
                 @loopback,
                 port,
                 @socket_options ++ timing_option,
                 1_000
               )

      assert {:ok, server} = :gen_tcp.accept(listener, 1_000)
      close_sockets([client, server])
    end)

    refute_receive {:casein_tcp_timing, _, _, _}, 50
    :ok = :gen_tcp.close(listener)
  end

  test "delegates the TCP callback surface to loopback sockets" do
    {listener, port} = open_listener(TimedTCP)

    assert {:ok, client} = :gen_tcp.connect(@loopback, port, @socket_options, 1_000)
    assert {:ok, server} = TimedTCP.accept(listener, 1_000)

    assert :ok = TimedTCP.setopts(server, nodelay: true)
    assert {:ok, options} = TimedTCP.getopts(server, [:active, :nodelay])
    assert options[:active] == false
    assert options[:nodelay] == true

    assert :ok = TimedTCP.send(server, "pong")
    assert {:ok, "pong"} = TimedTCP.recv(client, 4, 1_000)

    assert :ok = :gen_tcp.send(client, "ping")
    assert {:ok, "ping"} = TimedTCP.recv(server, 4)

    assert {:ok, stats} = TimedTCP.getstat(server, [:recv_oct, :send_oct])
    assert is_integer(stats[:recv_oct])
    assert is_integer(stats[:send_oct])

    assert {:ok, {@loopback, ^port}} = TimedTCP.sockname(listener)
    assert {:ok, {@loopback, client_port}} = TimedTCP.peername(server)
    assert {:ok, {@loopback, ^client_port}} = TimedTCP.sockname(client)
    assert {:ok, server_port} = TimedTCP.port(server)
    assert server_port == port

    owner = start_socket_owner(self())
    assert :ok = TimedTCP.controlling_process(server, owner)
    send(owner, {:return_socket, server, self()})
    assert_receive {:socket_returned, ^owner, :ok}

    assert :ok = TimedTCP.shutdown(server, :write)
    assert :ok = TimedTCP.close(server)
    assert :ok = TimedTCP.close(client)
    assert :ok = TimedTCP.close(listener)

    stop_supervised_task(owner)
  end

  defp open_listener(module) do
    assert {:ok, listener} =
             module.listen(0, @socket_options ++ [reuseaddr: true, ip: @loopback])

    assert {:ok, {@loopback, port}} = :inet.sockname(listener)
    {listener, port}
  end

  defp start_relay(parent) do
    start_supervised!(
      Supervisor.child_spec({Task, fn -> relay_timing(parent) end}, id: make_ref())
    )
  end

  defp relay_timing(parent) do
    receive do
      :stop ->
        :ok

      timing ->
        send(parent, {:relayed_timing, timing})
        relay_timing(parent)
    end
  end

  defp start_socket_owner(parent) do
    start_supervised!(Supervisor.child_spec({Task, fn -> own_socket(parent) end}, id: make_ref()))
  end

  defp start_closing_acceptor(parent, listener) do
    acceptor =
      start_supervised!(
        Supervisor.child_spec({Task, fn -> close_first_connection(parent) end}, id: make_ref())
      )

    :ok = :gen_tcp.controlling_process(listener, acceptor)
    send(acceptor, {:accept, listener})
    acceptor
  end

  defp close_first_connection(parent) do
    receive do
      {:accept, listener} ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        :ok = :gen_tcp.close(socket)
        :ok = :gen_tcp.close(listener)
        send(parent, {:plain_tcp_closed, self()})
    end
  end

  defp own_socket(parent) do
    receive do
      {:return_socket, socket, return_to} ->
        result = TimedTCP.controlling_process(socket, return_to)
        send(parent, {:socket_returned, self(), result})
        own_socket(parent)

      :stop ->
        :ok
    end
  end

  defp stop_supervised_task(pid) do
    monitor = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  defp close_sockets(sockets) do
    Enum.each(sockets, &:gen_tcp.close/1)
  end

  defp generation(byte),
    do: Base.url_encode64(:binary.copy(<<byte>>, 16), padding: false)
end
