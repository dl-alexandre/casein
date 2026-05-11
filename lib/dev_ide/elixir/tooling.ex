defmodule DevIDE.Elixir.Tooling do
  @moduledoc """
  Read-only tooling presence checks. No process starts.

  Lexical/ElixirLS detection looks at workspace-local artifacts only — we do
  not consult globally-installed escripts or PATH, since the goal is "what
  the workspace ships with," not "what could be invoked."
  """

  alias DevIDE.Files.PathSafety

  @type t :: %{
          formatter?: boolean(),
          lexical?: boolean(),
          elixir_ls?: boolean(),
          mix_lock_lexical?: boolean(),
          mix_lock_elixir_ls?: boolean()
        }

  @spec detect(String.t()) :: t()
  def detect(root) when is_binary(root) do
    lock = read(root, "mix.lock")

    %{
      formatter?: file_exists?(root, ".formatter.exs"),
      lexical?: any_path?(root, [".lexical", ".lexical.json", "lexical.config.exs"]),
      elixir_ls?: any_path?(root, [".elixir_ls", ".elixirls", ".elixir-ls"]),
      mix_lock_lexical?: lock_contains?(lock, "lexical"),
      mix_lock_elixir_ls?: lock_contains?(lock, "elixir_ls")
    }
  end

  defp file_exists?(root, rel) do
    case PathSafety.resolve(root, rel) do
      {:ok, abs} -> File.exists?(abs)
      _ -> false
    end
  end

  defp any_path?(root, candidates) do
    Enum.any?(candidates, &file_exists?(root, &1))
  end

  defp lock_contains?(nil, _), do: false
  defp lock_contains?(text, needle), do: String.contains?(text, needle)

  defp read(root, rel) do
    with {:ok, abs} <- PathSafety.resolve(root, rel),
         {:ok, content} <- File.read(abs) do
      content
    else
      _ -> nil
    end
  end
end
