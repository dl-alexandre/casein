defmodule DevIDE.Integrations.Manager.ClientBaseUrlTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Integrations.Manager.Client

  describe "base_url/0" do
    setup do
      prev_manager = Application.get_env(:dev_ide, :manager_url)
      on_exit(fn -> restore(:manager_url, prev_manager) end)
      :ok
    end

    test "returns the configured :manager_url" do
      Application.put_env(:dev_ide, :manager_url, "http://manager.test:4242")
      assert Client.base_url() == "http://manager.test:4242"
    end

    test "falls back to the default localhost URL when unconfigured and no env" do
      Application.delete_env(:dev_ide, :manager_url)
      prev = System.get_env("MILC_DEVBOX_MANAGER_URL")
      System.delete_env("MILC_DEVBOX_MANAGER_URL")

      try do
        assert Client.base_url() == "http://localhost:9000"
      after
        if prev, do: System.put_env("MILC_DEVBOX_MANAGER_URL", prev)
      end
    end

    test "prefers the MILC_DEVBOX_MANAGER_URL env over the default" do
      Application.delete_env(:dev_ide, :manager_url)
      prev = System.get_env("MILC_DEVBOX_MANAGER_URL")
      System.put_env("MILC_DEVBOX_MANAGER_URL", "http://example.test:1234")

      try do
        assert Client.base_url() == "http://example.test:1234"
      after
        if prev,
          do: System.put_env("MILC_DEVBOX_MANAGER_URL", prev),
          else: System.delete_env("MILC_DEVBOX_MANAGER_URL")
      end
    end
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
