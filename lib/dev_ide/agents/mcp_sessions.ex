defmodule DevIDE.Agents.MCPSessions do
  @moduledoc """
  Session registry for the MCP Streamable HTTP transport.

  The base MCP transport is a single request/response POST. Streamable HTTP adds
  an `Mcp-Session-Id` (issued by the server on `initialize`) plus an optional
  server→client SSE channel (opened with `GET`) so the server can push
  `notifications/*` — progress, logs — outside a single response.

  This GenServer owns:

    * an ETS table of `session_id -> {metadata, sse_pid}` (workspace/server
      scope plus the attached stream), and
    * process monitors on each SSE consumer (the controller process blocked in a
      chunked `GET`), so a dropped connection detaches automatically.

  It is intentionally small and side-effect-light: HTTP plumbing lives in the
  controllers, tool logic in the handlers. `notify/2` just sends an Erlang
  message to the attached SSE process, which chunks it to the client.
  """

  use GenServer

  @table __MODULE__
  @id_bytes 16

  @type session_id :: String.t()
  @type metadata :: %{
          required(:server) => :preview | :terminal,
          optional(:workspace_id) => String.t() | nil,
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
      [{^session_id, metadata, _stream}] -> {:ok, metadata}
      _ -> :error
    end
  end

  def fetch(_), do: :error

  @doc "Whether a session id is known."
  @spec exists?(session_id() | nil) :: boolean()
  def exists?(session_id), do: match?({:ok, _}, fetch(session_id))

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
      [{^session_id, _metadata, stream}] when is_pid(stream) -> Process.alive?(stream)
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
      [{^session_id, _metadata, stream}] when is_pid(stream) ->
        if Process.alive?(stream) do
          send(stream, {:mcp_sse, message})
          :ok
        else
          {:error, :no_stream}
        end

      _ ->
        {:error, :no_stream}
    end
  end

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    # monitors: ref => {session_id, pid}
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:create, metadata}, _from, state) do
    session_id = generate_id()
    metadata = Map.put_new(metadata, :created_at, System.system_time(:second))
    :ets.insert(@table, {session_id, metadata, nil})
    {:reply, session_id, state}
  end

  def handle_call({:delete, session_id}, _from, state) do
    state = demonitor_session(state, session_id)
    :ets.delete(@table, session_id)
    {:reply, :ok, state}
  end

  def handle_call({:attach_stream, session_id, pid}, _from, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, metadata, _prev}] ->
        ref = Process.monitor(pid)

        state =
          state
          |> demonitor_session(session_id)
          |> put_in([:monitors, ref], {session_id, pid})

        :ets.insert(@table, {session_id, metadata, pid})
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :unknown_session}, state}
    end
  end

  @impl true
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
      [{^session_id, metadata, ^pid}] -> :ets.insert(@table, {session_id, metadata, nil})
      _ -> :ok
    end
  end
end
