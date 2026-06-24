defmodule DevIDEPreviewBrowserTest do
  use ExUnit.Case, async: true

  alias DevIDEPreviewBrowser.{Browser, Health, Screenshot}

  test "opens a browser, navigates, emits load events, and observes state" do
    {:ok, session} =
      DevIDEPreviewBrowser.start_link(
        backend: DevIDEPreviewBrowser.FakeBackend,
        event_owner: self()
      )

    assert {:ok, %Browser{id: browser_id} = browser} =
             DevIDEPreviewBrowser.open_browser(session, url: "about:blank")

    assert {:ok, observation} =
             DevIDEPreviewBrowser.navigate(browser, "http://127.0.0.1:4000/page")

    assert observation.url == "http://127.0.0.1:4000/page"
    assert observation.status == 200
    assert_receive {:preview_browser, ^browser_id, {:load_started, "http://127.0.0.1:4000/page"}}

    assert_receive {:preview_browser, ^browser_id,
                    {:load_finished, "http://127.0.0.1:4000/page", 200}}

    assert {:ok, observed} = DevIDEPreviewBrowser.observe(browser)
    assert observed.url == "http://127.0.0.1:4000/page"
    assert observed.title == "127.0.0.1"
  end

  test "sends CDP commands through the backend" do
    {:ok, session} = DevIDEPreviewBrowser.start_link(event_owner: self())
    {:ok, browser} = DevIDEPreviewBrowser.open_browser(session, url: "http://example.test")

    assert {:ok, result} =
             DevIDEPreviewBrowser.cdp(browser, "Page.getNavigationHistory", %{})

    assert result["currentIndex"] == 0
    assert [%{"url" => "http://example.test"}] = result["entries"]
  end

  test "captures screenshots with explicit metadata" do
    {:ok, session} = DevIDEPreviewBrowser.start_link(event_owner: self())
    {:ok, browser} = DevIDEPreviewBrowser.open_browser(session, url: "http://example.test")

    assert {:ok, %Screenshot{} = screenshot} =
             DevIDEPreviewBrowser.screenshot(browser, format: :jpeg)

    assert screenshot.mime_type == "image/jpeg"
    assert screenshot.bytes =~ "http://example.test"
    assert screenshot.metadata == %{url: "http://example.test", backend: :fake}
  end

  test "closing a browser emits a close event and rejects future calls" do
    {:ok, session} = DevIDEPreviewBrowser.start_link(event_owner: self())
    {:ok, %Browser{id: browser_id} = browser} = DevIDEPreviewBrowser.open_browser(session)

    assert :ok = DevIDEPreviewBrowser.close(browser)
    assert_receive {:preview_browser, ^browser_id, :closed}
    assert {:error, :browser_not_found} = DevIDEPreviewBrowser.observe(browser)
  end

  test "backend-originated events are delivered to the configured owner" do
    {:ok, session} = DevIDEPreviewBrowser.start_link(event_owner: self())
    {:ok, %Browser{id: browser_id}} = DevIDEPreviewBrowser.open_browser(session)

    assert :ok = DevIDEPreviewBrowser.emit_event(session, browser_id, {:console, :info, "ready"})
    assert_receive {:preview_browser, ^browser_id, {:console, :info, "ready"}}

    assert :ok = DevIDEPreviewBrowser.emit_event(session, browser_id, {:crashed, :abnormal_exit})
    assert_receive {:preview_browser, ^browser_id, {:crashed, :abnormal_exit}}
  end

  test "sessions can be started under the dynamic supervisor" do
    {:ok, supervisor} = DevIDEPreviewBrowser.Supervisor.start_link()

    {:ok, session} =
      DevIDEPreviewBrowser.Supervisor.start_session(supervisor, event_owner: self())

    {:ok, %Browser{}} = DevIDEPreviewBrowser.open_browser(session)
  end

  test "external backend drives lifecycle through a JSON-line process" do
    {:ok, session} =
      DevIDEPreviewBrowser.start_link(
        backend: DevIDEPreviewBrowser.ExternalBackend,
        executable: python!(),
        args: [fixture_path("json_backend.py")],
        event_owner: self()
      )

    assert {:ok, %Browser{id: browser_id} = browser} =
             DevIDEPreviewBrowser.open_browser(session, url: "about:blank")

    assert {:ok, observation} =
             DevIDEPreviewBrowser.navigate(browser, "http://example.test/page")

    assert observation == %{
             backend: :external_process,
             status: 200,
             title: "example.test",
             url: "http://example.test/page"
           }

    assert_receive {:preview_browser, ^browser_id, {:load_started, "http://example.test/page"}}

    assert_receive {:preview_browser, ^browser_id,
                    {:console, :info, "navigated http://example.test/page"}}

    assert_receive {:preview_browser, ^browser_id,
                    {:load_finished, "http://example.test/page", 200}}

    assert {:ok, observed} = DevIDEPreviewBrowser.observe(browser)
    assert observed.url == "http://example.test/page"

    assert {:ok, result} =
             DevIDEPreviewBrowser.cdp(browser, "Runtime.evaluate", %{"expression" => "1 + 1"})

    assert result["method"] == "Runtime.evaluate"
    assert result["params"] == %{"expression" => "1 + 1"}
    assert result["url"] == "http://example.test/page"

    assert {:ok, %Screenshot{} = screenshot} = DevIDEPreviewBrowser.screenshot(browser)
    assert screenshot.mime_type == "image/png"
    assert screenshot.bytes == "external screenshot for http://example.test/page"
    assert screenshot.metadata == %{backend: :external_process, url: "http://example.test/page"}

    assert :ok = DevIDEPreviewBrowser.close(browser)
    assert_receive {:preview_browser, ^browser_id, :closed}
    assert {:error, :browser_not_found} = DevIDEPreviewBrowser.observe(browser)
  end

  test "external backend reports missing executable during startup" do
    assert {:error, :missing_executable} =
             DevIDEPreviewBrowser.ExternalBackend.start_runtime([])
  end

  test "external backend turns sidecar crash into an error and crash event" do
    {:ok, session} =
      DevIDEPreviewBrowser.start_link(
        backend: DevIDEPreviewBrowser.ExternalBackend,
        executable: python!(),
        args: [fixture_path("crashing_backend.py")],
        event_owner: self()
      )

    assert {:ok, %Browser{id: browser_id} = browser} = DevIDEPreviewBrowser.open_browser(session)

    assert {:error, {:port_exit, 7}} =
             DevIDEPreviewBrowser.navigate(browser, "http://example.test/crash")

    assert_receive {:preview_browser, ^browser_id, {:load_started, "http://example.test/crash"}}
    assert_receive {:preview_browser, ^browser_id, {:crashed, {:port_exit, 7}}}

    assert {:error, {:worker_exit, _reason}} = DevIDEPreviewBrowser.observe(browser)
  end

  test "external backend times out hung sidecar requests and cleans pending state" do
    {:ok, session} =
      DevIDEPreviewBrowser.start_link(
        backend: DevIDEPreviewBrowser.ExternalBackend,
        executable: python!(),
        args: [fixture_path("hanging_backend.py")],
        event_owner: self(),
        request_timeout: 25
      )

    assert {:ok, %Browser{id: browser_id} = browser} = DevIDEPreviewBrowser.open_browser(session)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :request_timeout} =
             DevIDEPreviewBrowser.navigate(browser, "http://example.test/slow")

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms < 500
    assert_receive {:preview_browser, ^browser_id, {:load_started, "http://example.test/slow"}}

    refute_receive {:preview_browser, ^browser_id,
                    {:load_finished, "http://example.test/slow", 200}},
                   75
  end

  @tag :playwright
  test "playwright sidecar drives a real browser runtime" do
    {:ok, session} =
      DevIDEPreviewBrowser.start_link(
        backend: DevIDEPreviewBrowser.ExternalBackend,
        executable: node!(),
        args: [sidecar_path("playwright_browser.mjs")],
        event_owner: self(),
        request_timeout: 5_000
      )

    assert {:ok, %Browser{id: browser_id} = browser} =
             DevIDEPreviewBrowser.open_browser(session, url: "about:blank")

    html =
      """
      <!doctype html>
      <title>Protocol Smoke</title>
      <script>
        (() => {
          const emit = (type, extra = {}) => {
            window.dispatchEvent(new CustomEvent("devide:preview:signal", {
              detail: {
                source: "devide-preview",
                version: 1,
                type,
                payload: {
                  url: window.location.href,
                  pathname: window.location.pathname,
                  timestamp: Date.now(),
                  request_id: "pv-smoke",
                  ...extra
                }
              }
            }))
          }

          emit("devide:preview:bridge_ready")
          document.addEventListener("DOMContentLoaded", () => {
            emit("devide:preview:dom_loaded")
            setTimeout(() => emit("devide:preview:live_socket_connected", {connected: true}), 0)
          })
        })()
        console.log("sidecar-ready")
      </script>
      <main id="root">ready</main>
      """

    url = "data:text/html;base64,#{Base.encode64(html)}"

    assert {:ok, observation} = DevIDEPreviewBrowser.navigate(browser, url)
    assert observation.backend == :external_process
    assert observation.title == "Protocol Smoke"
    assert observation.status == 200

    assert_receive {:preview_browser, ^browser_id, {:load_started, ^url}}
    assert_receive {:preview_browser, ^browser_id, {:console, :log, "sidecar-ready"}}
    assert_receive {:preview_browser, ^browser_id, {:load_finished, ^url, 200}}

    assert_receive {:preview_browser, ^browser_id,
                    {:preview_signal, "devide:preview:bridge_ready", bridge_payload,
                     %Health{} = bridge_health}}

    assert bridge_payload["request_id"] == "pv-smoke"
    assert bridge_health.bridge_ready

    assert_receive {:preview_browser, ^browser_id,
                    {:preview_signal, "devide:preview:dom_loaded", _dom_payload,
                     %Health{dom_loaded: true}}}

    assert_receive {:preview_browser, ^browser_id,
                    {:preview_signal, "devide:preview:live_socket_connected", _socket_payload,
                     %Health{state: :liveview_stable, live_socket_connected: true}}}

    assert {:ok, observed} = DevIDEPreviewBrowser.observe(browser)

    assert %Health{state: :liveview_stable, dom_loaded: true, live_socket_connected: true} =
             observed.health

    assert {:ok, cdp_result} =
             DevIDEPreviewBrowser.cdp(browser, "Runtime.evaluate", %{
               "expression" => "1 + 1",
               "returnByValue" => true
             })

    assert get_in(cdp_result, ["result", "value"]) == 2

    assert {:ok, %Screenshot{} = screenshot} = DevIDEPreviewBrowser.screenshot(browser)
    assert screenshot.mime_type == "image/png"
    assert <<137, 80, 78, 71, _rest::binary>> = screenshot.bytes
    assert screenshot.metadata.backend == :external_process

    assert :ok = DevIDEPreviewBrowser.close(browser)
    assert_receive {:preview_browser, ^browser_id, :closed}
  end

  @tag :playwright
  test "real preview_bridge.js signals LiveView health through the Playwright sidecar" do
    page_path = write_preview_bridge_contract_page!()
    on_exit(fn -> File.rm(page_path) end)

    {:ok, session} =
      DevIDEPreviewBrowser.start_link(
        backend: DevIDEPreviewBrowser.ExternalBackend,
        executable: node!(),
        args: [sidecar_path("playwright_browser.mjs")],
        event_owner: self(),
        request_timeout: 5_000
      )

    assert {:ok, %Browser{id: browser_id} = browser} =
             DevIDEPreviewBrowser.open_browser(session, url: "about:blank")

    url = "file://#{page_path}?devide_preview=1"

    assert {:ok, observation} = DevIDEPreviewBrowser.navigate(browser, url)
    assert observation.backend == :external_process
    assert observation.title == "Preview Bridge Contract"

    assert_receive {:preview_browser, ^browser_id, {:load_started, ^url}}

    assert_receive {:preview_browser, ^browser_id,
                    {:preview_signal, "devide:preview:bridge_ready", bridge_payload,
                     %Health{} = bridge_health}}

    assert bridge_payload["request_id"] =~ ~r/^pv-/
    assert bridge_payload["pathname"] == page_path
    assert bridge_health.bridge_ready

    assert_receive {:preview_browser, ^browser_id,
                    {:preview_signal, "devide:preview:live_socket_connected", _socket_payload,
                     %Health{live_socket_connected: true}}}

    assert_receive {:preview_browser, ^browser_id,
                    {:preview_signal, "devide:preview:dom_loaded", _dom_payload,
                     %Health{dom_loaded: true}}}

    assert_receive {:preview_browser, ^browser_id,
                    {:console, :log, "real-preview-bridge-installed"}}

    assert_receive {:preview_browser, ^browser_id, {:load_finished, ^url, 200}}

    assert {:ok, observed} = DevIDEPreviewBrowser.observe(browser)

    assert %Health{
             state: :liveview_stable,
             bridge_ready: true,
             dom_loaded: true,
             live_socket_connected: true
           } = observed.health

    assert :ok = DevIDEPreviewBrowser.close(browser)
    assert_receive {:preview_browser, ^browser_id, :closed}
  end

  defp python! do
    System.find_executable("python3") ||
      flunk("python3 is required for the external backend fixture")
  end

  defp node! do
    System.find_executable("node") ||
      flunk("node is required for the Playwright sidecar fixture")
  end

  defp fixture_path(name), do: Path.expand("fixtures/#{name}", __DIR__)

  defp sidecar_path(name) do
    __DIR__
    |> Path.join("../priv/sidecars/#{name}")
    |> Path.expand()
  end

  defp write_preview_bridge_contract_page! do
    path =
      System.tmp_dir!()
      |> Path.join("devide-preview-bridge-contract-#{System.unique_integer([:positive])}.html")

    File.write!(path, preview_bridge_contract_html())
    path
  end

  defp preview_bridge_contract_html do
    """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <title>Preview Bridge Contract</title>
      </head>
      <body class="phx-connected">
        <main id="root">LiveView connected</main>
        <script type="module">
    #{preview_bridge_asset_source!()}

    window.__installPreviewBridge({
      liveSocket: {
        socket: {
          isConnected: () => true
        }
      }
    })

    console.log("real-preview-bridge-installed")
        </script>
      </body>
    </html>
    """
  end

  defp preview_bridge_asset_source! do
    __DIR__
    |> Path.join("../../assets/js/preview_bridge.js")
    |> Path.expand()
    |> File.read!()
    |> String.replace(
      "export function installPreviewBridge",
      "window.__installPreviewBridge = function installPreviewBridge"
    )
    |> String.replace("process.env.NODE_ENV", ~s("development"))
  end
end
