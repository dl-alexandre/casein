defmodule CaseinMob.SessionConfigTest do
  use ExUnit.Case, async: false

  alias CaseinMob.OriginIdentity
  alias CaseinMob.SessionConfig

  @env_names ~w(
    CASEIN_MOB_DEV_PAIRING_URL
    CASEIN_MOB_DEV_PAIRING_TOKEN
    CASEIN_MOB_DEV_PINNED_WORKSPACES
  )

  setup do
    previous_env = Map.new(@env_names, &{&1, System.get_env(&1)})
    previous_session = Application.get_env(:casein_mob, :session)

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

    System.put_env("CASEIN_MOB_DEV_PAIRING_URL", "https://casein.test")
    System.put_env("CASEIN_MOB_DEV_PAIRING_TOKEN", "dev-token")

    assert SessionConfig.pairing() == {:ok, "https://casein.test", "dev-token"}
  end

  test "runtime dev pinned workspace env overrides local pinned state" do
    SessionConfig.pin_workspace("stored-ws")
    System.put_env("CASEIN_MOB_DEV_PINNED_WORKSPACES", "ws-1, ws-2,, ")

    assert SessionConfig.pinned_workspaces() == ["ws-1", "ws-2"]
  end

  test "saved hosts retain independent pins and resume context" do
    SessionConfig.put_pairing("http://192.168.1.72:57585/", "mac-token")
    SessionConfig.pin_workspace("mac-ws")
    SessionConfig.put_resume_context("mac-ws", session_id: "mac-run")

    SessionConfig.put_pairing("https://casein.devbox.test", "devbox-token")
    SessionConfig.pin_workspace("devbox-ws")

    assert SessionConfig.host_profiles() == [
             %{
               origin_id: OriginIdentity.legacy_id("https://casein.devbox.test"),
               display_name: "Devbox",
               url: "https://casein.devbox.test",
               active?: true,
               read_only?: false,
               last_workspace_id: "devbox-ws"
             },
             %{
               origin_id: OriginIdentity.legacy_id("http://192.168.1.72:57585"),
               display_name: "Local Mac",
               url: "http://192.168.1.72:57585",
               active?: false,
               read_only?: false,
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

    assert {:ok, "https://casein.devbox.test", "devbox-token"} =
             SessionConfig.activate_host("https://casein.devbox.test")

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
               read_only?: false,
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

  test "terminal target is bound to the active origin and selected workspace" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://casein.devbox.test",
      token: "token"
    })

    SessionConfig.pin_workspace("ws-1")
    SessionConfig.put_resume_context("ws-1")

    assert {:ok, %{origin_id: "origin-devbox", origin_name: "Devbox", workspace_id: "ws-1"}} =
             SessionConfig.terminal_target(%{
               origin_id: "origin-devbox",
               workspace_id: "ws-1"
             })

    assert {:error, :inactive_origin} =
             SessionConfig.terminal_target(%{
               origin_id: "origin-old",
               workspace_id: "ws-1"
             })

    assert {:error, :workspace_not_selected} =
             SessionConfig.terminal_target(%{
               origin_id: "origin-devbox",
               workspace_id: "stale-ws"
             })
  end

  test "terminal target follows profile switches without falling back across origins" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-one",
      display_name: "One",
      url: "https://one.test",
      token: "one-token"
    })

    SessionConfig.pin_workspace("one-ws")

    SessionConfig.put_pairing(%{
      origin_id: "origin-two",
      display_name: "Two",
      url: "https://two.test",
      token: "two-token"
    })

    SessionConfig.pin_workspace("two-ws")

    assert {:ok, %{origin_id: "origin-two", workspace_id: "two-ws"}} =
             SessionConfig.default_terminal_target()

    assert {:error, :workspace_not_selected} =
             SessionConfig.terminal_target(%{workspace_id: "one-ws"})

    assert {:ok, %{origin_id: "origin-one"}} = SessionConfig.activate_origin("origin-one")

    assert {:ok, %{origin_id: "origin-one", workspace_id: "one-ws"}} =
             SessionConfig.default_terminal_target()
  end

  test "terminal target is unavailable without an eligible workspace or on a legacy origin" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://casein.devbox.test",
      token: "token"
    })

    assert {:error, :workspace_not_selected} = SessionConfig.default_terminal_target()

    SessionConfig.put_pairing("https://devide.devbox.milcgroup.com", "legacy-token")

    assert {:ok, %{origin_id: "origin-devbox"}} =
             SessionConfig.activate_origin("origin-devbox")

    assert {:error, :inactive_origin} =
             SessionConfig.terminal_target(%{origin_id: "legacy-origin", workspace_id: "ws"})
  end

  test "terminal target requires an explicit origin and pinned workspace" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://casein.devbox.test",
      token: "token"
    })

    SessionConfig.put_resume_context("resume-only")

    assert {:error, :workspace_not_selected} = SessionConfig.terminal_target(%{})

    assert {:error, :workspace_not_selected} =
             SessionConfig.terminal_target(%{
               origin_id: "origin-devbox",
               workspace_id: "resume-only"
             })
  end

  test "active legacy profile is classified as read-only before authentication" do
    legacy_url = "https://devide.devbox.milcgroup.com"
    legacy_origin = OriginIdentity.legacy_id(legacy_url)

    SessionConfig.put_pairing(legacy_url, "legacy-token")
    Mob.State.put(:session_active_host, legacy_origin)

    assert {:error, :legacy_origin} =
             SessionConfig.terminal_target(%{
               origin_id: legacy_origin,
               workspace_id: "ws"
             })
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
    SessionConfig.put_pairing("https://casein.test", "token")

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

  test "deprecated Devbox profile stays distinct, credential-free, and read-only" do
    old_url = "https://devide.devbox.milcgroup.com"
    canonical_url = "https://casein.devbox.milcgroup.com"

    SessionConfig.put_pairing(%{
      origin_id: "installation-1",
      display_name: "Devbox",
      url: old_url,
      token: "old-token"
    })

    assert SessionConfig.connection() == :error

    SessionConfig.put_pairing(%{
      origin_id: "installation-1",
      display_name: "Devbox",
      url: canonical_url,
      token: "canonical-token"
    })

    old_id = OriginIdentity.legacy_id(old_url)

    assert SessionConfig.host_profiles() == [
             %{
               origin_id: "installation-1",
               display_name: "Devbox",
               url: canonical_url,
               active?: true,
               read_only?: false,
               last_workspace_id: nil
             },
             %{
               origin_id: old_id,
               display_name: "Devbox (legacy)",
               url: old_url,
               active?: false,
               read_only?: true,
               last_workspace_id: nil
             }
           ]

    assert SessionConfig.pairing() == {:ok, canonical_url, "canonical-token"}
    assert SessionConfig.activate_origin(old_id) == :error
    assert SessionConfig.activate_host(old_url) == :error
  end

  test "stored deprecated stable profile migrates without leaking token or resume state" do
    old_url = "https://devide.devbox.milcgroup.com"

    Mob.State.put(:session_host_profiles, %{
      "installation-1" => %{
        origin_id: "installation-1",
        display_name: "Devbox",
        url: old_url,
        token: "must-be-dropped",
        pinned_workspaces: ["old-ws"],
        resume_context: %{workspace_id: "old-ws"}
      }
    })

    Mob.State.put(:session_active_host, "installation-1")

    assert SessionConfig.connection() == :error
    assert SessionConfig.pairing() == :error

    assert [
             %{
               origin_id: old_id,
               read_only?: true,
               active?: false,
               last_workspace_id: "old-ws"
             }
           ] = SessionConfig.host_profiles()

    assert old_id == OriginIdentity.legacy_id(old_url)
  end

  test "deprecated durable pairing fallback is ignored after profile migration" do
    old_url = "https://devide.devbox.milcgroup.com"

    Mob.State.put(:session_host_profiles, %{
      "installation-1" => %{
        origin_id: "installation-1",
        display_name: "Devbox",
        url: old_url,
        token: "must-never-reconnect"
      }
    })

    Mob.State.put(:session_active_host, "installation-1")

    Mob.State.put(:session_pairing, %{
      origin_id: "installation-1",
      display_name: "Devbox",
      url: old_url,
      token: "must-never-reconnect"
    })

    assert SessionConfig.pairing() == :error
    assert SessionConfig.connection() == :error
  end

  test "equivalent deprecated origin spellings are credential-free and cannot activate" do
    for url <- [
          "https://DEVIDE.devbox.milcgroup.com",
          "https://devide.devbox.milcgroup.com:443/",
          "https://devide.devbox.milcgroup.com/pair/ws?source=old"
        ] do
      SessionConfig.clear_all()
      SessionConfig.put_pairing(%{origin_id: "stable", url: url, token: "must-drop"})

      assert SessionConfig.pairing() == :error
      assert SessionConfig.connection() == :error
      assert [%{read_only?: true, url: normalized}] = SessionConfig.host_profiles()
      assert normalized == "https://devide.devbox.milcgroup.com"
      assert SessionConfig.activate_host(url) == :error
    end
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

  test "inactive clarification cache never persists the question body" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-mac",
      display_name: "Local Mac",
      url: "https://mac.test",
      token: "mac-token"
    })

    assert :ok =
             SessionConfig.cache_cards(
               "origin-mac",
               [
                 %{
                   "id" => "clarification-1",
                   "workspace_id" => "mac-ws",
                   "session_id" => "agent-task-1",
                   "title" => "Agent needs clarification",
                   "body" => "Sensitive question that must stay live-only",
                   "type" => "clarification"
                 }
               ],
               "2026-07-23T12:00:00Z"
             )

    SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://devbox.test",
      token: "devbox-token"
    })

    [cached] = SessionConfig.inactive_cached_cards()
    assert cached["body"] == "Open Casein to view this request."
    refute inspect(cached) =~ "Sensitive question"
  end

  defp restore_app_env(nil), do: Application.delete_env(:casein_mob, :session)
  defp restore_app_env(value), do: Application.put_env(:casein_mob, :session, value)
end
