defmodule CaseinMob.TimedTCP do
  @moduledoc """
  `:gen_tcp` callback used by OTP TLS to expose the real TCP connect boundary.

  The wrapper delegates the complete transport contract and consumes one
  private option before calling `:gen_tcp`. It sends only the connection
  generation, an allowlisted stage, and a monotonic timestamp to the owning
  session client; endpoints and socket errors never cross this boundary.
  """

  import Kernel, except: [send: 2]

  @timing_option :casein_timing
  @generation_bytes 16
  @generation_length 22

  @spec connect(:inet.socket_address() | :inet.hostname(), :inet.port_number(), list(), timeout()) ::
          {:ok, port()} | {:error, term()}
  def connect(address, port, options, timeout) do
    {timing_target, tcp_options} = pop_timing_option(options)
    emit(timing_target, :tcp_connect_started)

    case :gen_tcp.connect(address, port, tcp_options, timeout) do
      {:ok, _socket} = connected ->
        emit(timing_target, :tcp_connected)
        connected

      {:error, _reason} = error ->
        error
    end
  end

  @spec listen(:inet.port_number(), list()) :: {:ok, port()} | {:error, term()}
  def listen(port, options) do
    {_timing_target, tcp_options} = pop_timing_option(options)
    :gen_tcp.listen(port, tcp_options)
  end

  @spec accept(port(), timeout()) :: {:ok, port()} | {:error, term()}
  def accept(listen_socket, timeout), do: :gen_tcp.accept(listen_socket, timeout)

  @spec send(port(), iodata()) :: :ok | {:error, term()}
  def send(socket, data), do: :gen_tcp.send(socket, data)

  @spec recv(port(), non_neg_integer()) :: {:ok, binary() | list()} | {:error, term()}
  def recv(socket, length), do: :gen_tcp.recv(socket, length)

  @spec recv(port(), non_neg_integer(), timeout()) ::
          {:ok, binary() | list()} | {:error, term()}
  def recv(socket, length, timeout), do: :gen_tcp.recv(socket, length, timeout)

  @spec close(port()) :: :ok
  def close(socket), do: :gen_tcp.close(socket)

  @spec shutdown(port(), :read | :write | :read_write) :: :ok | {:error, term()}
  def shutdown(socket, how), do: :gen_tcp.shutdown(socket, how)

  @spec controlling_process(port(), pid()) :: :ok | {:error, term()}
  def controlling_process(socket, pid), do: :gen_tcp.controlling_process(socket, pid)

  @spec setopts(port(), list()) :: :ok | {:error, term()}
  def setopts(socket, options), do: :inet.setopts(socket, options)

  @spec getopts(port(), list()) :: {:ok, list()} | {:error, term()}
  def getopts(socket, options), do: :inet.getopts(socket, options)

  @spec getstat(port(), list()) :: {:ok, list()} | {:error, term()}
  def getstat(socket, options), do: :inet.getstat(socket, options)

  @spec peername(port()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def peername(socket), do: :inet.peername(socket)

  @spec sockname(port()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def sockname(socket), do: :inet.sockname(socket)

  @spec port(port()) :: {:ok, :inet.port_number()} | {:error, term()}
  def port(socket), do: :inet.port(socket)

  defp pop_timing_option(options) when is_list(options) do
    timing_target = List.keyfind(options, @timing_option, 0)
    tcp_options = List.keydelete(options, @timing_option, 0)

    case timing_target do
      {@timing_option, target} -> {target, remove_timing_options(tcp_options)}
      nil -> {nil, tcp_options}
    end
  end

  defp pop_timing_option(options), do: {nil, options}

  defp remove_timing_options(options),
    do: Enum.reject(options, &match?({@timing_option, _value}, &1))

  defp emit({pid, generation}, stage)
       when is_pid(pid) and stage in [:tcp_connect_started, :tcp_connected] do
    if valid_generation?(generation) do
      Kernel.send(pid, {:casein_tcp_timing, generation, stage, System.monotonic_time()})
    end

    :ok
  end

  defp emit(_target, _stage), do: :ok

  defp valid_generation?(generation)
       when is_binary(generation) and byte_size(generation) == @generation_length do
    case Base.url_decode64(generation, padding: false) do
      {:ok, decoded} when byte_size(decoded) == @generation_bytes ->
        Base.url_encode64(decoded, padding: false) == generation

      _invalid ->
        false
    end
  end

  defp valid_generation?(_generation), do: false
end
