defmodule DevIDE.Terminals.TmuxExecutable do
  @moduledoc """
  Resolves the tmux executable used for host-side terminal operations.

  Desktop releases prefer their bundled runtime so Finder launches do not
  depend on Homebrew or the caller's `PATH`. Operators may override the binary
  explicitly; development and server installs retain the normal PATH fallback.
  Container and SSH commands intentionally do not use this resolver because
  tmux must be resolved inside the remote execution environment.
  """

  @env_key "DEV_IDE_TMUX_EXECUTABLE"

  @spec resolve() :: String.t()
  def resolve do
    configured() || bundled() || System.find_executable("tmux") || "tmux"
  end

  @doc false
  @spec bundled(Path.t() | nil) :: Path.t() | nil
  def bundled(priv_dir \\ app_priv_dir()) do
    with true <- darwin?(),
         path when is_binary(path) <- bundled_path(priv_dir),
         true <- executable_file?(path) do
      path
    else
      _ -> nil
    end
  end

  defp configured do
    [System.get_env(@env_key), Application.get_env(:dev_ide, :tmux_executable)]
    |> Enum.find(&executable_file?/1)
  end

  defp bundled_path(priv_dir) when is_binary(priv_dir), do: Path.join(priv_dir, "bin/tmux")
  defp bundled_path(_priv_dir), do: nil

  defp app_priv_dir do
    case :code.priv_dir(:dev_ide) do
      path when is_list(path) -> to_string(path)
      _ -> nil
    end
  end

  defp executable_file?(path) when is_binary(path) and path != "" do
    File.regular?(path) and
      match?({:ok, %{mode: mode}} when Bitwise.band(mode, 0o111) != 0, File.stat(path))
  end

  defp executable_file?(_path), do: false

  defp darwin?, do: match?({:unix, :darwin}, :os.type())
end
