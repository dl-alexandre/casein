defmodule CaseinMob.PairingCode do
  @moduledoc """
  Parses the credential-safe pairing formats accepted by every mobile entry point.

  Camera scanners on iOS and Android both hand their decoded text to this module.
  URI navigation adapters may also pass the same value. Keeping the URI grammar
  here prevents platform URL parsers from disagreeing about host/path semantics.
  """

  @compact_prefix "casein://pair/"
  @query_prefix "casein://pair?"
  @max_code_bytes 4_096

  @type error ::
          :empty
          | :invalid_structure
          | :invalid_encoding
          | :invalid_json
          | :invalid_payload

  @spec decode(String.t()) :: {:ok, map()} | {:error, error()}
  def decode(input) when is_binary(input) do
    code = String.trim(input)

    cond do
      code == "" ->
        {:error, :empty}

      byte_size(code) > @max_code_bytes ->
        {:error, :invalid_structure}

      true ->
        with {:ok, payload} <- extract_payload(code),
             {:ok, decoded} <- decode_payload(payload),
             true <- is_map(decoded) do
          {:ok, decoded}
        else
          false -> {:error, :invalid_payload}
          {:error, _reason} = error -> error
        end
    end
  end

  def decode(_input), do: {:error, :invalid_structure}

  defp extract_payload(@compact_prefix <> encoded) do
    with true <- encoded != "",
         false <- String.contains?(encoded, ["/", "?", "#"]),
         {:ok, decoded} <- percent_decode(encoded),
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, decoded) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_structure}
    end
  end

  defp extract_payload(@query_prefix <> query) do
    with [pair] <- String.split(query, "&"),
         [name, encoded] when name in ["code", "pairing_code"] and encoded != "" <-
           String.split(pair, "=", parts: 2),
         code when is_binary(code) and code != "" <- URI.decode_www_form(encoded) do
      {:ok, code}
    else
      _ -> {:error, :invalid_structure}
    end
  rescue
    ArgumentError -> {:error, :invalid_structure}
  end

  defp extract_payload("{" <> _rest = json), do: {:ok, json}
  defp extract_payload("casein://" <> _rest), do: {:error, :invalid_structure}

  defp extract_payload(payload) when is_binary(payload) do
    if String.contains?(payload, "://"),
      do: {:error, :invalid_structure},
      else: {:ok, payload}
  end

  defp decode_payload("{" <> _rest = json), do: decode_json(json)

  defp decode_payload(encoded) do
    encoded = String.replace(encoded, ~r/\s+/, "")

    with {:ok, json} <- Base.url_decode64(encoded, padding: false) do
      decode_json(json)
    else
      :error -> {:error, :invalid_encoding}
    end
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp percent_decode(encoded) do
    {:ok, URI.decode(encoded)}
  rescue
    ArgumentError -> {:error, :invalid_structure}
  end
end
