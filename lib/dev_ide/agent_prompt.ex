defmodule DevIDE.AgentPrompt do
  @moduledoc """
  Utilities for staging agent prompts without turning a large prompt into one
  opaque paste payload.

  Some agent TUIs collapse large multiline injections into paste-summary chips.
  DevIDE keeps the terminal transport separate from this module: callers can use
  the returned chunks with whatever pane-safe send path they own.
  """

  @default_max_lines_per_chunk 5
  @default_max_bytes_per_chunk 4_000
  @max_title_length 64

  @type plan :: %{
          chunks: [String.t()],
          max_lines_per_chunk: pos_integer(),
          max_bytes_per_chunk: pos_integer(),
          submit?: boolean()
        }

  @doc "Default prompt chunk size, intentionally small for terminal agent TUIs."
  @spec default_max_lines_per_chunk() :: pos_integer()
  def default_max_lines_per_chunk, do: @default_max_lines_per_chunk

  @doc "Default prompt chunk byte cap, used to avoid one huge line becoming one huge paste."
  @spec default_max_bytes_per_chunk() :: pos_integer()
  def default_max_bytes_per_chunk, do: @default_max_bytes_per_chunk

  @doc "Maximum length for deterministic titles extracted from first prompts."
  @spec max_title_length() :: pos_integer()
  def max_title_length, do: @max_title_length

  @doc """
  Build a transport-neutral prompt send plan.

  The text is normalized to LF newlines and split into chunks with at most
  `:max_lines_per_chunk` line segments and `:max_bytes_per_chunk` bytes.
  `:submit` records intent only; this function never appends an Enter key or
  mutates a terminal.
  """
  @spec plan(String.t(), keyword()) :: plan()
  def plan(text, opts \\ []) when is_binary(text) and is_list(opts) do
    max_lines = max_lines_per_chunk(opts)
    max_bytes = max_bytes_per_chunk(opts)

    %{
      chunks: chunks(text, max_lines_per_chunk: max_lines, max_bytes_per_chunk: max_bytes),
      max_lines_per_chunk: max_lines,
      max_bytes_per_chunk: max_bytes,
      submit?: Keyword.get(opts, :submit, false) == true
    }
  end

  @doc """
  Split prompt text into line-preserving chunks.

  Empty input returns an empty list. CRLF and bare CR are normalized to LF before
  chunking so direct chunk concatenation reconstructs the normalized prompt.
  """
  @spec chunks(String.t(), keyword()) :: [String.t()]
  def chunks(text, opts \\ []) when is_binary(text) and is_list(opts) do
    max_lines = max_lines_per_chunk(opts)
    max_bytes = max_bytes_per_chunk(opts)

    case normalize_newlines(text) do
      "" ->
        []

      normalized ->
        normalized
        |> line_segments()
        |> Enum.flat_map(&split_segment_by_bytes(&1, max_bytes))
        |> chunk_segments(max_lines, max_bytes)
    end
  end

  @doc "Normalize all newline spellings in prompt text to LF."
  @spec normalize_newlines(String.t()) :: String.t()
  def normalize_newlines(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  @doc """
  Extract a deterministic title from the first meaningful prompt line.

  This is deliberately not AI title generation. It gives the later session
  naming flow a stable fallback that does not require model calls.
  """
  @spec title_from_first_prompt(String.t()) :: String.t() | nil
  def title_from_first_prompt(text) when is_binary(text) do
    text
    |> normalize_newlines()
    |> String.split("\n")
    |> Enum.map(&clean_title_line/1)
    |> Enum.find(&(&1 != ""))
    |> truncate_title()
  end

  defp max_lines_per_chunk(opts) do
    case Keyword.get(opts, :max_lines_per_chunk, @default_max_lines_per_chunk) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError,
              "expected :max_lines_per_chunk to be a positive integer, got: #{inspect(value)}"
    end
  end

  defp max_bytes_per_chunk(opts) do
    case Keyword.get(opts, :max_bytes_per_chunk, @default_max_bytes_per_chunk) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError,
              "expected :max_bytes_per_chunk to be a positive integer, got: #{inspect(value)}"
    end
  end

  defp line_segments(normalized) do
    parts = String.split(normalized, "\n", trim: false)
    last_index = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {"", ^last_index} -> []
      {line, ^last_index} -> [line]
      {line, _index} -> [line <> "\n"]
    end)
  end

  defp split_segment_by_bytes("", _max_bytes), do: []

  defp split_segment_by_bytes(segment, max_bytes) do
    if byte_size(segment) <= max_bytes do
      [segment]
    else
      {prefix, rest} = take_prefix_by_bytes(segment, max_bytes)
      [prefix | split_segment_by_bytes(rest, max_bytes)]
    end
  end

  defp take_prefix_by_bytes(segment, max_bytes) do
    take_prefix_by_bytes(segment, max_bytes, [], 0)
  end

  defp take_prefix_by_bytes("", _max_bytes, acc, _size) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}
  end

  defp take_prefix_by_bytes(segment, max_bytes, acc, size) do
    {grapheme, rest} = String.next_grapheme(segment)
    grapheme_size = byte_size(grapheme)

    cond do
      acc != [] and size + grapheme_size > max_bytes ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), segment}

      size + grapheme_size > max_bytes ->
        {grapheme, rest}

      true ->
        take_prefix_by_bytes(rest, max_bytes, [grapheme | acc], size + grapheme_size)
    end
  end

  defp chunk_segments(segments, max_lines, max_bytes) do
    {chunks, current, _line_count, _byte_count} =
      Enum.reduce(segments, {[], [], 0, 0}, fn segment,
                                               {chunks, current, line_count, byte_count} ->
        segment_bytes = byte_size(segment)

        if current != [] and
             (line_count + 1 > max_lines or byte_count + segment_bytes > max_bytes) do
          {[current_to_chunk(current) | chunks], [segment], 1, segment_bytes}
        else
          {chunks, [segment | current], line_count + 1, byte_count + segment_bytes}
        end
      end)

    chunks
    |> maybe_prepend_current(current)
    |> Enum.reverse()
  end

  defp current_to_chunk(current), do: current |> Enum.reverse() |> IO.iodata_to_binary()

  defp maybe_prepend_current(chunks, []), do: chunks
  defp maybe_prepend_current(chunks, current), do: [current_to_chunk(current) | chunks]

  defp clean_title_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/^#+\s*/u, "")
    |> String.replace(~r/^(?:[-*]|\d+[.])\s+/u, "")
    |> String.replace(~r/^\[[ xX]\]\s+/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp truncate_title(nil), do: nil

  defp truncate_title(title) do
    if String.length(title) > @max_title_length do
      String.slice(title, 0, @max_title_length - 3) <> "..."
    else
      title
    end
  end
end
