defmodule Casein.Mobile.AttentionHistorySweeper do
  @moduledoc """
  Periodic sweeper for `mobile_attention_transitions` overflow.

  #932: prune used to run two `delete_all`s on every `record_card/3` inside
  the per-user observer `GenServer.call`. Bounds stay
  `AttentionInbox.retained_per_card/0` and `retained_per_origin/0`; they are
  just no longer paid on the write path.
  """

  use GenServer

  alias Casein.Mobile.AttentionInbox

  @default_sweep_interval_ms 3_600_000

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
    {:reply, AttentionInbox.sweep_history(), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _ = AttentionInbox.sweep_history()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval_ms())
  end

  defp enabled? do
    Application.get_env(:casein, :attention_history_sweeper_enabled, true)
  end

  defp sweep_interval_ms do
    Application.get_env(
      :casein,
      :attention_history_sweeper_interval_ms,
      @default_sweep_interval_ms
    )
  end
end
