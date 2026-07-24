defmodule CaseinPreviewBrowser.Session do
  @moduledoc """
  GenServer that owns one browser backend runtime and its browser instances.
  """

  use GenServer

  alias CaseinPreviewBrowser.{Browser, Health}

  @default_backend CaseinPreviewBrowser.FakeBackend

  defstruct [
    :backend,
    :backend_state,
    :event_owner,
    browsers: %{}
  ]

  @type browser_entry :: %{
          backend_ref: term(),
          health: Health.t(),
          health_visible?: boolean()
        }

  @type state :: %__MODULE__{
          backend: module(),
          backend_state: term(),
          event_owner: pid(),
          browsers: %{Browser.id() => browser_entry()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, {self(), opts}, name: Keyword.get(opts, :name))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @spec open_browser(GenServer.server(), keyword()) ::
          {:ok, Browser.t()} | {:error, term()}
  def open_browser(session, opts \\ []), do: GenServer.call(session, {:open_browser, opts})

  @spec navigate(Browser.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def navigate(%Browser{} = browser, url), do: call_browser(browser, {:navigate, url})

  @spec observe(Browser.t()) :: {:ok, map()} | {:error, term()}
  def observe(%Browser{} = browser), do: call_browser(browser, :observe)

  @spec cdp(Browser.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def cdp(%Browser{} = browser, method, params),
    do: call_browser(browser, {:cdp, method, params})

  @spec screenshot(Browser.t(), keyword()) ::
          {:ok, CaseinPreviewBrowser.Screenshot.t()} | {:error, term()}
  def screenshot(%Browser{} = browser, opts \\ []), do: call_browser(browser, {:screenshot, opts})

  @spec close(Browser.t()) :: :ok | {:error, term()}
  def close(%Browser{} = browser), do: call_browser(browser, :close)

  @spec emit_event(GenServer.server(), Browser.id(), term()) :: :ok
  def emit_event(session, browser_id, event) do
    GenServer.cast(session, {:emit_event, browser_id, event})
    :ok
  end

  @impl true
  def init({caller, opts}) do
    backend = Keyword.get(opts, :backend, @default_backend)
    event_owner = Keyword.get(opts, :event_owner, caller)

    backend_opts = Keyword.put(opts, :event_owner, self())

    case backend.start_runtime(backend_opts) do
      {:ok, backend_state} ->
        {:ok,
         %__MODULE__{
           backend: backend,
           backend_state: backend_state,
           event_owner: event_owner
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:open_browser, opts}, _from, %__MODULE__{} = state) do
    id = browser_id()

    case state.backend.open_browser(state.backend_state, id, opts) do
      {:ok, backend_state, backend_ref} ->
        browser = %Browser{id: id, session: self()}

        browsers =
          Map.put(state.browsers, id, %{
            backend_ref: backend_ref,
            health: Health.new(),
            health_visible?: false
          })

        {:reply, {:ok, browser}, %{state | backend_state: backend_state, browsers: browsers}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:browser_call, browser_id, :observe}, _from, %__MODULE__{} = state) do
    with {:ok, entry} <- fetch_browser(state, browser_id),
         {:ok, observation} <- state.backend.observe(state.backend_state, entry.backend_ref) do
      {state, observation} = merge_observed_health(state, browser_id, observation)
      {:reply, {:ok, observation}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:browser_call, browser_id, {:navigate, url}}, _from, %__MODULE__{} = state) do
    case fetch_browser(state, browser_id) do
      {:ok, entry} ->
        state = deliver(state, browser_id, {:load_started, url})

        case state.backend.navigate(state.backend_state, entry.backend_ref, url) do
          {:ok, backend_state, observation} ->
            state =
              %{state | backend_state: backend_state}
              |> drain_backend_events()

            status = Map.get(observation, :status) || Map.get(observation, "status") || 200

            state =
              state
              |> deliver(browser_id, {:load_finished, url, status})

            {state, observation} = merge_observed_health(state, browser_id, observation)
            {:reply, {:ok, observation}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, drain_backend_events(state)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:browser_call, browser_id, {:cdp, method, params}},
        _from,
        %__MODULE__{} = state
      ) do
    with {:ok, entry} <- fetch_browser(state, browser_id),
         {:ok, backend_state, result} <-
           state.backend.cdp(state.backend_state, entry.backend_ref, method, params) do
      {:reply, {:ok, result}, %{state | backend_state: backend_state}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:browser_call, browser_id, {:screenshot, opts}}, _from, %__MODULE__{} = state) do
    with {:ok, entry} <- fetch_browser(state, browser_id),
         {:ok, backend_state, screenshot} <-
           state.backend.screenshot(state.backend_state, entry.backend_ref, opts) do
      {:reply, {:ok, screenshot}, %{state | backend_state: backend_state}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:browser_call, browser_id, :close}, _from, %__MODULE__{} = state) do
    with {:ok, entry} <- fetch_browser(state, browser_id),
         {:ok, backend_state} <-
           state.backend.close_browser(state.backend_state, entry.backend_ref) do
      state =
        %{state | backend_state: backend_state}
        |> drain_backend_events()
        |> deliver(browser_id, :closed)

      {:reply, :ok, %{state | browsers: Map.delete(state.browsers, browser_id)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:emit_event, browser_id, event}, %__MODULE__{} = state) do
    {:noreply, deliver(state, browser_id, event)}
  end

  @impl true
  def handle_info({:preview_browser, browser_id, event}, %__MODULE__{} = state) do
    {:noreply, deliver(state, browser_id, event)}
  end

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    if function_exported?(state.backend, :stop_runtime, 1) do
      state.backend.stop_runtime(state.backend_state)
    end

    :ok
  end

  defp call_browser(%Browser{id: id, session: session}, command),
    do: GenServer.call(session, {:browser_call, id, command})

  defp fetch_browser(%__MODULE__{} = state, browser_id) do
    case Map.fetch(state.browsers, browser_id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :browser_not_found}
    end
  end

  defp deliver(%__MODULE__{} = state, browser_id, event) do
    state = record_health_event(state, browser_id, event)
    send_event(state, browser_id, event)
    state
  end

  defp record_health_event(%__MODULE__{} = state, browser_id, event) do
    case Map.fetch(state.browsers, browser_id) do
      {:ok, entry} ->
        {health, health_visible?} = transition_health(entry, event)

        put_in(state.browsers[browser_id], %{
          entry
          | health: health,
            health_visible?: health_visible?
        })

      :error ->
        state
    end
  end

  defp transition_health(%{health: _health}, {:health, %Health{} = health}),
    do: {health, true}

  defp transition_health(%{health: _health}, {:health, health}) do
    case normalize_health(health) do
      %Health{} = normalized -> {normalized, true}
      nil -> {Health.new(), false}
    end
  end

  defp transition_health(
         %{health: _health},
         {:preview_signal, _type, _payload, %Health{} = health}
       ),
       do: {health, true}

  defp transition_health(%{health: health}, {:preview_signal, type, payload, _snapshot}) do
    {Health.transition(health, {:preview_signal, type, payload}), true}
  end

  defp transition_health(%{health: health}, {:preview_signal, type, payload}) do
    {Health.transition(health, {:preview_signal, type, payload}), true}
  end

  defp transition_health(%{health: health}, {:crashed, _reason} = event) do
    {Health.transition(health, event), true}
  end

  defp transition_health(%{health: health, health_visible?: visible?}, event) do
    {Health.transition(health, event), visible?}
  end

  defp merge_observed_health(%__MODULE__{} = state, browser_id, observation)
       when is_map(observation) do
    case observation_health(observation) do
      %Health{} = health ->
        state = put_browser_health(state, browser_id, health, true)
        {state, Map.put(observation, :health, health)}

      nil ->
        case Map.fetch(state.browsers, browser_id) do
          {:ok, %{health: %Health{} = health, health_visible?: true}} ->
            {state, Map.put(observation, :health, health)}

          _other ->
            {state, observation}
        end
    end
  end

  defp merge_observed_health(%__MODULE__{} = state, _browser_id, observation),
    do: {state, observation}

  defp observation_health(observation) do
    observation
    |> Map.get(:health, Map.get(observation, "health"))
    |> normalize_health()
  end

  defp normalize_health(%Health{} = health), do: health
  defp normalize_health(%{} = health), do: Health.from_map(health)
  defp normalize_health(_health), do: nil

  defp put_browser_health(%__MODULE__{} = state, browser_id, %Health{} = health, visible?) do
    update_in(state.browsers, fn browsers ->
      Map.update(browsers, browser_id, %{health: health, health_visible?: visible?}, fn entry ->
        %{entry | health: health, health_visible?: visible?}
      end)
    end)
  end

  defp drain_backend_events(%__MODULE__{} = state) do
    receive do
      {:preview_browser, browser_id, event} ->
        state
        |> deliver(browser_id, event)
        |> drain_backend_events()
    after
      0 -> state
    end
  end

  defp send_event(%__MODULE__{event_owner: owner}, browser_id, event) when is_pid(owner) do
    send(owner, {:preview_browser, browser_id, event})
    :ok
  end

  defp send_event(_state, _browser_id, _event), do: :ok

  defp browser_id do
    "browser-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
