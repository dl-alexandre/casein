defmodule DevIDE.BoundedBuffer do
  @moduledoc false

  @spec append(binary(), iodata(), pos_integer(), keyword()) :: binary()
  def append(buffer, data, limit, opts \\ [])
      when is_binary(buffer) and is_integer(limit) and limit > 0 do
    marker = Keyword.get(opts, :truncation_marker, "")
    data = IO.iodata_to_binary(data)

    case append_tail(buffer, data, limit) do
      {:ok, result} -> result
      {:truncated, tail} -> marker <> tail
    end
  end

  defp append_tail(buffer, data, limit) do
    buffer_size = byte_size(buffer)
    data_size = byte_size(data)

    cond do
      buffer_size + data_size <= limit ->
        {:ok, buffer <> data}

      data_size >= limit ->
        {:truncated, binary_part(data, data_size - limit, limit)}

      true ->
        keep_from_buffer = limit - data_size
        buffer_tail = binary_part(buffer, buffer_size - keep_from_buffer, keep_from_buffer)
        {:truncated, buffer_tail <> data}
    end
  end
end
