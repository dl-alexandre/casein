defmodule DevIdeWeb.TerminalTelemetry do
  @moduledoc """
  Shared helpers for terminal render/push telemetry.

  Payload byte measurement requires JSON encoding the frame. Keep that cost
  centralized and runtime-configurable so production can sample it if frame
  volume becomes high.
  """

  @default_payload_byte_sample_rate 1.0

  def duration_us(started) when is_integer(started) do
    System.monotonic_time()
    |> Kernel.-(started)
    |> System.convert_time_unit(:native, :microsecond)
  end

  def changed_row_count(%{full_frame: true, cells: cells}) when is_list(cells), do: length(cells)
  def changed_row_count(%{rows: rows}) when is_list(rows), do: length(rows)
  def changed_row_count(_payload), do: 0

  def cell_count(cells) when is_list(cells) do
    Enum.reduce(cells, 0, fn
      row, acc when is_list(row) -> acc + length(row)
      _row, acc -> acc
    end)
  end

  def cell_count(_cells), do: 0

  def sampled_payload_measurements(payload) do
    if sample_payload_bytes?() do
      %{payload_bytes: payload_bytes(payload)}
    else
      %{}
    end
  end

  def sample_payload_bytes? do
    terminal_payload_bytes_sample_rate() >= :rand.uniform()
  end

  defp payload_bytes(payload) do
    payload
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
  rescue
    _ -> 0
  end

  defp terminal_payload_bytes_sample_rate do
    :dev_ide
    |> Application.get_env(:terminal_payload_bytes_sample_rate, env_sample_rate())
    |> normalize_sample_rate()
  end

  defp env_sample_rate do
    System.get_env("DEV_IDE_TERMINAL_PAYLOAD_BYTES_SAMPLE_RATE")
  end

  defp normalize_sample_rate(nil), do: @default_payload_byte_sample_rate
  defp normalize_sample_rate(true), do: 1.0
  defp normalize_sample_rate(false), do: 0.0

  defp normalize_sample_rate(value) when is_integer(value),
    do: value |> max(0) |> min(1) |> Kernel.*(1.0)

  defp normalize_sample_rate(value) when is_float(value), do: clamp_rate(value)

  defp normalize_sample_rate(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    case value do
      "" -> @default_payload_byte_sample_rate
      "true" -> 1.0
      "yes" -> 1.0
      "always" -> 1.0
      "false" -> 0.0
      "no" -> 0.0
      "never" -> 0.0
      _ -> parse_rate(value)
    end
  end

  defp normalize_sample_rate(_value), do: @default_payload_byte_sample_rate

  defp parse_rate(value) do
    case Float.parse(value) do
      {rate, ""} -> clamp_rate(rate)
      _ -> @default_payload_byte_sample_rate
    end
  end

  defp clamp_rate(value) when value < 0.0, do: 0.0
  defp clamp_rate(value) when value > 1.0, do: 1.0
  defp clamp_rate(value), do: value
end
