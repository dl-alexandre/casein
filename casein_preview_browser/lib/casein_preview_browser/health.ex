defmodule CaseinPreviewBrowser.Health do
  @moduledoc """
  LiveView-aware preview health snapshot.

  The external browser sidecar owns browser-specific observation, but the BEAM
  side keeps the canonical state names and normalization rules so callers do
  not depend on a particular sidecar implementation.
  """

  @states [
    :browser_started,
    :navigation_started,
    :dom_loaded,
    :live_socket_connected,
    :liveview_stable,
    :degraded,
    :crashed
  ]

  @derive {Inspect, only: [:state, :last_event_type]}
  defstruct state: :browser_started,
            bridge_ready: false,
            dom_loaded: false,
            live_socket_connected: nil,
            last_event_type: nil,
            last_event_at: nil,
            client_errors: []

  @type state ::
          :browser_started
          | :navigation_started
          | :dom_loaded
          | :live_socket_connected
          | :liveview_stable
          | :degraded
          | :crashed

  @type t :: %__MODULE__{
          state: state(),
          bridge_ready: boolean(),
          dom_loaded: boolean(),
          live_socket_connected: boolean() | nil,
          last_event_type: String.t() | nil,
          last_event_at: integer() | nil,
          client_errors: [map()]
        }

  @doc "Return the initial browser health snapshot."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Normalize a wire-format health map from a sidecar."
  @spec from_map(map() | nil) :: t() | nil
  def from_map(nil), do: nil

  def from_map(%__MODULE__{} = health), do: health

  def from_map(%{} = map) do
    %__MODULE__{
      state: normalize_state(value(map, :state)) || :browser_started,
      bridge_ready: truthy?(value(map, :bridge_ready)),
      dom_loaded: truthy?(value(map, :dom_loaded)),
      live_socket_connected: nullable_boolean(value(map, :live_socket_connected)),
      last_event_type: string_or_nil(value(map, :last_event_type)),
      last_event_at: integer_or_nil(value(map, :last_event_at)),
      client_errors: list_or_empty(value(map, :client_errors))
    }
  end

  @doc "Apply a normalized event to a health snapshot."
  @spec transition(t(), term()) :: t()
  def transition(%__MODULE__{} = health, {:load_started, _url}) do
    %{health | state: :navigation_started, dom_loaded: false, live_socket_connected: nil}
  end

  def transition(%__MODULE__{} = health, {:load_finished, _url, status})
      when is_integer(status) and status >= 400 do
    %{health | state: :degraded}
  end

  def transition(%__MODULE__{} = health, {:load_finished, _url, _status}),
    do: derive_state(health)

  def transition(%__MODULE__{} = health, {:crashed, _reason}), do: %{health | state: :crashed}

  def transition(%__MODULE__{} = health, {:preview_signal, type, payload})
      when is_binary(type) and is_map(payload) do
    apply_signal(health, type, payload)
  end

  def transition(%__MODULE__{} = health, {:preview_signal, type, payload, _snapshot})
      when is_binary(type) and is_map(payload) do
    apply_signal(health, type, payload)
  end

  def transition(%__MODULE__{} = health, _event), do: health

  @doc "Return a plain map snapshot useful for observations and JSON encoding."
  @spec snapshot(t() | nil) :: map() | nil
  def snapshot(nil), do: nil

  def snapshot(%__MODULE__{} = health) do
    %{
      state: health.state,
      bridge_ready: health.bridge_ready,
      dom_loaded: health.dom_loaded,
      live_socket_connected: health.live_socket_connected,
      last_event_type: health.last_event_type,
      last_event_at: health.last_event_at,
      client_errors: health.client_errors
    }
  end

  @spec states() :: [state()]
  def states, do: @states

  defp apply_signal(%__MODULE__{} = health, type, payload) do
    health =
      health
      |> Map.put(:last_event_type, type)
      |> Map.put(:last_event_at, integer_or_nil(value(payload, :timestamp)))

    case type do
      "casein:preview:bridge_ready" ->
        derive_state(%{health | bridge_ready: true})

      "casein:preview:dom_loaded" ->
        derive_state(%{health | dom_loaded: true})

      "casein:preview:live_socket_connected" ->
        derive_state(%{health | live_socket_connected: true})

      "casein:preview:live_socket_disconnected" ->
        %{health | live_socket_connected: false, state: :degraded}

      "casein:preview:page_loading_start" ->
        %{health | state: :navigation_started, dom_loaded: false, live_socket_connected: nil}

      "casein:preview:page_loading_stop" ->
        derive_state(health)

      "casein:preview:client_error" ->
        %{
          health
          | state: :degraded,
            client_errors: [payload | health.client_errors] |> Enum.take(10)
        }

      _ ->
        derive_state(health)
    end
  end

  defp derive_state(%__MODULE__{state: :crashed} = health), do: health
  defp derive_state(%__MODULE__{state: :degraded} = health), do: health

  defp derive_state(%__MODULE__{dom_loaded: true, live_socket_connected: true} = health),
    do: %{health | state: :liveview_stable}

  defp derive_state(%__MODULE__{live_socket_connected: true} = health),
    do: %{health | state: :live_socket_connected}

  defp derive_state(%__MODULE__{dom_loaded: true} = health), do: %{health | state: :dom_loaded}
  defp derive_state(%__MODULE__{} = health), do: health

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp normalize_state(value) when is_atom(value) and value in @states, do: value

  defp normalize_state(value) when is_binary(value) do
    Enum.find(@states, &(Atom.to_string(&1) == value))
  end

  defp normalize_state(_value), do: nil

  defp truthy?(value) when value in [true, "true", 1], do: true
  defp truthy?(_value), do: false

  defp nullable_boolean(value) when value in [true, "true", 1], do: true
  defp nullable_boolean(value) when value in [false, "false", 0], do: false
  defp nullable_boolean(_value), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_value), do: []
end
