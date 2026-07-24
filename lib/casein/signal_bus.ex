defmodule Casein.SignalBus do
  @moduledoc false

  alias Jido.Signal.Bus
  alias Jido.Signal.Journal.Adapters.ETS, as: ETSJournal

  @name Casein.SignalBus

  @spec name() :: atom()
  def name, do: @name

  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    Bus.child_spec(
      name: @name,
      journal_adapter: journal_adapter(),
      max_log_size: 10_000
    )
  end

  defp journal_adapter do
    Application.get_env(:casein, :signal_bus_journal_adapter, ETSJournal)
  end
end
