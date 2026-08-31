defmodule Casein.Terminals.ExpectedRemovals do
  @moduledoc """
  Short-lived record of session teardowns Casein performed on purpose.

  `Casein.Terminals.ControlPlane` announces sessions that disappear without
  explanation (OneBackend-v3#20076). A session Casein killed itself must not
  raise that alarm, but the killer and the reconciler cannot reference each
  other: `Terminals.Tmux` is reachable from `ControlPlane` through the tmux
  adapter, so a direct call closes a module cycle and re-entangles the
  preview/core seam (`scripts/check-scc-guard.sh`).

  This is therefore a leaf: it depends on nothing in `Casein.Terminals`, and
  both sides depend on it. `Tmux.kill/1` calls `expect/1`; the reconciler calls
  `claim/1`, which consumes the record so the same session name dying again
  later is still announced.

  Entries expire after `ttl_ms/0` (five minutes) — slack for a slow reconcile,
  not a window anything should rely on.
  """

  use GenServer

  @ttl_ms 300_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "How long an unclaimed expectation survives."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc """
  Record that `session` is being removed deliberately.

  Best-effort and never raises: a cast to a named process, dropped when that
  process is not running (tests, boot). Killing a session must not fail
  because bookkeeping is unavailable.
  """
  @spec expect(String.t(), GenServer.server()) :: :ok
  def expect(session, server \\ __MODULE__)

  def expect(session, server) when is_binary(session) do
    if is_pid(GenServer.whereis(server)) do
      GenServer.cast(server, {:expect, session, now_ms()})
    end

    :ok
  end

  def expect(_session, _server), do: :ok

  @doc "True when `session` was expected; consumes the record."
  @spec claim(String.t(), GenServer.server()) :: boolean()
  def claim(session, server \\ __MODULE__)

  def claim(session, server) when is_binary(session) do
    case GenServer.whereis(server) do
      nil -> false
      pid -> GenServer.call(pid, {:claim, session})
    end
  catch
    :exit, _reason -> false
  end

  def claim(_session, _server), do: false

  @doc false
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.call(pid, :clear)
    end
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(_state), do: {:ok, %{}}

  @impl true
  def handle_call({:claim, session}, _from, state) do
    state = prune(state)
    {expected, state} = Map.pop(state, session)
    {:reply, expected != nil, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}

  @impl true
  def handle_cast({:expect, session, at_ms}, state) do
    {:noreply, Map.put(prune(state), session, at_ms)}
  end

  defp prune(state) do
    cutoff = now_ms() - @ttl_ms
    Map.reject(state, fn {_session, at} -> at < cutoff end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
