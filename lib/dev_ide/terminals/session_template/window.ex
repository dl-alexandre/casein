defmodule DevIDE.Terminals.SessionTemplate.Window do
  @moduledoc """
  One tmux window in a session template.
  """

  alias DevIDE.Terminals.SessionTemplate.Pane

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          role: String.t() | nil,
          type: Pane.pane_type(),
          cwd: String.t() | nil,
          command: String.t() | nil,
          panes: [Pane.t()],
          focus: boolean()
        }

  defstruct [:id, :name, :role, :cwd, :command, type: :terminal, panes: [], focus: false]

  @spec new(map() | t()) :: {:ok, t()} | {:error, atom()}
  def new(%__MODULE__{} = window), do: validate(window)

  def new(attrs) when is_map(attrs) do
    with {:ok, name} <- required_string(field(attrs, :name), :window_name_required),
         {:ok, panes} <- normalize_panes(field(attrs, :panes, [])) do
      %__MODULE__{
        id: optional_string(field(attrs, :id)) || name,
        name: name,
        role: optional_role(field(attrs, :role)),
        type: Pane.cast_type(field(attrs, :type)),
        cwd: optional_string(field(attrs, :cwd)),
        command: optional_string(field(attrs, :command)),
        panes: panes,
        focus: bool?(field(attrs, :focus, false))
      }
      |> validate()
    end
  end

  defp validate(%__MODULE__{role: role} = window) when is_binary(role) do
    if valid_role?(role), do: {:ok, window}, else: {:error, :invalid_role}
  end

  defp validate(%__MODULE__{} = window), do: {:ok, window}

  defp normalize_panes(panes) when is_list(panes) do
    panes
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      case Pane.new(attrs) do
        {:ok, pane} -> {:cont, {:ok, [pane | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_panes(_), do: {:error, :invalid_panes}

  defp required_string(value, error) do
    case optional_string(value) do
      nil -> {:error, error}
      string -> {:ok, string}
    end
  end

  defp optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      string -> string
    end
  end

  defp optional_string(_), do: nil

  defp optional_role(value) do
    value
    |> optional_string()
    |> case do
      nil -> nil
      role -> String.downcase(role)
    end
  end

  defp valid_role?(role) when is_binary(role) do
    String.match?(role, ~r/^[a-z][a-z0-9_-]{0,31}$/)
  end

  defp bool?(value), do: value in [true, "true", "1", 1]

  defp field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
