defmodule CaseinMob.MobileTerminalDiagnostic do
  @moduledoc false

  @stages [
    :watch_started,
    :control_requested,
    :control_reply_accepted,
    :control_reply_rejected,
    :child_join_requested,
    :child_join_reply_received,
    :baseline_accepted,
    :baseline_rejected,
    :status_delivered
  ]

  @type stage ::
          :watch_started
          | :control_requested
          | :control_reply_accepted
          | :control_reply_rejected
          | :child_join_requested
          | :child_join_reply_received
          | :baseline_accepted
          | :baseline_rejected
          | :status_delivered

  @type t :: %{stage: stage(), counts: %{stage() => non_neg_integer()}}

  @spec new() :: t()
  def new, do: %{stage: :watch_started, counts: %{watch_started: 1}}

  @spec reset(stage()) :: t()
  def reset(stage) when stage in @stages, do: %{stage: stage, counts: %{stage => 1}}

  @spec record(t() | term(), term()) :: t()
  def record(%{stage: stage, counts: counts}, :status_delivered)
      when stage in @stages and is_map(counts) do
    %{stage: stage, counts: Map.update(counts, :status_delivered, 1, &min(&1 + 1, 255))}
  end

  def record(%{stage: stage, counts: counts}, next)
      when stage in @stages and next in @stages and is_map(counts) do
    %{stage: next, counts: Map.update(counts, next, 1, &min(&1 + 1, 255))}
  end

  def record(_diagnostic, next) when next in @stages,
    do: %{stage: next, counts: %{next => 1}}

  def record(diagnostic, _unknown), do: normalize(diagnostic)

  @spec public(t() | term()) :: map()
  def public(diagnostic) do
    diagnostic = normalize(diagnostic)

    %{
      stage: diagnostic.stage,
      counts: Map.take(diagnostic.counts, @stages)
    }
  end

  @spec valid_public?(term()) :: boolean()
  def valid_public?(%{stage: stage, counts: counts}) when stage in @stages and is_map(counts) do
    Enum.all?(counts, fn {key, value} ->
      key in @stages and is_integer(value) and value >= 0 and value <= 255
    end)
  end

  def valid_public?(_diagnostic), do: false

  defp normalize(%{stage: stage, counts: counts}) when stage in @stages and is_map(counts) do
    safe_counts =
      Enum.reduce(counts, %{}, fn entry, acc ->
        case entry do
          {key, value} when key in @stages and is_integer(value) and value >= 0 ->
            Map.put(acc, key, min(value, 255))

          _entry ->
            acc
        end
      end)

    %{stage: stage, counts: safe_counts}
  end

  defp normalize(_diagnostic), do: new()
end
