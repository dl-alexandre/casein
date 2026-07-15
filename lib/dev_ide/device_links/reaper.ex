defmodule DevIDE.DeviceLinks.Reaper do
  @moduledoc """
  Periodic sweeper for expired and revoked device-link tokens.

  Deletes rows past a retention grace so `verify_token/1` can still return
  `:expired` or `:revoked` for recently-lapsed credentials.
  """

  use GenServer

  import Ecto.Query

  alias DevIDE.DeviceLinks.Token
  alias DevIDE.Repo

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

    {count, _} =
      Repo.delete_all(
        from(t in Token,
          where:
            (not is_nil(t.revoked_at) and t.revoked_at < ^cutoff) or
              (not is_nil(t.expires_at) and t.expires_at < ^cutoff)
        )
      )

    count
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval_ms())
  end

  defp enabled? do
    Application.get_env(:dev_ide, :device_link_reaper_enabled, true)
  end

  defp sweep_interval_ms do
    Application.get_env(
      :dev_ide,
      :device_link_reaper_sweep_interval_ms,
      @default_sweep_interval_ms
    )
  end

  defp retention_seconds do
    Application.get_env(
      :dev_ide,
      :device_link_reaper_retention_seconds,
      @default_retention_seconds
    )
  end
end
