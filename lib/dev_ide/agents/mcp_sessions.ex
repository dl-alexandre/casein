defmodule DevIDE.Agents.MCPSessions do
  @moduledoc """
  Session registry for the MCP Streamable HTTP transport.

  The base MCP transport is a single request/response POST. Streamable HTTP adds
  an `Mcp-Session-Id` (issued by the server on `initialize`) plus an optional
  server→client SSE channel (opened with `GET`) so the server can push
  `notifications/*` — progress, logs — outside a single response.

  This GenServer owns:

    * an ETS table of `session_id -> {metadata, sse_pid, last_seen_ms}` (scope,
      the attached stream, and a recency stamp), and
    * process monitors on each SSE consumer (the controller process blocked in a
      chunked `GET`), so a dropped connection detaches automatically.

  ## Expiry

  Every `initialize` mints a session, including for stateless clients that ignore
  the `Mcp-Session-Id` header and never `DELETE`. A periodic sweep
  (`Process.send_after(self(), :sweep, …)`, mirroring
  `DevIDE.Terminals.TmuxWindowJanitor`) reaps sessions idle longer than the TTL,
  **except** ones with a live attached SSE stream. `touch/1` refreshes the stamp
  on each request that carries a known session id, so an actively used session is
  not reaped mid-use. Reaping an idle session is spec-safe: a later POST with the
  now-unknown id gets a 404 and the client re-initializes.

  Tunables (application env, with inline defaults):

    * `:mcp_session_ttl_ms` — idle TTL before a session is reapable (default 30m).
    * `:mcp_session_sweep_interval_ms` — sweep cadence (default 5m).
  """

  use GenServer

  @table __MODULE__
  @id_bytes 16
  @default_ttl_ms 1_800_000
  @default_sweep_interval_ms 300_000

  @type session_id :: String.t()
  @type metadata :: %{
          required(:server) => :preview | :terminal | :artifact,
          optional(:workspace_id) => String.t() | nil,
          optional(:auth_scope) => term(),
          optional(:created_at) => integer()
        }

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Create a session, returning its generated id."
  @spec create(metadata()) :: session_id()
  def create(metadata \\ %{}) do
    GenServer.call(__MODULE__, {:create, metadata})
  end

  @doc "Fetch session metadata."
  @spec fetch(session_id() | nil) :: {:ok, metadata()} | :error
  def fetch(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, metadata, _stream, _seen}] -> {:ok, metadata}
      _ -> :error
    end
  end

  def fetch(_), do: :error

  @doc "Whether a session id is known."
  @spec exists?(session_id() | nil) :: boolean()
  def exists?(session_id), do: match?({:ok, _}, fetch(session_id))

  @doc "Refresh a session's recency stamp so the sweep does not reap it mid-use."
  @spec touch(session_id()) :: :ok
  def touch(session_id) when is_binary(session_id) do
    GenServer.cast(__MODULE__, {:touch, session_id})
  end

  @doc "Terminate a session and detach any SSE consumer."
  @spec delete(session_id()) :: :ok
  def delete(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:delete, session_id})
  end

  @doc """
  Attach the calling (or given) process as the session's SSE consumer.

  Returns `{:error, :unknown_session}` if the session does not exist.
  """
  @spec attach_stream(session_id(), pid()) :: :ok | {:error, :unknown_session}
  def attach_stream(session_id, pid \\ self()) when is_binary(session_id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:attach_stream, session_id, pid})
  end

  @doc "Whether a session currently has a live attached SSE consumer."
  @spec streaming?(session_id()) :: boolean()
  def streaming?(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, _metadata, stream, _seen}] -> live_stream?(stream)
      _ -> false
    end
  end

  def streaming?(_), do: false

  @doc """
  Push a JSON-RPC message to the session's SSE consumer.

  Returns `{:error, :no_stream}` when no live consumer is attached.
  """
  @spec notify(session_id(), map()) :: :ok | {:error, :no_stream}
  def notify(session_id, message) when is_binary(session_id) and is_map(message) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, _metadata, stream, _seen}] ->
        if live_stream?(stream) do
          send(stream, {:mcp_sse, message})
          :ok
        else
          {:error, :no_stream}
        end

      _ ->
        {:error, :no_stream}
    end
  end

  @doc "Run the idle-session sweep synchronously; returns the number reaped."
  @spec sweep_now() :: non_neg_integer()
  def sweep_now do
    GenServer.call(__MODULE__, :sweep_now)
  end

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    schedule_sweep()
    # monitors: ref => {session_id, pid}
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:create, metadata}, _from, state) do
    session_id = generate_id()
    metadata = Map.put_new(metadata, :created_at, System.system_time(:second))
    :ets.insert(@table, {session_id, metadata, nil, now_ms()})
    {:reply, session_id, state}
  end

  def handle_call({:delete, session_id}, _from, state) do
    state = demonitor_session(state, session_id)
    :ets.delete(@table, session_id)
    {:reply, :ok, state}
  end

  def handle_call({:attach_stream, session_id, pid}, _from, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, metadata, _prev, _seen}] ->
        ref = Process.monitor(pid)

        state =
          state
          |> demonitor_session(session_id)
          |> put_in([:monitors, ref], {session_id, pid})

        :ets.insert(@table, {session_id, metadata, pid, now_ms()})
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :unknown_session}, state}
    end
  end

  def handle_call(:sweep_now, _from, state) do
    {count, state} = do_sweep(state)
    {:reply, count, state}
  end

  @impl true
  def handle_cast({:touch, session_id}, state) do
    if :ets.member(@table, session_id) do
      :ets.update_element(@table, session_id, {4, now_ms()})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    {_count, state} = do_sweep(state)
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {{session_id, ^pid}, monitors} ->
        detach_stream(session_id, pid)
        {:noreply, %{state | monitors: monitors}}

      {_other, _monitors} ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp generate_id do
    @id_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp live_stream?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp live_stream?(_), do: false

  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval_ms())
  end

  # Reap sessions idle past the TTL that have no live SSE stream attached.
  defp do_sweep(state) do
    now = now_ms()
    ttl = ttl_ms()

    reapable =
      :ets.foldl(
        fn {sid, _meta, stream, last_seen}, acc ->
          if reapable?(stream, last_seen, now, ttl), do: [sid | acc], else: acc
        end,
        [],
        @table
      )

    state =
      Enum.reduce(reapable, state, fn sid, st ->
        st = demonitor_session(st, sid)
        :ets.delete(@table, sid)
        st
      end)

    {length(reapable), state}
  end

  defp reapable?(stream, last_seen, now, ttl) do
    not live_stream?(stream) and now - last_seen >= ttl
  end

  # Drop (and flush) any monitor currently tracking this session's stream.
  defp demonitor_session(state, session_id) do
    {refs, monitors} =
      Enum.reduce(state.monitors, {[], state.monitors}, fn
        {ref, {^session_id, _pid}}, {refs, acc} -> {[ref | refs], Map.delete(acc, ref)}
        {_ref, _val}, {refs, acc} -> {refs, acc}
      end)

    Enum.each(refs, &Process.demonitor(&1, [:flush]))
    %{state | monitors: monitors}
  end

  defp detach_stream(session_id, pid) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, metadata, ^pid, seen}] ->
        :ets.insert(@table, {session_id, metadata, nil, seen})

      _ ->
        :ok
    end
  end

  defp ttl_ms, do: Application.get_env(:dev_ide, :mcp_session_ttl_ms, @default_ttl_ms)

  defp sweep_interval_ms,
    do: Application.get_env(:dev_ide, :mcp_session_sweep_interval_ms, @default_sweep_interval_ms)
end
