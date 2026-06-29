defmodule DevIDE.Agents.TidewaveCapabilityTest do
  # Serial: mutates process-global Application env (:preview_loopback_port),
  # which other suites read concurrently.
  use ExUnit.Case, async: false

  alias DevIDE.Agents.TidewaveCapability

  setup do
    prev_loopback = Application.get_env(:dev_ide, :preview_loopback_port)
    prev_provider = Application.get_env(:dev_ide, :tidewave_url_provider)

    on_exit(fn ->
      restore_env(:preview_loopback_port, prev_loopback)
      restore_env(:tidewave_url_provider, prev_provider)
    end)

    :ok
  end

  test "detect returns missing when Tidewave is not compiled in" do
    unless Code.ensure_loaded?(Tidewave) do
      cap = TidewaveCapability.detect()
      assert cap.status == :missing
      assert cap.kind == :tidewave
    end
  end

  @tag :tidewave_available
  test "detect advertises MCP URL when Tidewave is available" do
    Application.put_env(:dev_ide, :preview_loopback_port, 4000)

    cap = TidewaveCapability.detect()
    assert cap.status == :detected
    assert cap.source == :dev_ide
    assert cap.url =~ "/tidewave"
    assert cap.details.mcp_url =~ "/tidewave/mcp"
    refute cap.details.preview_env
  end

  @tag :tidewave_available
  test "detect tags preview_env source on ephemeral loopback port" do
    Application.put_env(:dev_ide, :preview_loopback_port, 41_042)

    cap = TidewaveCapability.detect()
    assert cap.status == :detected
    assert cap.source == :preview_env
    assert cap.details.preview_env
    assert cap.details.port == 41_042
  end

  test "detect returns missing when no URL provider is configured" do
    Application.delete_env(:dev_ide, :tidewave_url_provider)

    cap = TidewaveCapability.detect()
    assert cap.status == :missing
    assert cap.kind == :tidewave
  end

  test "detect returns missing when provider module is unavailable" do
    Application.put_env(
      :dev_ide,
      :tidewave_url_provider,
      {NonExistent.TidewaveProvider, :url, []}
    )

    cap = TidewaveCapability.detect()
    assert cap.status == :missing
  end

  @tag :tidewave_available
  test "detect uses configured provider MFA when Tidewave is available" do
    Application.put_env(:dev_ide, :tidewave_url_provider, {__MODULE__.FakeProvider, :url, []})
    Application.put_env(:dev_ide, :preview_loopback_port, 4000)

    cap = TidewaveCapability.detect()
    assert cap.status == :detected
    assert cap.source == :dev_ide
    assert cap.url == "http://fake.local/tidewave"
    assert cap.details.mcp_url == "http://fake.local/tidewave/mcp"
  end

  defmodule FakeProvider do
    def url, do: "http://fake.local"
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
