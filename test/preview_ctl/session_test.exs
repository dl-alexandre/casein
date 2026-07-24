defmodule PreviewCtl.SessionTest do
  use Casein.TestCase, async: false

  alias PreviewCtl.{Registry, Session, Test.FakeAdapter}

  setup do
    _ = Registry.clear()
    :ok
  end

  test "observe returns simulated DOM summary via fake adapter" do
    entry = put_runtime!("https://alice.devbox.example.com")

    assert {:ok, ^entry, observation} = Session.observe(entry.session.id)
    assert observation.url == "https://alice.devbox.example.com"
    assert is_list(observation.dom_summary.selectors)
  end

  test "navigate rejects disallowed cross-origin URLs" do
    entry = put_runtime!("https://alice.devbox.example.com")

    assert {:error, :origin_not_allowed} =
             Session.navigate(entry.session.id, "https://evil.example.com")

    assert {:ok, _, observation} = Session.navigate(entry.session.id, "/settings")
    assert observation.url == "https://alice.devbox.example.com:443/settings"
  end

  test "history controls move through runtime navigation stack" do
    entry = put_runtime!("https://alice.devbox.example.com")

    assert {:ok, _, %{url: "https://alice.devbox.example.com:443/one"}} =
             Session.navigate(entry.session.id, "/one")

    assert {:ok, _, %{url: "https://alice.devbox.example.com:443/two"}} =
             Session.navigate(entry.session.id, "/two")

    assert {:ok, _, %{url: "https://alice.devbox.example.com:443/one"}} =
             Session.go_back(entry.session.id)

    assert {:ok, _, %{url: "https://alice.devbox.example.com:443/two"}} =
             Session.go_forward(entry.session.id)

    assert {:ok, _, %{url: "https://alice.devbox.example.com:443/two"}} =
             Session.reload(entry.session.id)
  end

  test "close removes runtime registry entry" do
    entry = put_runtime!("https://alice.devbox.example.com")
    assert {:ok, _} = Session.close(entry.session.id)
    assert Registry.get(entry.session.id) == nil
  end

  test "click threads an explicit nth into the adapter command target" do
    entry = put_runtime!("https://alice.devbox.example.com")
    selector = "button[type=submit]"

    assert {:ok, _, _} = Session.click(entry.session.id, %{selector: selector, nth: 2})

    target = Registry.get(entry.session.id).adapter_state.dom.last_click_target
    assert target.selector == selector
    assert target.nth == 2
  end

  test "selector-only click produces a valid command with no nth" do
    entry = put_runtime!("https://alice.devbox.example.com")
    selector = "button[type=submit]"

    assert {:ok, _, _} = Session.click(entry.session.id, %{selector: selector})

    target = Registry.get(entry.session.id).adapter_state.dom.last_click_target
    assert target.selector == selector
    refute Map.has_key?(target, :nth)
  end

  test "type threads an explicit nth into the adapter opts" do
    entry = put_runtime!("https://alice.devbox.example.com")
    selector = "button[type=submit]"

    assert {:ok, _, _} = Session.type(entry.session.id, selector, "hello", %{nth: 1})

    last_type = Registry.get(entry.session.id).adapter_state.dom.last_type
    assert last_type.selector == selector
    assert last_type.text == "hello"
    assert last_type.opts == %{nth: 1}
  end

  test "click that navigates off-allowlist origin is refused without updating session" do
    base = "https://alice.devbox.example.com"
    entry = put_runtime!(base)
    off_origin_link = ~s(a[href="https://example.com/news"])

    assert {:error, {:origin_not_allowed, _observation}} =
             Session.click(entry.session.id, %{selector: off_origin_link})

    updated = Registry.get(entry.session.id)
    assert updated.adapter_state.current_url == base
    refute updated.adapter_state.current_url == "https://example.com/news"
  end

  test "click that navigates within allowlist still succeeds" do
    base = "https://alice.devbox.example.com"
    entry = put_runtime!(base)
    same_origin_link = ~s(a[href="/settings"])

    assert {:ok, _, observation} =
             Session.click(entry.session.id, %{selector: same_origin_link})

    assert observation.url == "https://alice.devbox.example.com:443/settings"
    assert Registry.get(entry.session.id).current_url == observation.url
  end

  test "screenshot is refused when the adapter has drifted off the allowlist" do
    entry = put_runtime!("https://alice.devbox.example.com")

    # Defense-in-depth: the interaction gate refuses to *commit* an off-origin
    # url, but the underlying browser can still end up off-allowlist via a path
    # the gate didn't mediate (JS/meta redirect). A screenshot must not capture
    # that page.
    off = %{
      entry
      | adapter_state: %{entry.adapter_state | current_url: "https://evil.example.com/x"}
    }

    :ok = Registry.put(entry.session.id, off)

    assert {:error, :origin_not_allowed} = Session.screenshot(entry.session.id)
  end

  defp put_runtime!(url) do
    session = %{id: System.unique_integer([:positive]), current_url: url}
    preview = %{url: url}

    {:ok, adapter_state} = FakeAdapter.start_session(%{current_url: url})

    entry = %{
      session: session,
      preview: preview,
      adapter_state: adapter_state,
      adapter_module: FakeAdapter,
      allowed_origins: [url]
    }

    :ok = Registry.put(session.id, entry)
    entry
  end
end
