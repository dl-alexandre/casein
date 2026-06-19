defmodule DevIDE.Agents.TidewaveCapabilityTest do
  use ExUnit.Case, async: true

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
    if Code.ensure_loaded?(Tidewave) do
      Application.put_env(:dev_ide, :preview_loopback_port, 4000)

      cap = TidewaveCapability.detect()
      assert cap.status == :detected
      assert cap.source == :dev_ide
      assert cap.url =~ "/tidewave"
      assert cap.details.mcp_url =~ "/tidewave/mcp"
      refute cap.details.preview_env
    end
  end

  @tag :tidewave_available
  test "detect tags preview_env source on ephemeral loopback port" do
    if Code.ensure_loaded?(Tidewave) do
      Application.put_env(:dev_ide, :preview_loopback_port, 41_042)

      cap = TidewaveCapability.detect()
      assert cap.status == :detected
      assert cap.source == :preview_env
      assert cap.details.preview_env
      assert cap.details.port == 41_042
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
