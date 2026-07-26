defmodule Casein.Desktop.RuntimeTest do
  use ExUnit.Case, async: false

  alias Casein.Desktop.Runtime

  @env_vars ~w(CASEIN_PROFILE CASEIN_DESKTOP_DATA_DIR CASEIN_DESKTOP_STATUS_PATH XDG_DATA_HOME LOCALAPPDATA APPDATA DATABASE_PATH SQLITE_DATABASE_PATH PORT)

  setup do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "recognizes only the desktop profile" do
    refute Runtime.desktop_profile?()
    System.put_env("CASEIN_PROFILE", "desktop")
    assert Runtime.desktop_profile?()
  end

  test "uses the explicit desktop data directory for local state" do
    System.put_env("CASEIN_DESKTOP_DATA_DIR", "/tmp/casein-desktop")

    assert Runtime.data_dir() == "/tmp/casein-desktop"
    assert Runtime.database_path() == "/tmp/casein-desktop/casein.sqlite3"
    assert Runtime.status_path() == "/tmp/casein-desktop/runtime.json"
  end

  test "requires an explicit non-privileged port for the desktop listener" do
    System.put_env("PORT", "0")

    assert_raise RuntimeError, ~r/between 1024 and 65535/, fn ->
      Runtime.requested_port()
    end

    System.put_env("PORT", "45873")
    assert Runtime.requested_port() == 45_873
  end

  test "uses native per-user data directories" do
    System.put_env("LOCALAPPDATA", "C:/Users/test/AppData/Local")
    System.put_env("XDG_DATA_HOME", "/home/test/.local/share")

    assert Runtime.data_dir({:win32, :nt}) == "C:/Users/test/AppData/Local/Casein"
    assert Runtime.data_dir({:unix, :linux}) == "/home/test/.local/share/casein"

    assert Runtime.data_dir({:unix, :darwin}) ==
             Path.join(System.user_home!(), "Library/Application Support/Casein")
  end

  test "honors database and status path overrides" do
    System.put_env("DATABASE_PATH", "/tmp/custom.sqlite3")
    System.put_env("CASEIN_DESKTOP_STATUS_PATH", "/tmp/status.json")

    assert Runtime.database_path() == "/tmp/custom.sqlite3"
    assert Runtime.status_path() == "/tmp/status.json"
  end

  test "accepts explicit desktop listener ports and rejects malformed values" do
    System.put_env("PORT", "4242")
    assert Runtime.requested_port() == 4242

    System.put_env("PORT", "invalid")
    assert_raise RuntimeError, ~r/PORT must be an integer/, &Runtime.requested_port/0
  end
end
