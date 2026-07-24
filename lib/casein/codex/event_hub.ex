defmodule Casein.Codex.EventHub do
  @moduledoc """
  Serializes canonical events from transports that do not own a runtime router.

  Hook and `codex exec --json` adapters publish here. Runtime-local App Server
  processes continue to use `EventRouter`, but both paths share `EventSink`.
  """

  use GenServer

  alias Casein.Codex.{Event, EventSink, Store}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec publish(Event.t()) :: {:ok, Event.t()} | {:error, term()}
  def publish(%Event{} = event), do: GenServer.call(__MODULE__, {:publish, event})

  @impl true
  def init(_opts), do: {:ok, %{sequences: %{}}}

  @impl true
  def handle_call({:publish, event}, _from, state) do
    current =
      Map.get_lazy(state.sequences, event.runtime_id, fn ->
        Store.latest_sequence(event.runtime_id)
      end)

    event = Event.resequence(event, current + 1)

    case EventSink.route(event) do
      :ok ->
        {:reply, {:ok, event}, put_in(state.sequences[event.runtime_id], event.sequence)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
end
