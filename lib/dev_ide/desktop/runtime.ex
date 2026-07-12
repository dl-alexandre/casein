defmodule DevIDE.Desktop.Runtime do
  @moduledoc """
  Runtime configuration helpers for the local desktop profile.

  The desktop profile is a loopback-only Phoenix release backed by SQLite.
  SQLite remains a compile-time choice, so desktop releases must be assembled
  with `DEV_IDE_REPO_ADAPTER=sqlite`.
  """

  @profile "desktop"

  @spec desktop_profile?() :: boolean()
  def desktop_profile?, do: System.get_env("DEV_IDE_PROFILE") == @profile

  @spec data_dir() :: Path.t()
  def data_dir, do: data_dir(:os.type())

  @doc false
  @spec data_dir({atom(), atom()}) :: Path.t()
  def data_dir(os_type) do
    System.get_env("DEV_IDE_DESKTOP_DATA_DIR") ||
      default_data_dir(os_type)
  end

  @spec database_path() :: Path.t()
  def database_path do
    System.get_env("DATABASE_PATH") ||
      System.get_env("SQLITE_DATABASE_PATH") ||
      Path.join(data_dir(), "devide.sqlite3")
  end

  @spec status_path() :: Path.t()
  def status_path do
    System.get_env("DEV_IDE_DESKTOP_STATUS_PATH") ||
      Path.join(data_dir(), "runtime.json")
  end

  @spec requested_port() :: 0..65_535
  def requested_port do
    case Integer.parse(System.get_env("PORT", "0")) do
      {port, ""} when port in 0..65_535 -> port
      _ -> raise "PORT must be an integer between 0 and 65535 for desktop mode"
    end
  end

  defp default_data_dir({:win32, _}) do
    root =
      present_env("LOCALAPPDATA") ||
        present_env("APPDATA") ||
        Path.join(user_home!(), "AppData/Local")

    Path.join(root, "DevIDE")
  end

  defp default_data_dir({:unix, :darwin}) do
    Path.join(user_home!(), "Library/Application Support/DevIDE")
  end

  defp default_data_dir(_os_type) do
    Path.join(xdg_data_home(), "devide")
  end

  defp xdg_data_home do
    case System.get_env("XDG_DATA_HOME") do
      value when is_binary(value) and value != "" -> value
      _ -> Path.join(user_home!(), ".local/share")
    end
  end

  defp user_home! do
    System.user_home() ||
      raise "cannot resolve a user home directory for the desktop data path"
  end

  defp present_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
