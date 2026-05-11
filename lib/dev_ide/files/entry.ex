defmodule DevIDE.Files.Entry do
  @moduledoc "A single file or directory entry surfaced to the UI."

  @type kind :: :file | :dir | :symlink | :other

  @type t :: %__MODULE__{
          name: String.t(),
          rel_path: String.t(),
          kind: kind(),
          size: non_neg_integer() | nil,
          mtime: NaiveDateTime.t() | nil
        }

  defstruct [:name, :rel_path, :kind, :size, :mtime]

  def from_stat(name, rel_path, %File.Stat{} = stat) do
    %__MODULE__{
      name: name,
      rel_path: rel_path,
      kind: kind(stat.type),
      size: stat.size,
      mtime: from_erl(stat.mtime)
    }
  end

  defp kind(:directory), do: :dir
  defp kind(:regular), do: :file
  defp kind(:symlink), do: :symlink
  defp kind(_), do: :other

  defp from_erl({{y, mo, d}, {h, mi, s}}) do
    {:ok, dt} = NaiveDateTime.new(y, mo, d, h, mi, s)
    dt
  end

  defp from_erl(_), do: nil
end
