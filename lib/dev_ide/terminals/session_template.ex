defmodule DevIDE.Terminals.SessionTemplate do
  @moduledoc """
  Declarative tmux workspace template.

  Templates describe the intended window/pane layout and startup commands.
  The first slice is deliberately read-only: callers can load built-ins and
  produce dry-run plans without mutating tmux.
  """

  alias DevIDE.Terminals.SessionTemplate.Loader
  alias DevIDE.Terminals.SessionTemplate.Executor
  alias DevIDE.Terminals.SessionTemplate.Window

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          windows: [Window.t()]
        }

  defstruct [:id, :name, :description, windows: []]

  @spec new(map() | t()) :: {:ok, t()} | {:error, atom()}
  def new(%__MODULE__{} = template), do: {:ok, template}

  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- required_string(field(attrs, :id), :id_required),
         {:ok, name} <- required_string(field(attrs, :name), :name_required),
         {:ok, windows} <- normalize_windows(field(attrs, :windows, [])) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         description: optional_string(field(attrs, :description)),
         windows: windows
       }}
    end
  end

  @spec list :: [t()]
  def list, do: Loader.list()

  @spec get(String.t()) :: {:ok, t()} | {:error, :template_not_found}
  def get(id), do: Loader.get(id)

  @spec built_in :: %{String.t() => t()}
  def built_in, do: Loader.built_in()

  @spec plan(String.t() | t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def plan(template_or_id, opts \\ []), do: Executor.plan(template_or_id, opts)

  @spec dry_run(String.t() | t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def dry_run(template_or_id, opts \\ []), do: Executor.dry_run(template_or_id, opts)

  @spec execute(String.t(), String.t() | t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(session, template_or_id, opts \\ []),
    do: Executor.execute(session, template_or_id, opts)

  defp normalize_windows([]), do: {:error, :windows_required}

  defp normalize_windows(windows) when is_list(windows) do
    windows
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      case Window.new(attrs) do
        {:ok, window} -> {:cont, {:ok, [window | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_windows(_), do: {:error, :invalid_windows}

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

  defp field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
