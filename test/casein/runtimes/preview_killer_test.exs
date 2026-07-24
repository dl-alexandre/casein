defmodule Casein.Runtimes.PreviewKillerTest do
  @moduledoc """
  Unit tests for `Casein.Runtimes.PreviewKiller`.

  The public `kill/1` seam routes through `Application.get_env(:casein,
  :runtime_preview_killer, Default)`. Tests swap a Behaviour impl for
  delegation, and exercise `Default` only with nil/absent pids and a closed
  loopback port — never `System.cmd("kill", ...)` against a real process.
  """

  use Casein.TestCase, async: false

  alias Casein.Runtimes.PreviewKiller

  defmodule FakeKiller do
    @moduledoc false
    @behaviour Casein.Runtimes.PreviewKiller.Behaviour

    @impl true
    def kill(server) when is_map(server) do
      send(self(), {:fake_preview_kill, server})
      {:error, :fake_preview_killer}
    end
  end

  setup do
    previous = Application.get_env(:casein, :runtime_preview_killer)

    on_exit(fn ->
      restore_env(previous)
    end)

    :ok
  end

  describe "kill/1 public API" do
    test "non-map server is a no-op :ok" do
      assert PreviewKiller.kill(nil) == :ok
      assert PreviewKiller.kill(:not_a_map) == :ok
      assert PreviewKiller.kill("string") == :ok
      assert PreviewKiller.kill(123) == :ok
      assert PreviewKiller.kill([]) == :ok
    end

    test "delegates to the configured Behaviour impl via :runtime_preview_killer" do
      Application.put_env(:casein, :runtime_preview_killer, FakeKiller)

      server = %{"runtime_id" => "rt-fake", "port" => 9999}
      assert PreviewKiller.kill(server) == {:error, :fake_preview_killer}
      assert_received {:fake_preview_kill, ^server}
    end

    test "defaults to Default when env is unset" do
      Application.delete_env(:casein, :runtime_preview_killer)

      # Closed port + no registry path material — pure :ok, no process touch.
      assert PreviewKiller.kill(%{"port" => free_closed_port()}) == :ok
    end
  end

  describe "Default.kill/1 registry + port branches" do
    setup do
      Application.put_env(:casein, :runtime_preview_killer, PreviewKiller.Default)
      :ok
    end

    test "removes registry file when pid is absent and port is unreachable" do
      {preview_home, runtime_id, registry} = tmp_registry!(%{})

      server = %{
        "runtime_id" => runtime_id,
        "port" => free_closed_port(),
        "env" => %{"DEVIDE_PREVIEW_HOME" => preview_home}
      }

      assert File.exists?(registry)
      assert PreviewKiller.kill(server) == :ok
      refute File.exists?(registry)
    end

    test "removes registry file when pid is explicitly nil (never kills a real pid)" do
      {preview_home, runtime_id, registry} = tmp_registry!(%{"pid" => nil, "proxy_pid" => nil})

      server = %{
        "runtime_id" => runtime_id,
        "port" => free_closed_port(),
        "env" => %{"DEVIDE_PREVIEW_HOME" => preview_home}
      }

      assert PreviewKiller.kill(server) == :ok
      refute File.exists?(registry)
    end

    test "accepts atom DEVIDE_PREVIEW_HOME env key and still drops the registry" do
      {preview_home, runtime_id, registry} = tmp_registry!(%{"pid" => ""})

      server = %{
        "runtime_id" => runtime_id,
        "port" => free_closed_port(),
        "env" => %{DEVIDE_PREVIEW_HOME: preview_home}
      }

      assert PreviewKiller.kill(server) == :ok
      refute File.exists?(registry)
    end

    test "derives preview home from cwd when env is absent" do
      cwd = Path.join(System.tmp_dir!(), "pk-cwd-#{System.unique_integer([:positive])}")
      runtime_id = "rt-cwd-#{System.unique_integer([:positive])}"
      preview_home = Path.join(cwd, ".devide-preview")
      instances = Path.join(preview_home, "instances")
      File.mkdir_p!(instances)
      registry = Path.join(instances, "#{runtime_id}.json")
      File.write!(registry, Jason.encode!(%{"pid" => nil}))
      on_exit(fn -> File.rm_rf(cwd) end)

      server = %{
        "runtime_id" => runtime_id,
        "cwd" => cwd,
        "port" => free_closed_port()
      }

      assert PreviewKiller.kill(server) == :ok
      refute File.exists?(registry)
    end

    test "missing registry file (enoent) is still :ok" do
      preview_home =
        Path.join(System.tmp_dir!(), "pk-enoent-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(preview_home, "instances"))
      on_exit(fn -> File.rm_rf(preview_home) end)

      server = %{
        "runtime_id" => "rt-missing-#{System.unique_integer([:positive])}",
        "port" => free_closed_port(),
        "env" => %{"DEVIDE_PREVIEW_HOME" => preview_home}
      }

      assert PreviewKiller.kill(server) == :ok
    end

    test "invalid runtime_id skips registry teardown (file left in place)" do
      {preview_home, _valid_id, registry} = tmp_registry!(%{"pid" => nil})

      # Fails ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,255}\z/
      server = %{
        "runtime_id" => "../evil",
        "port" => free_closed_port(),
        "env" => %{"DEVIDE_PREVIEW_HOME" => preview_home}
      }

      assert PreviewKiller.kill(server) == :ok
      assert File.exists?(registry)

      assert PreviewKiller.kill(%{
               "runtime_id" => "has space",
               "port" => free_closed_port(),
               "env" => %{"DEVIDE_PREVIEW_HOME" => preview_home}
             }) == :ok

      assert File.exists?(registry)
    end

    test "nil runtime_id skips registry teardown" do
      {preview_home, _id, registry} = tmp_registry!(%{"pid" => nil})

      server = %{
        "runtime_id" => nil,
        "port" => free_closed_port(),
        "env" => %{"DEVIDE_PREVIEW_HOME" => preview_home}
      }

      assert PreviewKiller.kill(server) == :ok
      assert File.exists?(registry)
    end

    test "nil port is a no-op after registry handling" do
      {preview_home, runtime_id, registry} = tmp_registry!(%{"pid" => nil})

      server = %{
        "runtime_id" => runtime_id,
        "port" => nil,
        "env" => %{"DEVIDE_PREVIEW_HOME" => preview_home}
      }

      assert PreviewKiller.kill(server) == :ok
      refute File.exists?(registry)
    end

    test "missing port key is a no-op for the port branch" do
      {preview_home, runtime_id, registry} = tmp_registry!(%{})

      server = %{
        "runtime_id" => runtime_id,
        "env" => %{"DEVIDE_PREVIEW_HOME" => preview_home}
      }

      assert PreviewKiller.kill(server) == :ok
      refute File.exists?(registry)
    end

    test "out-of-range port skips fuser and returns :ok" do
      {preview_home, runtime_id, registry} = tmp_registry!(%{"pid" => nil})

      for port <- [0, -1, 65_536, 99_999, "not-an-int"] do
        # Re-write registry each iteration after prior kill may have removed it.
        File.mkdir_p!(Path.dirname(registry))
        File.write!(registry, Jason.encode!(%{"pid" => nil}))

        server = %{
          "runtime_id" => runtime_id,
          "port" => port,
          "env" => %{"DEVIDE_PREVIEW_HOME" => preview_home}
        }

        assert PreviewKiller.kill(server) == :ok
        refute File.exists?(registry)
      end
    end
  end

  defp free_closed_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(sock)
    :ok = :gen_tcp.close(sock)
    port
  end

  defp tmp_registry!(json_map) when is_map(json_map) do
    preview_home =
      Path.join(System.tmp_dir!(), "pk-home-#{System.unique_integer([:positive])}")

    runtime_id = "rt-pk-#{System.unique_integer([:positive])}"
    instances = Path.join(preview_home, "instances")
    File.mkdir_p!(instances)
    registry = Path.join(instances, "#{runtime_id}.json")
    File.write!(registry, Jason.encode!(json_map))
    on_exit(fn -> File.rm_rf(preview_home) end)
    {preview_home, runtime_id, registry}
  end

  defp restore_env(nil), do: Application.delete_env(:casein, :runtime_preview_killer)
  defp restore_env(val), do: Application.put_env(:casein, :runtime_preview_killer, val)
end
