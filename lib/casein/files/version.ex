defmodule Casein.Files.Version do
  @moduledoc """
  File version token for optimistic concurrency.

  A token is `<size>:<mtime_hex>:<sha256_hex_first_16>`. Both the on-disk stat
  fields and a content hash are folded in: stat alone misses sub-second
  edits on filesystems with low mtime resolution, content alone misses the
  case where a tool re-writes identical bytes (rare but real).

  Tokens are opaque strings to callers; only `==` and `compute*` are public.
  """

  @type t :: String.t()

  @spec compute(binary(), File.Stat.t()) :: t()
  def compute(content, %File.Stat{size: size, mtime: mtime}) when is_binary(content) do
    digest =
      :crypto.hash(:sha256, content)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "#{size}:#{erl_time_hex(mtime)}:#{digest}"
  end

  @spec compute_path(Path.t()) :: {:ok, t()} | {:error, term()}
  def compute_path(abs) do
    with {:ok, stat} <- File.stat(abs),
         {:ok, content} <- File.read(abs) do
      {:ok, compute(content, stat)}
    end
  end

  defp erl_time_hex({{y, mo, d}, {h, mi, s}}) do
    Integer.to_string(
      y * 10_000_000_000 + mo * 100_000_000 + d * 1_000_000 + h * 10_000 + mi * 100 + s,
      16
    )
  end

  defp erl_time_hex(_), do: "0"
end
