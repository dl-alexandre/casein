defmodule DevideMob.SessionConfigTest do
  use ExUnit.Case, async: false

  alias DevideMob.OriginIdentity
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
             %{
               origin_id: OriginIdentity.legacy_id("https://devide.devbox.test"),
               display_name: "Devbox",
               url: "https://devide.devbox.test",
               active?: true,
               last_workspace_id: "devbox-ws"
             },
             %{
               origin_id: OriginIdentity.legacy_id("http://192.168.1.72:57585"),
               display_name: "Local Mac",
               url: "http://192.168.1.72:57585",
               active?: false,
               last_workspace_id: "mac-ws"
             }
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

    assert SessionConfig.host_profiles() == [
             %{
               origin_id: OriginIdentity.legacy_id("https://mac.test"),
               display_name: "mac.test",
               url: "https://mac.test",
               active?: false,
               last_workspace_id: nil
             }
           ]

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

  test "stable origin identity updates URL without duplicating the profile" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-mac",
      display_name: "Local Mac",
      url: "http://192.168.1.10:4000",
      token: "old-token"
    })

    SessionConfig.pin_workspace("mac-ws")

    SessionConfig.put_pairing(%{
      origin_id: "origin-mac",
      display_name: "Local Mac",
      url: "https://macbook.local:4443",
      token: "new-token"
    })

    assert SessionConfig.pairing() == {:ok, "https://macbook.local:4443", "new-token"}
    assert SessionConfig.pinned_workspaces() == ["mac-ws"]

    assert [%{origin_id: "origin-mac", url: "https://macbook.local:4443"}] =
             SessionConfig.host_profiles()
  end

  test "authoritative descriptor upgrades legacy identity and rejects stable mismatches" do
    SessionConfig.put_pairing("https://devide.test", "token")

    assert {:ok, %{origin_id: "origin-1", display_name: "Devbox"}} =
             SessionConfig.reconcile_active_origin(%{
               "id" => "origin-1",
               "display_name" => "Devbox"
             })

    assert {:error, :origin_mismatch} =
             SessionConfig.reconcile_active_origin(%{
               "id" => "tampered-origin",
               "display_name" => "Other"
             })
  end

  test "URL-keyed profile storage migrates without losing credentials or resume context" do
    url = "https://legacy.test"

    Mob.State.put(:session_host_profiles, %{
      url => %{
        url: url,
        token: "legacy-token",
        pinned_workspaces: ["legacy-ws"],
        resume_context: %{workspace_id: "legacy-ws", session_id: "legacy-session"}
      }
    })

    Mob.State.put(:session_active_host, url)

    origin_id = OriginIdentity.legacy_id(url)
    assert {:ok, ^url, "legacy-token"} = SessionConfig.pairing()
    assert [%{origin_id: ^origin_id, active?: true}] = SessionConfig.host_profiles()
    assert SessionConfig.pinned_workspaces() == ["legacy-ws"]

    assert SessionConfig.resume_context() == %{
             workspace_id: "legacy-ws",
             session_id: "legacy-session"
           }
  end

  test "inactive cache is bounded, minimal, origin-qualified, and read-only" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-mac",
      display_name: "Local Mac",
      url: "https://mac.test",
      token: "mac-token"
    })

    cards =
      for index <- 1..35 do
        %{
          "id" => "card-#{index}",
          "workspace_id" => "mac-ws",
          "title" => "Card #{index}",
          "actions" => [%{"id" => "approve"}],
          "intervention" => %{
            "recent_output" => "must-not-cache",
            "action" => %{"id" => "follow_up"}
          },
          "evidence" => %{
            "version" => 1,
            "changed_files" => %{
              "count" => 1,
              "files" => ["lib/card_#{index}.ex"],
              "truncated" => false
            },
            "diff" => %{"excerpt" => "must-not-cache", "truncated" => false},
            "artifact" => %{
              "kind" => "preview_artifact",
              "filename" => "card-#{index}.png",
              "media_type" => "image/png",
              "byte_size" => 42,
              "pwa_url" => "https://mac.test/credential-free-but-live-only"
            },
            "links" => [
              %{"url" => "https://mac.test/workspaces/mac-ws?tab=diff"}
            ]
          },
          "token" => "must-not-cache",
          "resume" => %{
            "state" => "working",
            "token" => "nested-token",
            "actions" => [%{"id" => "approve"}],
            "locator" => %{
              "workspace_id" => "mac-ws",
              "origin_id" => "tampered-origin",
              "token" => "nested-token"
            }
          }
        }
      end

    assert :ok = SessionConfig.cache_cards("origin-mac", cards, "2026-07-23T12:00:00Z")

    SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://devbox.test",
      token: "devbox-token"
    })

    cached = SessionConfig.inactive_cached_cards()
    assert Enum.count(cached) == 30
    assert Enum.all?(cached, &(&1["_cached"] == true))
    assert Enum.all?(cached, &(&1["origin"]["id"] == "origin-mac"))
    refute Enum.any?(cached, &Map.has_key?(&1, "actions"))
    refute Enum.any?(cached, &Map.has_key?(&1, "intervention"))
    refute Enum.any?(cached, &Map.has_key?(&1, "token"))
    assert hd(cached)["resume"]["freshness"]["kind"] == "cached"
    refute Map.has_key?(hd(cached)["resume"], "actions")
    refute Map.has_key?(hd(cached)["resume"], "token")
    assert hd(cached)["evidence"]["freshness"]["kind"] == "cached"
    assert hd(cached)["evidence"]["changed_files"]["files"] == ["lib/card_1.ex"]
    assert hd(cached)["evidence"]["artifact"]["filename"] == "card-1.png"
    refute Map.has_key?(hd(cached)["evidence"], "diff")
    refute Map.has_key?(hd(cached)["evidence"], "links")
    refute Map.has_key?(hd(cached)["evidence"]["artifact"], "pwa_url")

    assert hd(cached)["resume"]["locator"] == %{
             "origin_id" => "origin-mac",
             "workspace_id" => "mac-ws"
           }
  end

  defp restore_app_env(nil), do: Application.delete_env(:devide_mob, :session)
  defp restore_app_env(value), do: Application.put_env(:devide_mob, :session, value)
end
