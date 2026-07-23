defmodule DevideMob.SessionConfigTest do
  use ExUnit.Case, async: false

  alias DevideMob.SessionConfig

  @env_names ~w(
    DEVIDE_MOB_DEV_PAIRING_URL
    DEVIDE_MOB_DEV_PAIRING_TOKEN
    DEVIDE_MOB_DEV_PINNED_WORKSPACES
  )

  setup do
    previous_env = Map.new(@env_names, &{&1, System.get_env(&1)})
    previous_session = Application.get_env(:devide_mob, :session)

    if Process.whereis(Mob.State) == nil do
      start_supervised!(Mob.State)
    end

    SessionConfig.clear_all()
    Enum.each(@env_names, &System.delete_env/1)

    on_exit(fn ->
      restore_app_env(previous_session)

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      if Process.whereis(Mob.State) do
        SessionConfig.clear_all()
      end
    end)

    :ok
  end

  test "runtime dev pairing env overrides cleared local pairing for simulator smoke tests" do
    SessionConfig.put_pairing("https://stored.test", "stored-token")
    SessionConfig.clear_pairing()

    System.put_env("DEVIDE_MOB_DEV_PAIRING_URL", "https://devide.test")
    System.put_env("DEVIDE_MOB_DEV_PAIRING_TOKEN", "dev-token")

    assert SessionConfig.pairing() == {:ok, "https://devide.test", "dev-token"}
  end

  test "runtime dev pinned workspace env overrides local pinned state" do
    SessionConfig.pin_workspace("stored-ws")
    System.put_env("DEVIDE_MOB_DEV_PINNED_WORKSPACES", "ws-1, ws-2,, ")

    assert SessionConfig.pinned_workspaces() == ["ws-1", "ws-2"]
  end

  test "saved hosts retain independent pins and resume context" do
    SessionConfig.put_pairing("http://192.168.1.72:57585/", "mac-token")
    SessionConfig.pin_workspace("mac-ws")
    SessionConfig.put_resume_context("mac-ws", session_id: "mac-run")

    SessionConfig.put_pairing("https://devide.devbox.test", "devbox-token")
    SessionConfig.pin_workspace("devbox-ws")

    assert SessionConfig.host_profiles() == [
             %{url: "http://192.168.1.72:57585", active?: false},
             %{url: "https://devide.devbox.test", active?: true}
           ]

    assert {:ok, "http://192.168.1.72:57585", "mac-token"} =
             SessionConfig.activate_host("http://192.168.1.72:57585/")

    assert SessionConfig.pinned_workspaces() == ["mac-ws"]

    assert SessionConfig.resume_context() == %{
             workspace_id: "mac-ws",
             session_id: "mac-run",
             source: :workspace
           }

    assert {:ok, "https://devide.devbox.test", "devbox-token"} =
             SessionConfig.activate_host("https://devide.devbox.test")

    assert SessionConfig.pinned_workspaces() == ["devbox-ws"]
    assert SessionConfig.resume_context() == nil
  end

  test "clearing the active pairing preserves other saved hosts" do
    SessionConfig.put_pairing("https://mac.test", "mac-token")
    SessionConfig.put_pairing("https://devbox.test", "devbox-token")

    SessionConfig.clear_pairing()

    assert SessionConfig.pairing() == :error
    assert SessionConfig.host_profiles() == [%{url: "https://mac.test", active?: false}]

    assert SessionConfig.activate_host("https://mac.test") ==
             {:ok, "https://mac.test", "mac-token"}
  end

  test "resume context persists the last workspace and optional session id" do
    assert SessionConfig.resume_context() == nil

    assert :ok =
             SessionConfig.put_resume_context("ws-1",
               session_id: "run-1",
               source: :review
             )

    assert SessionConfig.resume_context() == %{
             workspace_id: "ws-1",
             session_id: "run-1",
             source: :review
           }
  end

  test "clearing all state clears resume context" do
    SessionConfig.put_pairing("https://stored.test", "stored-token")
    SessionConfig.pin_workspace("ws-1")
    SessionConfig.put_resume_context("ws-1")

    SessionConfig.clear_all()

    assert SessionConfig.pairing() == :error
    assert SessionConfig.pinned_workspaces() == []
    assert SessionConfig.resume_context() == nil
  end

  test "unpinning the resumed workspace clears resume context" do
    SessionConfig.pin_workspace("ws-1")
    SessionConfig.pin_workspace("ws-2")
    SessionConfig.put_resume_context("ws-1")

    SessionConfig.unpin_workspace("ws-2")
    assert SessionConfig.resume_context() == %{workspace_id: "ws-1", source: :workspace}

    SessionConfig.unpin_workspace("ws-1")
    assert SessionConfig.resume_context() == nil
  end

  defp restore_app_env(nil), do: Application.delete_env(:devide_mob, :session)
  defp restore_app_env(value), do: Application.put_env(:devide_mob, :session, value)
end
