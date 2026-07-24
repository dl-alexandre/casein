defmodule Casein.Elixir.Project do
  @moduledoc """
  Lightweight project metadata detection.

  All reads go through `Casein.Files.PathSafety` and respect
  `PathSafety.ignored_dir?/1`. This module never starts processes, never
  invokes `mix`, and never reaches outside the workspace root.
  """

  alias Casein.Files.PathSafety

  @max_bytes 256 * 1024

  @type t :: %{
          mix?: boolean(),
          umbrella?: boolean(),
          phoenix?: boolean(),
          live_view?: boolean(),
          ecto?: boolean(),
          formatter?: boolean()
        }

  @spec detect(String.t()) :: t()
  def detect(root) when is_binary(root) do
    mix_text = read(root, "mix.exs")
    lock_text = read(root, "mix.lock")
    formatter_text = read(root, ".formatter.exs")
    apps_dir = path_or_nil(root, "apps")

    %{
      mix?: not is_nil(mix_text),
      umbrella?: umbrella?(apps_dir),
      phoenix?: contains_dep?([mix_text, lock_text], "phoenix"),
      live_view?: contains_dep?([mix_text, lock_text], "phoenix_live_view"),
      ecto?:
        contains_dep?([mix_text, lock_text], "ecto") or
          contains_dep?([mix_text, lock_text], "ecto_sql"),
      formatter?: not is_nil(formatter_text)
    }
  end

  defp umbrella?(nil), do: false

  defp umbrella?(apps_dir) do
    case File.ls(apps_dir) do
      {:ok, names} ->
        Enum.any?(names, fn name ->
          not PathSafety.ignored_dir?(name) and
            File.regular?(Path.join([apps_dir, name, "mix.exs"]))
        end)

      _ ->
        false
    end
  end

  defp contains_dep?(texts, dep) do
    needle = ":" <> dep
    Enum.any?(texts, &(is_binary(&1) and String.contains?(&1, needle)))
  end

  defp read(root, rel) do
    with {:ok, abs} <- PathSafety.resolve(root, rel),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes <- File.stat(abs),
         {:ok, content} <- File.read(abs) do
      content
    else
      _ -> nil
    end
  end

  defp path_or_nil(root, rel) do
    case PathSafety.resolve(root, rel) do
      {:ok, abs} -> if File.dir?(abs), do: abs, else: nil
      _ -> nil
    end
  end
end
