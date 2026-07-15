defmodule DevIDEWeb.WorkspaceLive.PreviewPaneE2ETest do
  @moduledoc """
  Slice 1 of preview-driven pane test runs: an end-to-end visual-regression
  check that exercises the REAL stack — pane registration, the `:playwright`
  control adapter, and its own headless Chromium — with NO operator viewer
  attached. This is the smallest thing that proves the whole chain works;
  functional flows (LiveView updates, split/close) and app-content regression
  are later slices, each with their own golden.

  Excluded by default (`@tag :preview_e2e`). Run explicitly:

      mix test --only preview_e2e

  Requires the Node bridge deps (`mix preview.npm`) and a Playwright chromium
  build (`cd priv/scripts && npx playwright install chromium`). Bootstrap or
  refresh the committed golden image with:

      PREVIEW_UPDATE_GOLDEN=1 mix test --only preview_e2e

  Notes for future maintainers:

  * We assert on the control-session screenshot artifact, NOT on
    `preview_observe_pane`'s `operator_visible`/`browser_loaded` — those reflect
    the operator's LiveView iframe telemetry, which is absent headlessly and
    would always read false here.
  * The content under test is a frozen static fixture served over loopback, so
    the golden measures the *pane rendering pipeline*, not some live app whose
    content drifts.
  """
  use DevIDE.DataCase, async: false

  alias DevIDE.PreviewControl
  alias DevIDE.PreviewPanes
  alias DevIDE.Previews.Artifacts
  alias DevIDE.Previews.Storage.LocalDisk
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  @moduletag :preview_e2e

  # The screenshot's dimensions are fixed by the Playwright browser context's
  # default viewport (1280x720) — a registration `viewport` only bounds click
  # coordinates, it is NOT plumbed to the daemon context. That default is stable
  # run-to-run, and any drift is caught as a hard pixelmatch dimension mismatch
  # rather than a diff percentage. (Plumbing viewport through to the context is a
  # separate lib change; see the accompanying notes.)

  @golden_dir Path.expand("../../../fixtures/preview_goldens", __DIR__)
  @golden_path Path.join(@golden_dir, "preview_pane_fixture.png")

  # Max fraction of pixels allowed to differ from the golden. pixelmatch runs
  # with includeAA:false, so this only needs to absorb minor sub-pixel churn.
  @max_diff_pct 1.0

  # Deterministic, self-contained fixture: fixed layout, system font with
  # smoothing off, solid colors, no animation, no external resources.
  @fixture_html """
  <!doctype html>
  <html>
    <head>
      <meta charset="utf-8" />
      <title>preview-pane-e2e</title>
      <style>
        html, body {
          margin: 0; padding: 0; background: #0b1021; color: #e6e6e6;
          font-family: Arial, sans-serif; -webkit-font-smoothing: none;
        }
        .box {
          position: absolute; top: 80px; left: 80px; width: 640px; height: 200px;
          background: #1f6feb; border: 8px solid #e6e6e6; box-sizing: border-box;
        }
        h1 { position: absolute; top: 120px; left: 112px; font-size: 48px; margin: 0; }
        .swatch { position: absolute; top: 360px; width: 160px; height: 120px; }
      </style>
    </head>
    <body>
      <div class="box"></div>
      <h1>DevIDE preview pane</h1>
      <div class="swatch" style="left: 80px; background: #2ea043"></div>
      <div class="swatch" style="left: 280px; background: #d29922"></div>
      <div class="swatch" style="left: 480px; background: #f85149"></div>
    </body>
  </html>
  """

  setup do
    # --- real playwright adapter + node bridge (mirrors AdapterTest) ---
    prev_adapter = Application.get_env(:dev_ide, :preview_control_adapter)
    prev_script = Application.get_env(:preview_ctl, :playwright_script)
    Application.put_env(:dev_ide, :preview_control_adapter, :playwright)
    Application.put_env(:preview_ctl, :playwright_script, "priv/scripts/preview_playwright.mjs")
    restart_bridge!()

    # --- fake tmux so pane registration needs no real tmux server ---
    prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)
    PreviewPanes.clear()
    FakeState.delete(:fake_tmux_windows)
    FakeState.delete(:fake_tmux_panes)

    # --- static fixture served on loopback for Chromium to load ---
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, @fixture_html)
    end)

    on_exit(fn ->
      PreviewPanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      restore(:dev_ide, :preview_control_adapter, prev_adapter)
      restore(:dev_ide, :tmux_adapter, prev_tmux)
      restore(:dev_ide, :workspaces_root, prev_root)
      restore(:preview_ctl, :playwright_script, prev_script)
      restart_bridge!()
    end)

    {:ok, bypass: bypass}
  end

  test "preview pane renders the fixture matching the golden", %{bypass: bypass} do
    path = seed_workspace!()
    session = "devide_ws_e2e"
    pane_id = "%e2e"
    seed_session!(session, pane_id)
    url = "http://localhost:#{bypass.port}/"

    # Registering the pane opens its bound control session on the :playwright
    # adapter — no viewer, no tmux server, no workspace token.
    assert {:ok, reg} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => url,
               "cwd" => path,
               "tmux_session" => session
             })

    session_id = reg.control_session_id

    assert {:ok, _} = PreviewControl.navigate(session_id, url, [])
    assert {:ok, obs} = PreviewControl.screenshot(session_id, [])

    current_path = obs[:artifact_path] || obs["artifact_path"]

    assert is_binary(current_path) and String.starts_with?(current_path, "/preview-artifacts/"),
           "screenshot degraded to simulated output (#{inspect(current_path)}) — is Playwright " <>
             "chromium installed? try: cd priv/scripts && npx playwright install chromium"

    # Derive the workspace id from the artifact path itself so the golden is
    # stored under the SAME scope the screenshot landed in.
    {ws_id, current_file} = parse_artifact!(current_path)
    current_bytes = File.read!(LocalDisk.safe_path!(ws_id, current_file))

    assert <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = current_bytes,
           "screenshot artifact is not a PNG"

    if update_golden?() do
      File.mkdir_p!(@golden_dir)
      File.write!(@golden_path, current_bytes)

      IO.puts(
        "\n[preview_e2e] wrote golden #{@golden_path} " <>
          "(#{byte_size(current_bytes)} bytes) — commit it and re-run without PREVIEW_UPDATE_GOLDEN"
      )
    else
      # Stage the committed golden as a workspace artifact so we can drive the
      # production comparator (which reads servable /preview-artifacts paths).
      golden_path =
        Artifacts.store_png!(ws_id, System.unique_integer([:positive]), File.read!(@golden_path))

      case PreviewControl.compare_snapshots(%{id: ws_id}, golden_path, current_path,
             threshold: 0.1
           ) do
        {:ok, diff} ->
          pct = diff[:diff_pct] || 0.0
          overlay = diff[:diff_image_url]

          assert pct <= @max_diff_pct,
                 "preview pane diverged from golden by #{pct}% (budget #{@max_diff_pct}%). " <>
                   "overlay diff image: #{inspect(overlay)}. If the change is intended, refresh " <>
                   "with PREVIEW_UPDATE_GOLDEN=1 mix test --only preview_e2e"

        {:error, :dimension_mismatch} ->
          flunk(
            "screenshot dimensions != golden — Playwright default viewport changed? " <>
              "regenerate with PREVIEW_UPDATE_GOLDEN=1 mix test --only preview_e2e"
          )

        {:error, reason} ->
          flunk("compare_snapshots failed: #{inspect(reason)}")
      end
    end
  end

  # --- helpers ---

  defp update_golden?,
    do: System.get_env("PREVIEW_UPDATE_GOLDEN") == "1" or not File.exists?(@golden_path)

  # "/preview-artifacts/<ws_id>/<file>" -> {ws_id, file}
  defp parse_artifact!(servable_path) do
    path = servable_path |> URI.parse() |> Map.get(:path) || servable_path

    ["preview-artifacts", ws_id, file] =
      path |> String.trim_leading("/") |> Path.split()

    {ws_id, file}
  end

  defp restart_bridge! do
    _ = Supervisor.terminate_child(DevIDE.Supervisor, PreviewCtl.Playwright.Bridge)
    {:ok, _} = Supervisor.restart_child(DevIDE.Supervisor, PreviewCtl.Playwright.Bridge)
    :ok
  end

  defp seed_workspace! do
    root = Path.join(System.tmp_dir!(), "preview-e2e-#{System.unique_integer([:positive])}")
    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)
    path
  end

  defp seed_session!(session, pane_id) do
    FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: pane_id,
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "devide-preview",
          current_path: "/tmp"
        }
      ]
    })
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)
end
