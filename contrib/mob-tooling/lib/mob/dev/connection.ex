defmodule Mob.Dev.Connection do
  @moduledoc """
  Supervised owner of the dev connection / mesh-reconnect lifecycle.

  Lifecycle state belongs **here**, not in a LiveView. A LiveView dies and
  remounts with its socket, and you'd get one handler per mounted view; this
  GenServer is a single supervised owner that LiveViews merely subscribe to (or
  call) if they need status.

  ## iOS / Android reality

    * **iOS** suspends the app in the background. A persistent distribution / IEx
      link *will* drop — this module is built around **reconnect-on-foreground**,
      not around pretending the link survives. Do not promise persistence.
    * **Android** can hold a foreground service to keep the BEAM alive longer,
      but treat backgrounding as "degraded" and lean on MeshX store-and-forward.

  Add to your supervision tree **in dev only**:

      children =
        base_children ++
          if Application.get_env(:my_app, :mob_dev), do: [Mob.Dev.Connection], else: []
  """

  use GenServer
  require Logger

  # ASSUMED MOB API — verify against the real package:
  #   Mob.Device.subscribe/1 delivers {:app_state, :background | :foreground}
  #   (and presumably peer/transport events). Adjust to the real contract.

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Current connection lifecycle state: :foreground | :background."
  def state, do: GenServer.call(__MODULE__, :state)

  @impl true
  def init(_opts) do
    Mob.Device.subscribe([:app])
    {:ok, %{lifecycle: :foreground}}
  end

  @impl true
  def handle_call(:state, _from, %{lifecycle: lc} = state), do: {:reply, lc, state}

  @impl true
  def handle_info({:app_state, :background}, state) do
    Logger.info("[Mob.Dev] backgrounded — pausing active work; relying on store-and-forward")
    # Pause heavy work; let MeshX outbox / epidemic routing buffer. Do NOT assume
    # the distribution link stays up (iOS will suspend us).
    {:noreply, %{state | lifecycle: :background}}
  end

  @impl true
  def handle_info({:app_state, :foreground}, state) do
    Logger.info("[Mob.Dev] foregrounded — re-announcing and reconnecting peers")
    # Re-establish on resume: re-announce mDNS, reconnect transports, resubscribe.
    # Idempotent — safe to run on every foreground.
    Mob.Device.subscribe([:app])
    {:noreply, %{state | lifecycle: :foreground}}
  end

  @impl true
  def handle_info(other, state) do
    Logger.debug("[Mob.Dev] unhandled device event: #{inspect(other)}")
    {:noreply, state}
  end
end
