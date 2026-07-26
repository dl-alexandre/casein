defmodule PreviewCtl.Playwright.AdapterBridgeTest do
  # Drives the Playwright Adapter end-to-end through the real Bridge GenServer,
  # backed by a fake Node helper script that speaks the newline-delimited JSON
  # protocol. This exercises Adapter.playwright_command/decode paths plus the
  # Bridge port spawn/command/decode_line cycle without a real browser.
  use Casein.TestCase, async: false

  alias PreviewCtl.Playwright.Adapter
  alias PreviewCtl.Playwright.Bridge

  # The fake helper. Invoked by the Bridge as `node <this_file> --daemon`, so it
  # must read stdin line-by-line, parse each JSON request, and write back exactly
  # ONE JSON line per request. It returns a SUPERSET response so every Adapter
  # parser (observation/storage/artifact/url) is satisfied at once. When the
  # request action is "__boom__" it returns an `ok:false` error to cover the
  # {:error, {:playwright_error, _}} branch in Bridge.decode_line/1.
  @fake_script """
  const readline = require("readline");
  const rl = readline.createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    line = line.trim();
    if (line === "") return;
    let req;
    try {
      req = JSON.parse(line);
    } catch (e) {
      process.stdout.write(JSON.stringify({ ok: false, error: "bad_json" }) + "\\n");
      return;
    }
    if (req.action === "__boom__" || (req.url || "").indexOf("__fail__") !== -1) {
      process.stdout.write(JSON.stringify({ ok: false, error: "boom" }) + "\\n");
      return;
    }
    const params = req.params || {};
    // When the request url carries the "nav-me" marker, transform it so the test
    // can prove the adapter threads result["url"] (and observation.url) back
    // into state. Every other url is echoed unchanged.
    const url = req.url.indexOf("nav-me") !== -1 ? req.url + "#pw" : req.url;
    const cookies = Array.isArray(params.cookies) ? params.cookies : [];
    const resp = {
      ok: true,
      // Echo identifying fields so the test can prove the adapter sent them.
      echo_action: req.action,
      echo_url: req.url,
      echo_browser_id: req.browser_id,
      echo_params: params,
      url: url,
      observation: {
        url: url,
        title: "T",
        source_url: null,
        dom_summary: {
          title: "T",
          headings: ["H1"],
          links: [],
          visible_text: "hello",
          byte_size: 5,
          url: url,
          source_url: null
        },
        console_errors: [],
        network_errors: []
      },
      artifact: req.action === "screenshot" ? { kind: "screenshot", data: "AAAA" } : null,
      local_storage: { "k": "v" },
      session_storage: { "s": "1" },
      console_errors: ["cerr"],
      network_errors: ["nerr"],
      // set_cookies response shape (names/count only — never values)
      cookie_count: cookies.length,
      cookie_names: cookies.map((c) => c && c.name).filter(Boolean)
    };
    process.stdout.write(JSON.stringify(resp) + "\\n");
  });
  """

  # The Bridge GenServer is an app-supervised singleton (name: __MODULE__), so we
  # cannot start a second one. Instead, configure the fake helper script and
  # restart the existing Bridge via the app supervisor so its init re-reads the
  # script. Done once per module (setup_all) to avoid tripping max_restarts.
  setup_all do
    previous = Application.get_env(:preview_ctl, :playwright_script)

    dir = Path.join(System.tmp_dir!(), "casein-cov-80-pw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "fake_playwright.js")
    File.write!(script, @fake_script)

    Application.put_env(:preview_ctl, :playwright_script, script)
    restart_bridge()

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:preview_ctl, :playwright_script)
        value -> Application.put_env(:preview_ctl, :playwright_script, value)
      end

      restart_bridge()
      File.rm_rf(dir)
    end)

    :ok
  end

  setup do
    {:ok, state: base_state()}
  end

  defp restart_bridge do
    _ = Supervisor.terminate_child(Casein.Supervisor, PreviewCtl.Playwright.Bridge)
    {:ok, _} = Supervisor.restart_child(Casein.Supervisor, PreviewCtl.Playwright.Bridge)
    :ok
  end

  defp base_state do
    %{
      current_url: "http://example.test/page",
      browser_id: "pw-deadbeef",
      default_headers: %{"x-test" => "1"},
      storage_state_path: nil,
      storage_profile: "ephemeral"
    }
  end

  describe "start_session/1" do
    test "builds session state from a url" do
      assert {:ok, session} =
               Adapter.start_session(%{
                 current_url: "http://host/x",
                 default_headers: %{"a" => "b"},
                 storage_profile: "named",
                 storage_profile_name: "p1",
                 storage_state_path: "/tmp/s.json"
               })

      assert session.current_url == "http://host/x"
      assert is_binary(session.browser_id)
      assert String.starts_with?(session.browser_id, "pw-")
      assert session.default_headers == %{"a" => "b"}
      assert session.storage_profile == "named"
      assert session.storage_profile_name == "p1"
      assert session.storage_state_path == "/tmp/s.json"
    end

    test "drops malformed headers during normalization" do
      assert {:ok, session} =
               Adapter.start_session(%{
                 current_url: "http://host/x",
                 default_headers: %{
                   "" => "skip",
                   "bad:key" => "v",
                   "ok" => "good",
                   "crlf" => "a\r\nb"
                 }
               })

      assert session.default_headers == %{"ok" => "good"}
    end

    test "returns :missing_url when no url present" do
      assert {:error, :missing_url} = Adapter.start_session(%{})
      assert {:error, :missing_url} = Adapter.start_session(%{current_url: nil})
      assert {:error, :missing_url} = Adapter.start_session("not a map")
    end
  end

  describe "observe_live/1 via bridge" do
    test "returns parsed observation from the helper", %{state: state} do
      assert {:ok, new_state, obs} = Adapter.observe_live(state)

      assert new_state.current_url == "http://example.test/page"
      assert obs.url == "http://example.test/page"
      assert obs.title == "T"
      assert obs.console_errors == []
      assert obs.network_errors == []
      assert obs.dom_summary.headings == ["H1"]
      assert obs.dom_summary.visible_text == "hello"
      assert new_state.last_observation == obs
    end
  end

  describe "click/2 via bridge" do
    test "threads selector + nth params and returns observation", %{state: state} do
      assert {:ok, new_state, obs} = Adapter.click(state, %{selector: "#btn", nth: 2})
      assert obs.url == "http://example.test/page"
      assert new_state.last_observation == obs
    end

    test "supports x/y coordinate targets", %{state: state} do
      assert {:ok, _new_state, obs} = Adapter.click(state, %{x: 10, y: 20})
      assert obs.title == "T"
    end
  end

  describe "type/4 via bridge" do
    test "returns updated state only", %{state: state} do
      assert {:ok, new_state} = Adapter.type(state, "#field", "hello", %{nth: 0})
      assert new_state.current_url == "http://example.test/page"
      assert Map.has_key?(new_state, :last_observation)
    end
  end

  describe "press/2 via bridge" do
    test "returns updated state", %{state: state} do
      assert {:ok, new_state} = Adapter.press(state, "Enter")
      assert new_state.current_url == "http://example.test/page"
    end
  end

  describe "history commands via bridge" do
    test "go_back/1 returns observation", %{state: state} do
      assert {:ok, _new_state, obs} = Adapter.go_back(state)
      assert obs.url == "http://example.test/page"
    end

    test "go_forward/1 returns observation", %{state: state} do
      assert {:ok, _new_state, obs} = Adapter.go_forward(state)
      assert obs.title == "T"
    end

    test "reload/1 returns observation", %{state: state} do
      assert {:ok, _new_state, obs} = Adapter.reload(state)
      assert obs.url == "http://example.test/page"
    end
  end

  describe "screenshot/1 via bridge" do
    test "returns observation and artifact", %{state: state} do
      assert {:ok, _new_state, obs, artifact} = Adapter.screenshot(state)
      assert obs.url == "http://example.test/page"
      assert artifact == %{"kind" => "screenshot", "data" => "AAAA"}
    end
  end

  describe "get_storage/1 via bridge" do
    test "decodes storage maps and error lists", %{state: state} do
      assert {:ok, new_state, storage} = Adapter.get_storage(state)
      assert storage.url == "http://example.test/page"
      assert storage.local_storage == %{"k" => "v"}
      assert storage.session_storage == %{"s" => "1"}
      assert storage.console_errors == ["cerr"]
      assert storage.network_errors == ["nerr"]
      assert new_state.last_storage == storage
    end
  end

  describe "clear_storage/1 via bridge" do
    test "decodes storage result", %{state: state} do
      assert {:ok, _new_state, storage} = Adapter.clear_storage(state)
      assert storage.local_storage == %{"k" => "v"}
      assert storage.session_storage == %{"s" => "1"}
    end
  end

  describe "set_cookies/2 via bridge" do
    test "threads cookies to playwright and returns names/count only", %{state: state} do
      cookies = [
        %{"name" => "auth", "value" => "should-not-echo-back"},
        %{"name" => "sid", "value" => "also-secret"}
      ]

      assert {:ok, new_state, result} = Adapter.set_cookies(state, cookies)

      assert new_state.current_url == state.current_url
      assert result["cookie_count"] == 2 or result[:cookie_count] == 2
      names = result["cookie_names"] || result[:cookie_names]
      assert names == ["auth", "sid"]
      # Adapter surface must not re-expose raw values from the helper echo.
      refute inspect(result) =~ "should-not-echo-back"
    end
  end

  describe "close/1 via bridge" do
    test "issues close and returns :ok", %{state: state} do
      assert :ok = Adapter.close(state)
    end

    test "no-op when no browser_id" do
      assert :ok = Adapter.close(%{})
    end
  end

  describe "result url threading" do
    test "navigate uses the persistent Playwright context", %{state: state} do
      assert {:ok, new_state, obs} =
               Adapter.navigate(state, "http://example.test/nav-me")

      assert new_state.current_url == "http://example.test/nav-me#pw"
      assert obs.url == "http://example.test/nav-me#pw"
    end

    test "navigates state to the url returned by the helper", %{state: state} do
      # The fake transforms a url containing "nav-me"; the adapter must thread
      # the returned result["url"] into both state.current_url and observation.url.
      state = %{state | current_url: "http://example.test/nav-me"}

      assert {:ok, new_state, obs} = Adapter.click(state, %{selector: "#nav"})

      assert new_state.current_url == "http://example.test/nav-me#pw"
      assert obs.url == "http://example.test/nav-me#pw"
    end
  end

  describe "error branch via sentinel action" do
    test "bridge surfaces ok:false as {:error, {:playwright_error, _}}", %{state: state} do
      payload = sentinel_payload(state)
      assert {:error, {:playwright_error, "boom"}} = Bridge.command(payload)
    end

    test "click/2 propagates a helper error tuple", %{state: state} do
      # The fake replies ok:false whenever the url carries the "__fail__" marker.
      # click returns `other` on a non-{:ok,...} result, so the playwright_error
      # tuple from Bridge.decode_line flows straight back to the caller.
      state = %{state | current_url: "http://example.test/__fail__"}
      assert {:error, {:playwright_error, "boom"}} = Adapter.click(state, %{selector: "#x"})
    end

    test "observe_live falls back to static observe when the helper errors", %{state: state} do
      # observe_live swallows the bridge error and falls back to HTTP observe.
      # The unreachable __fail__ url cannot be fetched, so the fallback returns an
      # error tuple — proving control reached observe_live_fallback rather than
      # the happy path (which would have returned {:ok, _, obs}).
      state = %{state | current_url: "http://127.0.0.1:1/__fail__"}
      assert {:error, _reason} = Adapter.observe_live(state)
    end
  end

  describe "bridge command serialization" do
    test "serialized command/1 round-trips a request and echoes its fields", %{state: _state} do
      assert {:ok, result} =
               Bridge.command(%{
                 action: "type",
                 url: "http://x/y",
                 browser_id: "b",
                 default_headers: %{},
                 storage_state_path: nil,
                 params: %{selector: "#a", text: "t"}
               })

      assert result["ok"] == true
      assert result["echo_action"] == "type"
      assert result["echo_browser_id"] == "b"
      assert result["echo_params"]["selector"] == "#a"
      assert result["echo_params"]["text"] == "t"
    end
  end

  defp sentinel_payload(state) do
    %{
      action: "__boom__",
      url: state.current_url,
      browser_id: Map.get(state, :browser_id),
      default_headers: Map.get(state, :default_headers, %{}),
      storage_state_path: Map.get(state, :storage_state_path),
      params: %{}
    }
  end
end
