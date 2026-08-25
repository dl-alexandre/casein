defmodule Casein.Terminals.InputBuffer do
  @moduledoc """
  Classify whether a pane composer holds real unsent user text.

  Claude Code paints a suggested-next-prompt in the composer with faint/dim
  SGR. After ANSI is stripped that suggestion is byte-identical to typed
  text. This classifier reads an ANSI-preserving tail and reports:

    * `%{has_content: false, source: "empty"}` — composer present, no text
    * `%{has_content: false, source: "placeholder"}` — suggestion only
    * `%{has_content: true, source: "typed"}` — real unsent text
    * `%{has_content: "unknown", source: "unknown"}` — cannot distinguish

  Treat `"unknown"` as "do not claim this is user content". A suggested
  prompt is never reported as typed text.
  """

  @tail_lines 12
  @ansi_csi ~r/\e\[[0-?]*[ -\/]*[@-~]/
  @composer_re ~r/^(?<prefix>(?:\e\[[0-?]*[ -\/]*[@-~])*)[❯›](?<rest>.*)$/u

  @footer_re ~r/(?:⏎\s*send|esc to (?:interrupt|cancel)|ctrl[+\-]c to |\d+(?:\.\d+)?[kKmM]\s*\(|claude-|sonnet|opus|gpt-|opencode|codex)/iu

  @choice_re ~r/^\s*(?:\e\[[0-?]*[ -\/]*[@-~])*[❯›>]\s+(?:allow|approve|yes|deny|reject|always|once)\b/iu

  @placeholder_256 MapSet.new(Enum.to_list(232..250) ++ [8])

  @type t :: %{
          has_content: boolean() | String.t(),
          source: String.t()
        }

  @doc "Classify a captured pane without I/O. Undecidable input is always unknown."
  @spec classify(String.t() | term()) :: t()
  def classify(screen) when is_binary(screen) do
    lines = screen |> String.split("\n") |> Enum.take(-@tail_lines)
    screen_has_ansi? = String.contains?(screen, "\e[")

    case find_composer(lines) do
      nil ->
        unknown()

      {prefix, rest} ->
        classify_composer(prefix, rest, screen_has_ansi?)
    end
  end

  def classify(_screen), do: unknown()

  defp unknown, do: %{has_content: "unknown", source: "unknown"}

  defp empty, do: %{has_content: false, source: "empty"}

  defp placeholder, do: %{has_content: false, source: "placeholder"}

  defp typed, do: %{has_content: true, source: "typed"}

  defp find_composer(lines) do
    Enum.reduce_while(Enum.reverse(lines), nil, fn line, _acc ->
      cond do
        blank_line?(line) ->
          {:cont, nil}

        choice_line?(line) ->
          {:cont, nil}

        match = Regex.named_captures(@composer_re, line) ->
          {:halt, {match["prefix"], match["rest"]}}

        footer_line?(line) ->
          {:cont, nil}

        true ->
          {:cont, nil}
      end
    end)
  end

  defp blank_line?(line) do
    line
    |> strip_ansi()
    |> String.trim()
    |> Kernel.==("")
  end

  defp footer_line?(line), do: Regex.match?(@footer_re, strip_ansi(line))

  defp choice_line?(line), do: Regex.match?(@choice_re, line)

  defp strip_ansi(text), do: Regex.replace(@ansi_csi, text, "")

  defp classify_composer(prefix, rest, screen_has_ansi?) do
    initial = apply_sgr_string(%{faint: false, placeholder_fg: false, saw_sgr: false}, prefix)
    {styles, meta} = walk(rest, initial, [])

    content = Enum.reject(styles, & &1.whitespace?)

    cond do
      content == [] ->
        empty()

      Enum.all?(content, & &1.placeholder?) and meta.saw_placeholder_sgr ->
        placeholder()

      Enum.any?(content, &(not &1.placeholder?)) and (meta.saw_sgr or screen_has_ansi?) ->
        typed()

      true ->
        unknown()
    end
  end

  defp walk("", _state, acc) do
    meta = %{
      saw_sgr: Enum.any?(acc, & &1.saw_sgr),
      saw_placeholder_sgr: Enum.any?(acc, & &1.saw_placeholder_sgr)
    }

    {Enum.reverse(acc), meta}
  end

  defp walk(text, state, acc) do
    case next_token(text) do
      {:sgr, params, rest} ->
        walk(rest, apply_sgr(state, params), acc)

      {:escape, rest} ->
        walk(rest, state, acc)

      {:char, char, rest} ->
        walk(rest, state, [char_style(state, char) | acc])
    end
  end

  defp next_token(<<"\e[", rest::binary>>) do
    case Regex.run(~r/^([0-9;]*)m(.*)/s, rest) do
      [_, params, tail] ->
        {:sgr, parse_sgr_params(params), tail}

      _ ->
        case Regex.run(~r/^[0-?]*[ -\/]*[@-~](.*)/s, rest) do
          [_, tail] -> {:escape, tail}
          _ -> {:char, "\e", rest}
        end
    end
  end

  defp next_token(<<"\e]", rest::binary>>) do
    case Regex.run(~r/^[^\a\e]*(?:\a|\e\\)(.*)/s, rest) do
      [_, tail] -> {:escape, tail}
      _ -> {:char, "\e", rest}
    end
  end

  defp next_token(<<"\e", rest::binary>>), do: {:char, "\e", rest}

  defp next_token(<<char::utf8, rest::binary>>), do: {:char, <<char::utf8>>, rest}

  defp next_token(<<>>), do: {:escape, ""}

  defp parse_sgr_params(""), do: [0]

  defp parse_sgr_params(params) do
    params
    |> String.split(";", trim: false)
    |> Enum.map(fn
      "" -> 0
      part -> String.to_integer(part)
    end)
  rescue
    ArgumentError -> [0]
  end

  defp apply_sgr_string(state, text) do
    {_, final} =
      Enum.reduce(sgr_sequences(text), {state, state}, fn params, {_prev, acc} ->
        {acc, apply_sgr(acc, params)}
      end)

    final
  end

  defp sgr_sequences(text) do
    for [_, params] <- Regex.scan(~r/\e\[([0-9;]*)m/, text), do: parse_sgr_params(params)
  end

  defp apply_sgr(state, params), do: consume_sgr(state, params)

  defp consume_sgr(state, []), do: state

  defp consume_sgr(state, [0 | rest]) do
    consume_sgr(%{state | faint: false, placeholder_fg: false, saw_sgr: true}, rest)
  end

  defp consume_sgr(state, [2 | rest]) do
    consume_sgr(%{state | faint: true, saw_sgr: true}, rest)
  end

  defp consume_sgr(state, [22 | rest]) do
    consume_sgr(%{state | faint: false, saw_sgr: true}, rest)
  end

  defp consume_sgr(state, [39 | rest]) do
    consume_sgr(%{state | placeholder_fg: false, saw_sgr: true}, rest)
  end

  defp consume_sgr(state, [90 | rest]) do
    consume_sgr(%{state | placeholder_fg: true, saw_sgr: true}, rest)
  end

  defp consume_sgr(state, [38, 5, n | rest]) when is_integer(n) do
    consume_sgr(
      %{state | placeholder_fg: MapSet.member?(@placeholder_256, n), saw_sgr: true},
      rest
    )
  end

  defp consume_sgr(state, [38, 2, r, g, b | rest])
       when is_integer(r) and is_integer(g) and is_integer(b) do
    consume_sgr(%{state | placeholder_fg: dim_gray?(r, g, b), saw_sgr: true}, rest)
  end

  defp consume_sgr(state, [38 | rest]) do
    consume_sgr(%{state | saw_sgr: true}, skip_color(rest))
  end

  defp consume_sgr(state, [_other | rest]) do
    consume_sgr(%{state | saw_sgr: true}, rest)
  end

  defp skip_color([5, _n | rest]), do: rest
  defp skip_color([2, _r, _g, _b | rest]), do: rest
  defp skip_color(rest), do: rest

  defp dim_gray?(r, g, b) do
    max = Enum.max([r, g, b])
    min = Enum.min([r, g, b])
    max - min <= 16 and max <= 180
  end

  defp char_style(state, char) do
    placeholder? = state.faint or state.placeholder_fg

    %{
      whitespace?: String.trim(char) == "",
      placeholder?: placeholder?,
      saw_sgr: state.saw_sgr,
      saw_placeholder_sgr: placeholder? and state.saw_sgr
    }
  end
end
