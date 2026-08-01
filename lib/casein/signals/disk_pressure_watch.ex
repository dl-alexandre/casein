defmodule Casein.Signals.DiskPressureWatch do
  @moduledoc """
  Always-on host filesystem pressure watcher.

  Usage is classified into healthy, warning, and alarm levels. A notification
  is emitted only when the level changes, so a sustained pressure episode does
  not produce one alarm per sample.
  """

  @type level :: :healthy | :warning | :alarm

  @doc false
  @spec classify(number(), number(), number()) :: level()
  def classify(used_percent, warning_percent, alarm_percent)
      when is_number(used_percent) and is_number(warning_percent) and
             is_number(alarm_percent) do
    cond do
      used_percent >= alarm_percent -> :alarm
      used_percent >= warning_percent -> :warning
      true -> :healthy
    end
  end

  @doc false
  @spec transition(level(), level()) :: :noop | {:emit, level()}
  def transition(level, level), do: :noop
  def transition(_previous, current), do: {:emit, current}
end
