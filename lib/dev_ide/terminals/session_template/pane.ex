defmodule DevIDE.Terminals.SessionTemplate.Pane do
  @moduledoc """
  Additional tmux pane declared under a template window.
  """

  @directions ["h", "v"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          cwd: String.t() | nil,
          command: String.t() | nil,
          split_direction: String.t(),
          size_percent: pos_integer() | nil,
          focus: boolean()
        }

  defstruct [:id, :cwd, :command, :size_percent, split_direction: "h", focus: false]

  @spec new(map() | t()) :: {:ok, t()} | {:error, atom()}
  def new(%__MODULE__{} = pane), do: validate(pane)

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: optional_string(field(attrs, :id)),
      cwd: optional_string(field(attrs, :cwd)),
      command: optional_string(field(attrs, :command)),
      split_direction: optional_string(field(attrs, :split_direction)) || "h",
      size_percent: optional_integer(field(attrs, :size_percent)),
      focus: bool?(field(attrs, :focus, false))
    }
    |> validate()
  end

  defp validate(%__MODULE__{split_direction: direction}) when direction not in @directions,
    do: {:error, :invalid_direction}

  defp validate(%__MODULE__{size_percent: percent})
       when is_integer(percent) and (percent <= 0 or percent >= 100),
       do: {:error, :invalid_size_percent}

  defp validate(%__MODULE__{} = pane), do: {:ok, pane}

  defp optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      string -> string
    end
  end

  defp optional_string(_), do: nil

  defp optional_integer(value) when is_integer(value), do: value

  defp optional_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp optional_integer(_), do: nil

  defp bool?(value), do: value in [true, "true", "1", 1]

  defp field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
