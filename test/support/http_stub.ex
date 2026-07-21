defmodule DevIDE.TestSupport.HTTPStub do
  @moduledoc """
  Bandit-backed localhost HTTP stub for tests.

  Drop-in replacement for Bypass: `open/1`, `expect/2`, `expect/4`,
  `expect_once/2`, `expect_once/4`, `stub/4`, `down/1`, `up/1`, and a
  `%HTTPStub{port: port}` struct. Handlers receive a `Plug.Conn` and must
  return one (typically via `Plug.Conn.resp/3`).

  Expectations are verified on ExUnit `on_exit`:

  * `expect` — route must be hit at least once
  * `expect_once` — route must be hit exactly once
  * `stub` — zero or more hits (never fails for being unused)
  """

  use GenServer

  defstruct [:pid, :port]

  @type t :: %__MODULE__{pid: pid(), port: :inet.port_number()}

  defmodule Router do
    @moduledoc false

    def init(stub_pid), do: stub_pid

    def call(conn, stub_pid) do
      DevIDE.TestSupport.HTTPStub.__dispatch__(stub_pid, conn)
    end
  end

  @doc """
  Starts a stub listening on `127.0.0.1`.

  Options:

  * `:port` — TCP port (default `0` = OS-assigned; real port is on the struct)
  """
  @spec open(keyword()) :: t()
  def open(opts \\ []) do
    preferred_port = Keyword.get(opts, :port, 0)

    # Unlinked: Bypass owns its instances under a DynamicSupervisor so they
    # outlive the test process until on_exit verification. start_link would
    # kill the stub on test-process EXIT before ExUnit's on_exit runs.
    {:ok, pid} = GenServer.start(__MODULE__, %{preferred_port: preferred_port})
    port = GenServer.call(pid, :port)

    ExUnit.Callbacks.on_exit({__MODULE__, pid}, fn ->
      verify_on_exit!(pid)
    end)

    %__MODULE__{pid: pid, port: port}
  end

  @spec expect(t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect(%__MODULE__{pid: pid}, fun) when is_function(fun, 1) do
    GenServer.call(pid, {:register, :expect, :any, :any, fun})
  end

  @spec expect(t(), String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect(%__MODULE__{pid: pid}, method, path, fun)
      when is_binary(method) and is_binary(path) and is_function(fun, 1) do
    GenServer.call(pid, {:register, :expect, method, path, fun})
  end

  @spec expect_once(t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect_once(%__MODULE__{pid: pid}, fun) when is_function(fun, 1) do
    GenServer.call(pid, {:register, :expect_once, :any, :any, fun})
  end

  @spec expect_once(t(), String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect_once(%__MODULE__{pid: pid}, method, path, fun)
      when is_binary(method) and is_binary(path) and is_function(fun, 1) do
    GenServer.call(pid, {:register, :expect_once, method, path, fun})
  end

  @spec stub(t(), String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def stub(%__MODULE__{pid: pid}, method, path, fun)
      when is_binary(method) and is_binary(path) and is_function(fun, 1) do
    GenServer.call(pid, {:register, :stub, method, path, fun})
  end

  @doc """
  Stops the listener so clients get `econnrefused`. Keeps the port reserved
  for a later `up/1` on the same port.
  """
  @spec down(t()) :: :ok | {:error, :already_down}
  def down(%__MODULE__{pid: pid}), do: GenServer.call(pid, :down, :infinity)

  @doc """
  Restarts the listener on the same port after `down/1`.
  """
  @spec up(t()) :: :ok | {:error, :already_up | term()}
  def up(%__MODULE__{pid: pid}), do: GenServer.call(pid, :up, :infinity)

  @doc false
  def __dispatch__(pid, conn) do
    case GenServer.call(pid, {:take, conn.method, conn.request_path}, :infinity) do
      {:ok, route, fun} ->
        try do
          fun.(conn)
        else
          result_conn ->
            GenServer.cast(pid, {:result, route, :ok})
            result_conn
        catch
          class, reason ->
            stacktrace = __STACKTRACE__
            GenServer.cast(pid, {:result, route, {:exit, {class, reason, stacktrace}}})
            :erlang.raise(class, reason, stacktrace)
        end

      {:error, error, route} ->
        GenServer.cast(pid, {:result, route, {:error, error, route}})
        raise "HTTPStub route error: #{inspect(error)} for #{inspect(route)}"
    end
  end

  # -- GenServer -------------------------------------------------------------

  @impl true
  def init(%{preferred_port: preferred_port}) do
    case start_listener(preferred_port) do
      {:ok, bandit_pid, port} ->
        {:ok,
         %{
           bandit_pid: bandit_pid,
           port: port,
           expectations: %{},
           fatal_error: nil
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  def handle_call(:down, _from, %{bandit_pid: nil} = state) do
    {:reply, {:error, :already_down}, state}
  end

  def handle_call(:down, _from, %{bandit_pid: bandit_pid} = state) do
    stop_listener(bandit_pid)
    {:reply, :ok, %{state | bandit_pid: nil}}
  end

  def handle_call(:up, _from, %{bandit_pid: pid} = state) when is_pid(pid) do
    {:reply, {:error, :already_up}, state}
  end

  def handle_call(:up, _from, %{bandit_pid: nil, port: port} = state) do
    case start_listener(port) do
      {:ok, bandit_pid, ^port} ->
        {:reply, :ok, %{state | bandit_pid: bandit_pid}}

      {:ok, bandit_pid, other_port} ->
        stop_listener(bandit_pid)
        {:reply, {:error, {:port_mismatch, other_port}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register, kind, method, path, fun}, _from, state)
      when kind in [:expect, :expect_once, :stub] do
    expected =
      case kind do
        :expect -> :once_or_more
        :expect_once -> :once
        :stub -> :none_or_more
      end

    route = {method, path}

    entry = %{
      fun: fun,
      expected: expected,
      request_count: 0,
      results: []
    }

    {:reply, :ok, put_in(state.expectations[route], entry)}
  end

  def handle_call({:take, method, path}, _from, state) do
    case match_route(state.expectations, method, path) do
      nil ->
        route = {method, path}
        {:reply, {:error, :unexpected_request, route}, state}

      route ->
        entry = Map.fetch!(state.expectations, route)

        cond do
          entry.expected == :once and entry.request_count > 0 ->
            state = bump_count(state, route)
            {:reply, {:error, :too_many_requests, route}, state}

          true ->
            state = bump_count(state, route)
            {:reply, {:ok, route, entry.fun}, state}
        end
    end
  end

  def handle_call(:on_exit, _from, state) do
    state = stop_listener_state(state)
    result = verify_state(state)
    {:stop, :normal, result, state}
  end

  @impl true
  def handle_cast({:result, route, result}, state) do
    case state.expectations[route] do
      nil ->
        # Unexpected / too-many path: store first fatal for on_exit.
        fatal =
          case result do
            {:error, _, _} = err -> err
            other -> other
          end

        {:noreply, %{state | fatal_error: state.fatal_error || fatal}}

      entry ->
        entry = %{entry | results: [result | entry.results]}
        {:noreply, put_in(state.expectations[route], entry)}
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp verify_on_exit!(pid) do
    result =
      try do
        if Process.alive?(pid) do
          GenServer.call(pid, :on_exit, :infinity)
        else
          :ok
        end
      catch
        :exit, {:noproc, _} -> :ok
        :exit, {:normal, _} -> :ok
      end

    case result do
      :ok ->
        :ok

      {:error, :too_many_requests, {:any, :any}} ->
        raise ExUnit.AssertionError,
          message: "Expected only one HTTP request for HTTPStub"

      {:error, :too_many_requests, {method, path}} ->
        raise ExUnit.AssertionError,
          message: "Expected only one HTTP request for HTTPStub at #{method} #{path}"

      {:error, :unexpected_request, {:any, :any}} ->
        raise ExUnit.AssertionError,
          message: "HTTPStub got an HTTP request but wasn't expecting one"

      {:error, :unexpected_request, {method, path}} ->
        raise ExUnit.AssertionError,
          message: "HTTPStub got an HTTP request but wasn't expecting one at #{method} #{path}"

      {:error, :not_called, {:any, :any}} ->
        raise ExUnit.AssertionError, message: "No HTTP request arrived at HTTPStub"

      {:error, :not_called, {method, path}} ->
        raise ExUnit.AssertionError,
          message: "No HTTP request arrived at HTTPStub at #{method} #{path}"

      {:exit, {class, reason, stacktrace}} ->
        :erlang.raise(class, reason, stacktrace)
    end
  end

  defp verify_state(state) do
    cond do
      match?({:exit, _}, state.fatal_error) ->
        state.fatal_error

      match?({:error, _, _}, state.fatal_error) ->
        state.fatal_error

      true ->
        case expectation_problem(state.expectations) do
          nil -> :ok
          error -> error
        end
    end
  end

  defp expectation_problem(expectations) do
    not_called =
      expectations
      |> Enum.reject(fn {_route, e} -> e.expected == :none_or_more end)
      |> Enum.find(fn {_route, e} -> e.results == [] end)

    case not_called do
      {route, _} ->
        {:error, :not_called, route}

      nil ->
        Enum.find_value(expectations, fn {_route, e} ->
          Enum.find(e.results, fn
            {:exit, _} -> true
            {:error, _, _} -> true
            _ -> false
          end)
        end)
    end
  end

  defp match_route(expectations, method, path) do
    cond do
      Map.has_key?(expectations, {method, path}) -> {method, path}
      Map.has_key?(expectations, {:any, :any}) -> {:any, :any}
      true -> nil
    end
  end

  defp bump_count(state, route) do
    update_in(state.expectations[route].request_count, &(&1 + 1))
  end

  defp start_listener(port) do
    case Bandit.start_link(
           plug: {Router, self()},
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: port,
           startup_log: false
         ) do
      {:ok, pid} ->
        case ThousandIsland.listener_info(pid) do
          {:ok, {_address, actual_port}} when is_integer(actual_port) and actual_port > 0 ->
            {:ok, pid, actual_port}

          other ->
            stop_listener(pid)
            {:error, {:listener_info, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_listener_state(%{bandit_pid: nil} = state), do: state

  defp stop_listener_state(%{bandit_pid: pid} = state) do
    stop_listener(pid)
    %{state | bandit_pid: nil}
  end

  defp stop_listener(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      # Bandit is a supervisor; stop it so the listen socket is released and
      # subsequent clients see econnrefused (not a half-open acceptor).
      _ = Supervisor.stop(pid, :normal, 5_000)
    end

    :ok
  end
end
