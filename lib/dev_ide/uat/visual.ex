defmodule DevIDE.UAT.Visual do
  @moduledoc """
  The optional visual-baseline tier (tier-3). Compares a captured screenshot
  against a stored baseline and returns an **advisory** result — `DevIDE.UAT.Replay`
  treats a mismatch as `:warn`, never `:fail`, so a flaky pixel diff can never gate
  CI.

  The `differ` is injectable. The default `byte_distance/2` is dependency-free and
  deterministic but NOT perceptual — it flags any change, so it is only meaningful
  for byte-stable renders. A real perceptual diff (SSIM via an image lib or
  ImageMagick `compare`) plugs in as `opts[:differ]` without touching callers.
  """

  @type result :: %{
          match: boolean(),
          distance: float() | nil,
          reason: atom() | nil
        }

  @doc """
  Compare `actual_path` against `baseline_path`.

  Options:

    * `:differ` — `(actual, baseline -> {:ok, distance :: float} | {:error, term})`
      (default `byte_distance/2`)
    * `:threshold` — max distance still considered a match (default `0.0`, exact)

  Returns `{:ok, result}`; a missing baseline or actual is a non-matching result
  with a `:reason`, never an error (the tier is advisory).
  """
  @spec compare(String.t() | nil, String.t() | nil, keyword()) :: {:ok, result()}
  def compare(actual_path, baseline_path, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.0)
    differ = Keyword.get(opts, :differ, &byte_distance/2)

    cond do
      blank_or_missing?(baseline_path) ->
        {:ok, %{match: false, distance: nil, reason: :no_baseline}}

      blank_or_missing?(actual_path) ->
        {:ok, %{match: false, distance: nil, reason: :no_actual}}

      true ->
        case differ.(actual_path, baseline_path) do
          {:ok, distance} ->
            {:ok, %{match: distance <= threshold, distance: distance, reason: nil}}

          {:error, reason} ->
            {:ok, %{match: false, distance: nil, reason: reason}}
        end
    end
  end

  @doc """
  Default differ: normalized byte distance in `0.0..1.0`. Identical files → `0.0`;
  fully different (or different lengths, padded) → toward `1.0`.
  """
  @spec byte_distance(String.t(), String.t()) :: {:ok, float()} | {:error, term()}
  def byte_distance(actual_path, baseline_path) do
    with {:ok, a} <- File.read(actual_path),
         {:ok, b} <- File.read(baseline_path) do
      {:ok, normalized_distance(a, b)}
    end
  end

  defp normalized_distance(same, same), do: 0.0

  defp normalized_distance(a, b) do
    max_len = max(byte_size(a), byte_size(b))
    if max_len == 0, do: 0.0, else: differing_bytes(a, b) / max_len
  end

  defp differing_bytes(a, b) do
    la = :binary.bin_to_list(a)
    lb = :binary.bin_to_list(b)
    len = max(length(la), length(lb))
    pa = la ++ List.duplicate(nil, len - length(la))
    pb = lb ++ List.duplicate(nil, len - length(lb))

    pa
    |> Enum.zip(pb)
    |> Enum.count(fn {x, y} -> x != y end)
  end

  defp blank_or_missing?(nil), do: true
  defp blank_or_missing?(""), do: true
  defp blank_or_missing?(path) when is_binary(path), do: not File.exists?(path)
end
