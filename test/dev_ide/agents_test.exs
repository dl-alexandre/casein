defmodule Casein.AgentsTest do
  use Casein.TestCase, async: false

  alias Casein.Agents

  defmodule FakeAdapter do
    @behaviour Casein.Agents

    @impl true
    def detect(root, ws), do: [{:detected, root, ws}]

    @impl true
    def transcripts(root), do: [{:transcript, root}]

    @impl true
    def review_commands(caps), do: [{:review, caps}]
  end

  setup do
    prev = Application.get_env(:dev_ide, :agents_adapter)
    Application.put_env(:dev_ide, :agents_adapter, FakeAdapter)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:dev_ide, :agents_adapter)
        value -> Application.put_env(:dev_ide, :agents_adapter, value)
      end
    end)

    :ok
  end

  test "detect/2 delegates to the configured adapter (default ws nil)" do
    assert Agents.detect("/repo") == [{:detected, "/repo", nil}]
    assert Agents.detect("/repo", %{id: "ws-1"}) == [{:detected, "/repo", %{id: "ws-1"}}]
  end

  test "transcripts/1 delegates to the configured adapter" do
    assert Agents.transcripts("/repo") == [{:transcript, "/repo"}]
  end

  test "review_commands/1 delegates to the configured adapter" do
    caps = [:cap_a, :cap_b]
    assert Agents.review_commands(caps) == [{:review, caps}]
  end
end
