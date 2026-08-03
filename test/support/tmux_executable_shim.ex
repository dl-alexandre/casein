defmodule Casein.Test.TmuxExecutableShim do
  @moduledoc false

  @env_key "CASEIN_TMUX_EXECUTABLE"

  def install! do
    previous_app = Application.get_env(:casein, :tmux_executable)
    previous_env = System.get_env(@env_key)

    root =
      Path.join(
        System.tmp_dir!(),
        "casein-test-tmux-#{System.unique_integer([:positive, :monotonic])}"
      )

    executable = Path.join(root, "tmux")
    File.mkdir_p!(root)

    File.write!(
      executable,
      """
      #!/bin/sh
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -L|-S|-f) shift 2 ;;
          -*) shift ;;
          new-session) exec /bin/cat ;;
          *) exit 0 ;;
        esac
      done
      exit 0
      """
    )

    File.chmod!(executable, 0o700)
    Application.put_env(:casein, :tmux_executable, executable)
    System.put_env(@env_key, executable)

    fn ->
      restore_app_env(previous_app)
      restore_system_env(previous_env)
      File.rm_rf(root)
      :ok
    end
  end

  defp restore_app_env(nil), do: Application.delete_env(:casein, :tmux_executable)
  defp restore_app_env(value), do: Application.put_env(:casein, :tmux_executable, value)

  defp restore_system_env(nil), do: System.delete_env(@env_key)
  defp restore_system_env(value), do: System.put_env(@env_key, value)
end
