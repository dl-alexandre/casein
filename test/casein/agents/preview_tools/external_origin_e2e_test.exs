defmodule Casein.Agents.PreviewTools.ExternalOriginE2ETest do
  @moduledoc """
  End-to-end proof for `preview_open mode=external`: an allowlisted origin
  outside this deployment's workspaces opens on the REAL stack — allowlist,
  pane registration, the `:playwright` control adapter and its own Chromium —
  and the browser lands on that origin **unrewritten**.

  Origin preservation is the whole point of the lane, so it is what this test
  asserts. Serving another product under a path prefix
  (`/preview-proxy/<ws>/<port>/…`) is what reconnect-loops a LiveView app: the
  join `url` cannot match the app's own router, so the join is refused and the
  client falls back to a full-page reload every 1-2s, forever. Pointing the
  browser at the real origin is what keeps the app's router, cookies, CSRF
  token, and `wss://` join all agreeing about who they are talking to.

  Excluded by default (`@tag :preview_e2e`) **and** skipped unless a target is
  named, because it reaches the public internet. Run it against any external
  app you have allowlisted:

      CASEIN_TEST_EXTERNAL_PREVIEW_URL=https://staging.example.com/login \\
        mix test --only preview_e2e test/casein/agents/preview_tools/external_origin_e2e_test.exs

  Requires the Node bridge deps (`mix preview.npm`) and a Playwright chromium
  build (`cd priv/scripts && npx playwright install chromium`).
  """
  use Casein.DataCase, async: false

  alias Casein.Agents.PreviewTools
  alias Casein.PreviewControl
  alias Casein.PreviewPanes
  alias Casein.Previews.Url
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  @moduletag :preview_e2e

  @workspace %{
    id: "ws-external-e2e",
    metadata: %{type: :v3, domain_base: "alice.devbox.example.com", ports: %{"app" => 10_100}}
  }

  @tmux_session "casein_ws_external_e2e"
  @pane_id "%external-e2e"

  setup do
    target = System.get_env("CASEIN_TEST_EXTERNAL_PREVIEW_URL")

    if is_nil(target) or target == "" do
      {:ok, skip: true}
    else
      prev_adapter = Application.get_env(:casein, :preview_control_adapter)
      prev_script = Application.get_env(:preview_ctl, :playwright_script)
      prev_tmux = Application.get_env(:casein, :tmux_adapter)
      prev_allowlist = Application.get_env(:casein, :preview_external_origins)
      prev_preflight = Application.get_env(:casein, :preview_open_preflight)

      Application.put_env(:casein, :preview_control_adapter, :playwright)
      Application.put_env(:preview_ctl, :playwright_script, "priv/scripts/preview_playwright.mjs")
      Application.put_env(:casein, :tmux_adapter, FakeAdapter)
      # The real reachability preflight is part of what we are proving here.
      Application.put_env(:casein, :preview_open_preflight, true)
      Application.put_env(:casein, :preview_external_origins, [Url.origin_of(target)])
      restart_bridge!()

      PreviewPanes.clear()
      seed_session!()

      on_exit(fn ->
        PreviewPanes.clear()
        FakeState.delete(:fake_tmux_windows)
        FakeState.delete(:fake_tmux_panes)
        restore(:casein, :preview_control_adapter, prev_adapter)
        restore(:casein, :tmux_adapter, prev_tmux)
        restore(:casein, :preview_external_origins, prev_allowlist)
        restore(:casein, :preview_open_preflight, prev_preflight)
        restore(:preview_ctl, :playwright_script, prev_script)
        restart_bridge!()
      end)

      {:ok, target: target, skip: false}
    end
  end

  test "an allowlisted external origin opens, and the browser stays on that origin", context do
    if context[:skip] do
      # No target named — nothing to reach.
      assert true
    else
      target = context[:target]
      origin = Url.origin_of(target)

      assert {:ok, payload} =
               PreviewTools.invoke("preview_open", @workspace, %{
                 "mode" => "external",
                 "url" => target,
                 "tmux_session" => @tmux_session
               })

      assert payload.preview_source == %{via: "external"}

      registration = PreviewPanes.get_by_pane(payload.pane_id)

      assert registration.url == target,
             "the pane must hold the caller's URL verbatim, got #{inspect(registration.url)}"

      # What the browser actually loaded — not what we asked it to load.
      assert {:ok, observation} = PreviewControl.observe_live(payload.session_id)
      loaded = observation[:url] || observation["url"]

      assert Url.origin_of(loaded) == origin,
             "browser left the target origin: #{inspect(loaded)} (expected #{origin}). " <>
               "A rewritten or path-prefixed URL here is the LiveView reconnect-loop bug."

      # Same-origin navigation stays inside the lane the allowlist opened.
      assert {:ok, _} = PreviewControl.navigate(payload.session_id, "/", [])
      assert {:ok, after_nav} = PreviewControl.observe_live(payload.session_id)
      assert Url.origin_of(after_nav[:url] || after_nav["url"]) == origin

      # This test exists to be read as evidence, so say what was reached.
      IO.puts("\n[external_e2e] requested #{target} -> browser loaded #{loaded}")
    end
  end

  test "an origin outside the allowlist is refused and opens no pane", context do
    if context[:skip] do
      assert true
    else
      assert {:error, %{error: :external_origin_not_allowed}} =
               PreviewTools.invoke("preview_open", @workspace, %{
                 "mode" => "external",
                 "url" => "https://not-allowlisted.invalid/login",
                 "tmux_session" => @tmux_session
               })

      assert PreviewPanes.list_for_workspace(@workspace.id) == []
    end
  end

  # --- helpers ---

  defp restart_bridge! do
    _ = Supervisor.terminate_child(Casein.Supervisor, PreviewCtl.Playwright.Bridge)
    {:ok, _} = Supervisor.restart_child(Casein.Supervisor, PreviewCtl.Playwright.Bridge)
    :ok
  end

  defp seed_session! do
    FakeState.put(:fake_tmux_windows, %{
      @tmux_session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      @tmux_session => [
        %{
          id: @pane_id,
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: "/tmp"
        }
      ]
    })
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)
end
