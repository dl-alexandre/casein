defmodule Casein.EctoTypes.StringList do
  @moduledoc false

  use Ecto.Type

  @sqlite Casein.Repo.Adapter.sqlite?()

  def type, do: if(@sqlite, do: :string, else: {:array, :string})

  def cast(nil), do: {:ok, []}

  def cast(values) when is_list(values) do
    {:ok, Enum.map(values, &to_string/1)}
  end

  def cast(_value), do: :error

  def load(nil), do: {:ok, []}
  def load(value) when is_binary(value), do: if(@sqlite, do: decode(value), else: :error)
  def load(values) when is_list(values), do: if(@sqlite, do: :error, else: cast(values))
  def load(_value), do: :error

  def dump(values) when is_list(values) do
    values = Enum.map(values, &to_string/1)
    if @sqlite, do: Jason.encode(values), else: {:ok, values}
  end

  def dump(_value), do: :error

  defp decode(value) do
    case Jason.decode(value) do
      {:ok, values} when is_list(values) -> {:ok, Enum.map(values, &to_string/1)}
      _ -> :error
    end
  end
end
