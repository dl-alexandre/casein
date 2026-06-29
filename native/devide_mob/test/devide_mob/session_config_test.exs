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

  defp restore_app_env(nil), do: Application.delete_env(:devide_mob, :session)
  defp restore_app_env(value), do: Application.put_env(:devide_mob, :session, value)
end
