defmodule DevIDE.EctoTypes.MapList do
  @moduledoc false

  use Ecto.Type

  @sqlite DevIDE.Repo.Adapter.sqlite?()

  def type, do: if(@sqlite, do: :string, else: {:array, :map})

  def cast(nil), do: {:ok, []}
  def cast(values) when is_list(values), do: {:ok, values}
  def cast(_value), do: :error

  def load(nil), do: {:ok, []}
  def load(value) when is_binary(value), do: if(@sqlite, do: decode(value), else: :error)
  def load(values) when is_list(values), do: if(@sqlite, do: :error, else: {:ok, values})
  def load(_value), do: :error

  def dump(values) when is_list(values) do
    if @sqlite, do: Jason.encode(values), else: {:ok, values}
  end

  def dump(_value), do: :error

  defp decode(value) do
    case Jason.decode(value) do
      {:ok, values} when is_list(values) -> {:ok, values}
      _ -> :error
    end
  end
end
