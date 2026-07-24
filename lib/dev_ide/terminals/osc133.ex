defmodule Casein.Terminals.Osc133 do
  @moduledoc """
  Streaming parser for OSC 133 shell-integration markers.

  The parser keeps a bounded carry buffer so OSC sequences split across PTY
  chunks are parsed once their terminator arrives. Recognized OSC 133 and OSC 7
  sequences are returned as semantic tokens and omitted from `{:data, ...}`
  tokens; unrecognized OSC sequences are preserved as data.
  """

  defstruct pending: ""

  @osc_start "\e]"
  @bel "\a"
  @st "\e\\"
  @max_pending_bytes 8 * 1024

  @type t :: %__MODULE__{pending: binary()}
  @type token ::
          {:data, binary()}
          | {:prompt_start}
          | {:command_start, String.t() | nil}
          | {:output_start, String.t() | nil}
          | {:command_end, integer() | nil}
          | {:cwd, String.t() | nil}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec scan(t(), binary()) :: {[token()], t()}
  def scan(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    {tokens, pending} = parse(state.pending <> chunk, [])
    {tokens, %{state | pending: pending}}
  end

  defp parse("", acc), do: {Enum.reverse(acc), ""}

  defp parse(binary, acc) do
    case :binary.match(binary, @osc_start) do
      :nomatch ->
        carry_trailing_esc(binary, acc)

      {0, _len} ->
        parse_osc(binary, acc)

      {idx, _len} ->
        <<data::binary-size(^idx), rest::binary>> = binary
        parse(rest, data_token(acc, data))
    end
  end

  # A chunk can end mid-introducer (a lone ESC whose "]" arrives in the next
  # chunk). Carry the ESC so the sequence still parses; tokens only feed the
  # command tracker, never the viewer byte stream, so holding one trailing
  # byte back for a chunk is unobservable.
  defp carry_trailing_esc(binary, acc) do
    data_len = byte_size(binary) - 1

    case binary do
      <<data::binary-size(^data_len), "\e">> ->
        {Enum.reverse(data_token(acc, data)), "\e"}

      _ ->
        {Enum.reverse(data_token(acc, binary)), ""}
    end
  end

  defp parse_osc(binary, acc) do
    case terminator(binary) do
      nil ->
        pending_or_data(binary, acc)

      {term_at, term_len} ->
        content_len = term_at - byte_size(@osc_start)
        seq_len = byte_size(@osc_start) + content_len + term_len

        <<_start::binary-size(2), content::binary-size(^content_len),
          _term::binary-size(^term_len), rest::binary>> = binary

        token = parse_content(content)
        seq = binary_part(binary, 0, seq_len)

        acc =
          case token do
            nil -> data_token(acc, seq)
            token -> [token | acc]
          end

        parse(rest, acc)
    end
  end

  defp terminator(binary) do
    rest_offset = byte_size(@osc_start)
    rest_len = byte_size(binary) - rest_offset

    cond do
      rest_len <= 0 ->
        nil

      true ->
        rest = binary_part(binary, rest_offset, rest_len)
        bel = match_at(rest, @bel)
        st = match_at(rest, @st)

        case earliest(bel, st) do
          nil -> nil
          {idx, len} -> {rest_offset + idx, len}
        end
    end
  end

  defp match_at(binary, pattern) do
    case :binary.match(binary, pattern) do
      :nomatch -> nil
      {idx, len} -> {idx, len}
    end
  end

  defp earliest(nil, nil), do: nil
  defp earliest(match, nil), do: match
  defp earliest(nil, match), do: match
  defp earliest({a_idx, _} = a, {b_idx, _} = b), do: if(a_idx <= b_idx, do: a, else: b)

  defp pending_or_data(binary, acc) do
    if byte_size(binary) <= @max_pending_bytes do
      {Enum.reverse(acc), binary}
    else
      emit_bytes = byte_size(binary) - @max_pending_bytes
      <<data::binary-size(^emit_bytes), pending::binary>> = binary
      {Enum.reverse(data_token(acc, data)), pending}
    end
  end

  defp data_token(acc, ""), do: acc
  defp data_token(acc, data), do: [{:data, data} | acc]

  defp parse_content("133;" <> rest) do
    case String.split(rest, ";", parts: 2) do
      ["A"] ->
        {:prompt_start}

      ["B"] ->
        {:command_start, nil}

      ["B", payload] ->
        {:command_start, command_payload(payload)}

      ["C"] ->
        {:output_start, nil}

      ["C", payload] ->
        {:output_start, command_payload(payload)}

      ["D"] ->
        {:command_end, nil}

      ["D", payload] ->
        {:command_end, exit_status(payload)}

      _ ->
        nil
    end
  end

  defp parse_content("7;" <> uri), do: {:cwd, cwd_from_uri(uri)}
  defp parse_content(_content), do: nil

  defp command_payload(payload) do
    payload
    |> kv_payload_value(["cmd", "command"])
    |> blank_to_nil()
  end

  defp exit_status(payload) do
    payload
    |> String.split(";", parts: 2)
    |> List.first()
    |> case do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {status, _rest} -> status
          :error -> nil
        end
    end
  end

  defp kv_payload_value(payload, keys) do
    pairs =
      payload
      |> String.split(";")
      |> Enum.flat_map(fn part ->
        case String.split(part, "=", parts: 2) do
          [key, value] -> [{key, URI.decode(value)}]
          _ -> []
        end
      end)
      |> Map.new()

    Enum.find_value(keys, payload, &Map.get(pairs, &1))
  end

  defp cwd_from_uri(uri) do
    case URI.parse(uri) do
      %URI{scheme: "file", path: path} when is_binary(path) -> URI.decode(path)
      _ -> uri
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end
end
