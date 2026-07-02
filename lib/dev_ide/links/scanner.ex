defmodule DevIDE.Links.Scanner do
  @moduledoc """
  Pure terminal-row link candidate scanner.

  This module does no filesystem or network verification. It only finds
  plausible spans; callers pass each span to `DevIDE.Links.Resolver` when they
  need a verified target.
  """

  alias DevIDE.Links.Scanner.Span

  @url_regex ~r/https?:\/\/[^\s\)\]"'<>]+/i

  @known_extensions ~w(
    astro bash c cjs cpp cs css cts eex erl ex exs go h heex hpp hrl html
    java js json jsx leex lock markdown md mjs mts php py rb rs sh sql svelte
    toml ts tsx txt vue yaml yml zsh
  )

  @known_ext_pattern Enum.map_join(
                       Enum.sort_by(@known_extensions, &byte_size/1, :desc),
                       "|",
                       &Regex.escape/1
                     )

  @path_regex ~r"""
  (?:
    (?:~|\.{1,2}|\/|[A-Za-z0-9_.@+-]+\/)[^\s\)\]"'<>]*
    |
    [A-Za-z0-9_.@+-]+\.(?:#{@known_ext_pattern})
  )
  (?::\d+(?::\d+)?)?
  (?:\#[A-Za-z0-9_.~%:+\/=-]+)?
  """x

  @doc "Scan one terminal row for plausible URL and file path candidates."
  @spec scan_row(String.t()) :: [Span.t()]
  def scan_row(row) when is_binary(row) do
    url_spans = scan_urls(row)
    url_ranges = Enum.map(url_spans, &{&1.col_start, &1.col_end})

    path_spans =
      row
      |> regex_spans(@path_regex)
      |> Enum.reject(&overlaps_any?(&1, url_ranges))
      |> Enum.filter(&plausible_path?/1)

    (url_spans ++ path_spans)
    |> Enum.sort_by(& &1.col_start)
  end

  def scan_row(_), do: []

  @doc "Scan one row for HTTP(S) URL candidates only."
  @spec scan_urls(String.t()) :: [Span.t()]
  def scan_urls(row) when is_binary(row), do: regex_spans(row, @url_regex)
  def scan_urls(_), do: []

  defp regex_spans(row, regex) do
    regex
    |> Regex.scan(row, return: :index)
    |> Enum.map(fn [{start, length} | _] ->
      raw = binary_part(row, start, length)
      trim_span(row, start, start + length, raw)
    end)
    |> Enum.reject(&(&1.raw == ""))
  end

  defp trim_span(row, start, stop, raw) do
    {start, raw} = trim_leading(row, start, raw)
    {stop, raw} = trim_trailing(stop, raw)
    %Span{col_start: start, col_end: stop, raw: raw}
  end

  defp trim_leading(_row, start, <<first::binary-size(1), rest::binary>>)
       when first in ["(", "\"", "'", "<"] do
    trim_leading(rest, start + byte_size(first), rest)
  end

  defp trim_leading(_row, start, raw), do: {start, raw}

  defp trim_trailing(stop, raw) do
    case raw do
      "" ->
        {stop, raw}

      _ ->
        last = binary_part(raw, byte_size(raw) - 1, 1)

        if last in [")", ".", ",", ":", ";", "\"", "'", ">"] do
          trim_trailing(stop - byte_size(last), binary_part(raw, 0, byte_size(raw) - 1))
        else
          {stop, raw}
        end
    end
  end

  defp plausible_path?(%Span{raw: raw}) do
    String.contains?(raw, "/") or known_extension_path?(raw)
  end

  defp known_extension_path?(raw) do
    path =
      raw
      |> strip_fragment()
      |> strip_position()

    ext =
      path
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.downcase()

    ext in @known_extensions
  end

  defp strip_fragment(raw) do
    raw
    |> String.split("#", parts: 2)
    |> hd()
  end

  defp strip_position(raw) do
    case Regex.run(~r/^(.+?):\d+(?::\d+)?$/, raw) do
      [_, path] -> path
      _ -> raw
    end
  end

  defp overlaps_any?(%Span{col_start: start, col_end: stop}, ranges) do
    Enum.any?(ranges, fn {range_start, range_stop} ->
      start < range_stop and stop > range_start
    end)
  end
end
