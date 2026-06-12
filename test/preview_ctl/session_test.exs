defmodule PreviewCtl.SessionTest do
  use ExUnit.Case, async: false

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

  test "navigate rejects cross-origin URLs" do
    entry = put_runtime!("https://alice.devbox.example.com")

    assert {:error, :origin_not_allowed} =
             Session.navigate(entry.session.id, "https://evil.example.com")

    assert {:ok, _, observation} = Session.navigate(entry.session.id, "/settings")
    assert observation.url == "https://alice.devbox.example.com:443/settings"
  end

  test "close removes runtime registry entry" do
    entry = put_runtime!("https://alice.devbox.example.com")
    assert {:ok, _} = Session.close(entry.session.id)
    assert Registry.get(entry.session.id) == nil
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
