defmodule Casein.DeviceLinks.Reaper do
  @moduledoc """
  Periodic sweeper for expired/revoked device-link tokens and short-lived
  compact pairing handles.

  Deletes rows past a retention grace so `verify_token/1` can still return
  `:expired` or `:revoked` for recently-lapsed credentials.
  """

  use GenServer

  import Ecto.Query

  alias Casein.DeviceLinks.{PairingHandle, Token}
  alias Casein.Repo

  @default_sweep_interval_ms 21_600_000
  @default_retention_seconds 2_592_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec sweep_now() :: non_neg_integer()
  def sweep_now do
    GenServer.call(__MODULE__, :sweep_now)
  end

  @impl true
  def init(_opts) do
    if enabled?(), do: schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:sweep_now, _from, state) do
    {:reply, do_sweep(), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _ = do_sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp do_sweep do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -retention_seconds(), :second)

    {token_count, _} =
      Repo.delete_all(
        from(t in Token,
          where:
            (not is_nil(t.revoked_at) and t.revoked_at < ^cutoff) or
              (not is_nil(t.expires_at) and t.expires_at < ^cutoff)
        )
      )

    {handle_count, _} =
      Repo.delete_all(
        from(h in PairingHandle,
          where:
            h.expires_at < ^cutoff or
              (not is_nil(h.consumed_at) and h.consumed_at < ^cutoff) or
              (not is_nil(h.revoked_at) and h.revoked_at < ^cutoff)
        )
      )

    token_count + handle_count
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval_ms())
  end

  defp enabled? do
    Application.get_env(:casein, :device_link_reaper_enabled, true)
  end

  defp sweep_interval_ms do
    Application.get_env(
      :casein,
      :device_link_reaper_sweep_interval_ms,
      @default_sweep_interval_ms
    )
  end

  defp retention_seconds do
    Application.get_env(
      :casein,
      :device_link_reaper_retention_seconds,
      @default_retention_seconds
    )
  end
end
