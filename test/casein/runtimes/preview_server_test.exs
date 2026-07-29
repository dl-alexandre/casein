defmodule Casein.Runtimes.PreviewServerTest do
  use Casein.TestCase, async: true

  alias Casein.Runtimes.PreviewServer
  alias Casein.Workspaces.State.WorkspaceRecord

  # These tests exercise PreviewServer derivation/construction. Port selection
  # briefly probes loopback availability even for explicit ports; no listener is
  # retained. default_launcher_path/0 is made deterministic where needed with
  # CASEIN_RUNTIME_PREVIEW_LAUNCHER.

  defp record(attrs \\ %{}) do
    %WorkspaceRecord{
      external_id: Map.get(attrs, :external_id, "ws-ext-1"),
      name: "ws",
      host_path: Map.get(attrs, :host_path, "/srv/host")
    }
  end

  describe "build_for_worktree/6 — invalid inputs" do
    test "non-WorkspaceRecord record returns error" do
      assert PreviewServer.build_for_worktree(%{}, "rt", "tmux", "/wt", %{}, []) ==
               {:error, :invalid_runtime_preview_server}
    end

    test "non-binary runtime_id returns error" do
      assert PreviewServer.build_for_worktree(record(), :rt, "tmux", "/wt", %{}, []) ==
               {:error, :invalid_runtime_preview_server}
    end

    test "non-map attrs returns error" do
      assert PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", nil, []) ==
               {:error, :invalid_runtime_preview_server}
    end
  end

  describe "build_for_worktree/6 — top-level fields and surfaces" do
    test "derives ids, surfaces, url and source from an explicit port" do
      {:ok, server} =
        PreviewServer.build_for_worktree(
          record(%{external_id: "ws-9"}),
          "rt-7",
          "tmux-3",
          "/wt/path",
          %{"preview_port" => 4321},
          []
        )

      assert server["id"] == "preview:rt-7:app"
      assert server["runtime_id"] == "rt-7"
      assert server["workspace_id"] == "ws-9"
      assert server["tmux_session_id"] == "tmux-3"
      assert server["port"] == 4321
      assert server["surface_key"] == "runtime:rt-7:app"
      assert server["surface_name"] == "app"
      assert server["url"] == "http://localhost:4321"
      assert server["source"] == "runtime_preview_server"
      assert server["cwd"] == Path.expand("/wt/path")
      assert server["worktree_path"] == Path.expand("/wt/path")
    end
  end

  describe "build_for_worktree/6 — port derivation precedence" do
    test "preview_port wins over everything" do
      {:ok, server} =
        PreviewServer.build_for_worktree(
          record(),
          "rt",
          "tmux",
          "/wt",
          %{"preview_port" => 5000},
          []
        )

      assert server["port"] == 5000
    end

    test "string preview_port is parsed" do
      {:ok, server} =
        PreviewServer.build_for_worktree(
          record(),
          "rt",
          "tmux",
          "/wt",
          %{"preview_port" => "5050"},
          []
        )

      assert server["port"] == 5050
    end

    test "falls back to attrs port" do
      {:ok, server} =
        PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", %{"port" => 5101}, [])

      assert server["port"] == 5101
    end

    test "falls back to runtime_profile app port" do
      attrs = %{"runtime_profile" => %{"ports" => %{"app" => 5200}}}
      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["port"] == 5200
    end

    test "profile http port used when app missing" do
      attrs = %{"runtime_profile" => %{"ports" => %{"http" => 5300}}}
      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["port"] == 5300
    end

    test "profile PORT env used when ports missing" do
      attrs = %{"runtime_profile" => %{"env" => %{"PORT" => "5400"}}}
      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["port"] == 5400
    end

    test "profile surfaces port used when ports and env missing" do
      attrs = %{"runtime_profile" => %{"surfaces" => [%{"port" => 5500}]}}
      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["port"] == 5500
    end

    test "profile pulled from metadata.runtime_profile" do
      attrs = %{"metadata" => %{"runtime_profile" => %{"ports" => %{"app" => 5600}}}}
      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["port"] == 5600
    end

    test "falls back to existing preview_server port" do
      attrs = %{"preview_server" => %{"port" => 5700}}
      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["port"] == 5700
    end

    test "existing preview_server read from metadata" do
      attrs = %{"metadata" => %{"preview_server" => %{"port" => 5800, "command" => ["run"]}}}
      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["port"] == 5800
      assert server["command"] == ["run"]
    end

    test "reallocates an existing preview port reserved by another runtime" do
      {:ok, initial} =
        PreviewServer.build_for_worktree(
          record(),
          "rt-restored",
          "tmux",
          "/wt",
          %{"preview_port" => 5800},
          []
        )

      attrs = %{"metadata" => %{"preview_server" => initial}}

      {:ok, server} =
        PreviewServer.build_for_worktree(record(), "rt-restored", "tmux", "/wt", attrs, [5800])

      refute server["port"] == 5800
      assert server["port"] in 41_050..41_079
      assert server["env"]["PORT"] == Integer.to_string(server["port"])
      assert List.last(server["command"]) == Integer.to_string(server["port"])
      refute server["command"] == initial["command"]
    end

    test "reallocates an occupied retained port unless the active runtime owns it" do
      {:ok, probe} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {{127, 0, 0, 1}, occupied_port}} = :inet.sockname(probe)
      :ok = :gen_tcp.close(probe)

      {:ok, initial} =
        PreviewServer.build_for_worktree(
          record(),
          "rt-retained",
          "tmux",
          "/wt",
          %{"preview_port" => occupied_port},
          []
        )

      {:ok, listener} =
        :gen_tcp.listen(occupied_port, [
          :binary,
          active: false,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

      on_exit(fn -> :gen_tcp.close(listener) end)

      attrs = %{"metadata" => %{"preview_server" => initial}}

      {:ok, reallocated} =
        PreviewServer.build_for_worktree(
          record(),
          "rt-retained",
          "tmux",
          "/wt",
          attrs,
          []
        )

      refute reallocated["port"] == occupied_port

      {:ok, retained} =
        PreviewServer.build_for_worktree(
          record(),
          "rt-retained",
          "tmux",
          "/wt",
          Map.put(attrs, "_allow_occupied_preview_port", true),
          []
        )

      assert retained["port"] == occupied_port
      assert retained["command"] == initial["command"]
    end

    test "allocated ports come from the runtime preview range" do
      {:ok, server} =
        PreviewServer.build_for_worktree(record(), "rt-auto", "tmux", "/wt", %{}, [])

      assert server["port"] in 41_050..41_079
    end

    test "allocation fails instead of falling back to an occupied preferred port" do
      used_ports = Enum.to_list(41_050..41_079)

      assert PreviewServer.build_for_worktree(record(), "rt-full", "tmux", "/wt", %{}, used_ports) ==
               {:error, :no_runtime_preview_port_available}
    end
  end

  describe "owns_live_port?/1" do
    test "requires a matching live launcher registry and reachable port" do
      base =
        Path.join(
          System.tmp_dir!(),
          "casein-preview-owner-#{System.unique_integer([:positive])}"
        )

      cwd = Path.join(base, "worktree")
      preview_home = Path.join(base, "preview-home")
      registry_dir = Path.join(preview_home, "instances")
      File.mkdir_p!(cwd)
      File.mkdir_p!(registry_dir)
      on_exit(fn -> File.rm_rf!(base) end)

      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      registry = %{
        "runtime_id" => "rt-owned",
        "workspace_id" => "ws-ext-1",
        "checkout" => cwd,
        "port" => Integer.to_string(port),
        "pid" => System.pid(),
        "status" => "running"
      }

      File.write!(
        Path.join(registry_dir, "rt-owned.json"),
        Jason.encode!(registry)
      )

      server = %{
        "runtime_id" => "rt-owned",
        "workspace_id" => "ws-ext-1",
        "cwd" => cwd,
        "port" => port,
        "env" => %{"CASEIN_PREVIEW_HOME" => preview_home}
      }

      assert PreviewServer.owns_live_port?(server)
      refute PreviewServer.owns_live_port?(%{server | "runtime_id" => "rt-other"})
      refute PreviewServer.owns_live_port?(%{server | "workspace_id" => "ws-other"})
      refute PreviewServer.owns_live_port?(%{server | "port" => port + 1})

      File.write!(
        Path.join(registry_dir, "rt-owned.json"),
        Jason.encode!(%{registry | "status" => "failed"})
      )

      refute PreviewServer.owns_live_port?(server)
    end
  end

  describe "build_for_worktree/6 — command derivation" do
    test "command from runtime_profile (string) wraps into list" do
      attrs = %{"port" => 6000, "runtime_profile" => %{"command" => "start.sh"}}
      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["command"] == ["start.sh"]
    end

    test "command from runtime_profile (list) filters blanks" do
      attrs = %{"port" => 6001, "runtime_profile" => %{"command" => ["bash", "", "x"]}}
      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["command"] == ["bash", "x"]
    end

    test "falls back to existing preview_server command" do
      attrs = %{"port" => 6002, "preview_server" => %{"command" => ["existing", "cmd"]}}
      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["command"] == ["existing", "cmd"]
    end

    test "legacy preview-env command is rejected and falls through to default" do
      System.put_env("CASEIN_RUNTIME_PREVIEW_LAUNCHER", "/custom/launch.sh")

      attrs = %{
        "port" => 6003,
        "runtime_profile" => %{
          "command" => ["bash", "scripts/preview-env.sh", "dirty", "--port", "6003"]
        }
      }

      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["command"] == ["bash", "/custom/launch.sh", "--port", "6003"]
    after
      System.delete_env("CASEIN_RUNTIME_PREVIEW_LAUNCHER")
    end

    test "default command uses configured launcher path and string port" do
      System.put_env("CASEIN_RUNTIME_PREVIEW_LAUNCHER", "/opt/launcher.sh")

      {:ok, server} =
        PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", %{"port" => 6004}, [])

      assert server["command"] == ["bash", "/opt/launcher.sh", "--port", "6004"]
    after
      System.delete_env("CASEIN_RUNTIME_PREVIEW_LAUNCHER")
    end
  end

  describe "build_for_worktree/6 — status derivation" do
    test "preview_status attr (trimmed) wins" do
      attrs = %{"port" => 7000, "preview_status" => "  running  "}
      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["status"] == "running"
    end

    test "blank preview_status falls back to existing server status" do
      attrs = %{
        "port" => 7001,
        "preview_status" => "   ",
        "preview_server" => %{"status" => "ready"}
      }

      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["status"] == "ready"
    end

    test "defaults to provisioned when no status anywhere" do
      {:ok, server} =
        PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", %{"port" => 7002}, [])

      assert server["status"] == "provisioned"
    end
  end

  describe "build_for_worktree/6 — env construction" do
    test "merges existing env, profile env, and computed env with overrides winning" do
      attrs = %{
        "port" => 8000,
        "preview_server" => %{"env" => %{"KEEP" => "1", "PORT" => "999"}},
        "runtime_profile" => %{"env" => %{"FROM_PROFILE" => "p", "PORT" => "888"}}
      }

      {:ok, server} =
        PreviewServer.build_for_worktree(
          record(%{external_id: "ws-env", host_path: "/host/root"}),
          "rt-env",
          "tmux-env",
          "/wt/env",
          attrs,
          []
        )

      env = server["env"]
      assert env["KEEP"] == "1"
      assert env["FROM_PROFILE"] == "p"
      # computed values override both existing and profile env
      assert env["PORT"] == "8000"
      assert env["CASEIN_RUNTIME_ID"] == "rt-env"
      assert env["CASEIN_WORKSPACE_ID"] == "ws-env"
      assert env["CASEIN_TMUX_SESSION"] == "tmux-env"
      assert env["CASEIN_PREVIEW_HOME"] == "/host/root/.casein-preview"

      assert env["CASEIN_RUNTIME_PREVIEW_SOCKET"] ==
               Path.join(["/host/root", ".casein-preview", "sockets", socket_name("rt-env")])
    end

    test "non-string/int env entries are dropped; nil host_path uses worktree_path" do
      attrs = %{"port" => 8001, "preview_server" => %{"env" => %{"BAD" => %{}, "OK" => 5}}}

      {:ok, server} =
        PreviewServer.build_for_worktree(
          record(%{host_path: nil}),
          "rt2",
          "tmux2",
          "/wt/only",
          attrs,
          []
        )

      env = server["env"]
      refute Map.has_key?(env, "BAD")
      assert env["OK"] == "5"
      assert env["CASEIN_PREVIEW_HOME"] == "/wt/only/.casein-preview"
    end

    test "Phoenix worktree previews force dev and carry the observed revision" do
      worktree =
        Path.join(
          System.tmp_dir!(),
          "casein-preview-mix-env-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(worktree)
      File.write!(Path.join(worktree, "mix.exs"), "defmodule Preview.MixProject do\nend\n")
      on_exit(fn -> File.rm_rf!(worktree) end)

      revision = String.duplicate("a", 40)

      attrs = %{
        "port" => 8002,
        "metadata" => %{"git_head_sha" => revision},
        "runtime_profile" => %{
          "env" => %{"MIX_ENV" => "prod", "SOURCE_REVISION" => "stale"}
        }
      }

      {:ok, server} =
        PreviewServer.build_for_worktree(record(), "rt-mix", "tmux-mix", worktree, attrs, [])

      assert server["env"]["MIX_ENV"] == "dev"
      assert server["env"]["SOURCE_REVISION"] == revision
    end
  end

  defp socket_name(runtime_id) do
    hash =
      runtime_id
      |> :erlang.phash2(2_176_782_336)
      |> Integer.to_string(36)
      |> String.downcase()

    "rt-#{hash}.sock"
  end

  describe "for_metadata/1" do
    test "returns the embedded preview_server map" do
      server = %{"id" => "x"}
      assert PreviewServer.for_metadata(%{"preview_server" => server}) == server
    end

    test "reads via atom key fallback" do
      server = %{"id" => "y"}
      assert PreviewServer.for_metadata(%{preview_server: server}) == server
    end

    test "returns nil when preview_server is not a map" do
      assert PreviewServer.for_metadata(%{"preview_server" => "nope"}) == nil
    end

    test "returns nil when key absent" do
      assert PreviewServer.for_metadata(%{}) == nil
    end

    test "returns nil for non-map input" do
      assert PreviewServer.for_metadata(nil) == nil
    end
  end

  describe "put_profile/2" do
    test "non-map server returns metadata unchanged" do
      assert PreviewServer.put_profile(%{"a" => 1}, "nope") == %{"a" => 1}
    end

    test "stores preview_server and derives a normalized phoenix profile" do
      server = %{
        "id" => "preview:rt:app",
        "source" => "runtime_preview_server",
        "command" => ["run", "me"],
        "cwd" => "/wt",
        "port" => 4500,
        "env" => %{"A" => "1"}
      }

      result = PreviewServer.put_profile(%{}, server)

      assert result["preview_server"] == server

      profile = result["runtime_profile"]
      assert profile["name"] == "phoenix"
      assert profile["kind"] == "phoenix"
      assert profile["command"] == ["run", "me"]
      assert profile["cwd"] == "/wt"
      assert profile["env"] == %{"A" => "1"}
      assert profile["ports"]["app"] == 4500
      assert profile["surfaces"] == [%{"name" => "app", "port" => 4500}]
      assert profile["metadata"]["preview_server_id"] == "preview:rt:app"
      assert profile["metadata"]["source"] == "runtime_preview_server"
    end

    test "merges existing profile env and ports" do
      existing = %{
        "runtime_profile" => %{
          "name" => "phoenix",
          "env" => %{"EXIST" => "e"},
          "ports" => %{"api" => 9001}
        }
      }

      server = %{
        "command" => ["c"],
        "cwd" => "/x",
        "port" => 4600,
        "env" => %{"NEW" => "n"}
      }

      result = PreviewServer.put_profile(existing, server)
      profile = result["runtime_profile"]

      assert profile["env"]["EXIST"] == "e"
      assert profile["env"]["NEW"] == "n"
      assert profile["ports"]["api"] == 9001
      assert profile["ports"]["app"] == 4600
    end
  end

  describe "put_status/3" do
    test "put_unavailable records profile failure metadata without a preview server" do
      metadata = %{
        "preview_server" => %{"port" => 41_050},
        "runtime_profile" => %{"name" => "phoenix", "metadata" => %{"keep" => "k"}}
      }

      result = PreviewServer.put_unavailable(metadata, "no_runtime_preview_port_available")

      refute Map.has_key?(result, "preview_server")
      assert result["runtime_profile"]["name"] == "phoenix"
      assert result["runtime_profile"]["metadata"]["keep"] == "k"
      assert result["runtime_profile"]["metadata"]["preview_status"] == "failed"

      assert result["runtime_profile"]["metadata"]["preview_failure_reason"] ==
               "no_runtime_preview_port_available"
    end

    test "non-binary status returns metadata unchanged" do
      assert PreviewServer.put_status(%{"a" => 1}, :running) == %{"a" => 1}
    end

    test "sets status on existing server and preview_status in profile metadata" do
      metadata = %{
        "preview_server" => %{"id" => "s", "status" => "old"},
        "runtime_profile" => %{"metadata" => %{"keep" => "k"}}
      }

      result = PreviewServer.put_status(metadata, "running")

      assert result["preview_server"]["status"] == "running"
      assert result["preview_server"]["id"] == "s"
      refute Map.has_key?(result["preview_server"], "failure_reason")

      assert result["runtime_profile"]["metadata"]["preview_status"] == "running"
      assert result["runtime_profile"]["metadata"]["keep"] == "k"
      refute Map.has_key?(result["runtime_profile"]["metadata"], "preview_failure_reason")
    end

    test "starts from empty server when none present" do
      result = PreviewServer.put_status(%{}, "failed")
      assert result["preview_server"] == %{"status" => "failed"}
    end

    test "non-map preview_server treated as empty server" do
      result = PreviewServer.put_status(%{"preview_server" => "nope"}, "ready")
      assert result["preview_server"] == %{"status" => "ready"}
    end

    test "failure_reason set on server and profile metadata" do
      result = PreviewServer.put_status(%{}, "failed", "boom")
      assert result["preview_server"]["failure_reason"] == "boom"
      assert result["runtime_profile"]["metadata"]["preview_failure_reason"] == "boom"
    end

    test "blank/nil failure_reason deletes the reason on server and profile" do
      metadata = %{
        "preview_server" => %{"failure_reason" => "old"},
        "runtime_profile" => %{"metadata" => %{"preview_failure_reason" => "old"}}
      }

      result = PreviewServer.put_status(metadata, "running", "")
      refute Map.has_key?(result["preview_server"], "failure_reason")
      refute Map.has_key?(result["runtime_profile"]["metadata"], "preview_failure_reason")

      result_nil = PreviewServer.put_status(metadata, "running", nil)
      refute Map.has_key?(result_nil["preview_server"], "failure_reason")
    end

    test "non-map runtime_profile becomes a map with metadata" do
      result = PreviewServer.put_status(%{"runtime_profile" => "nope"}, "running")
      assert result["runtime_profile"]["metadata"]["preview_status"] == "running"
    end
  end

  describe "metadata_ports/1" do
    test "non-map returns empty list" do
      assert PreviewServer.metadata_ports(nil) == []
    end

    test "empty metadata returns empty list" do
      assert PreviewServer.metadata_ports(%{}) == []
    end

    test "collects preview_server port and profile ports, deduped" do
      metadata = %{
        "preview_server" => %{"port" => 4000},
        "runtime_profile" => %{"ports" => %{"app" => 4000, "api" => 5000}}
      }

      ports = PreviewServer.metadata_ports(metadata)
      assert Enum.sort(ports) == [4000, 5000]
    end

    test "string ports are parsed; invalid ones dropped" do
      metadata = %{
        "preview_server" => %{"port" => "6001"},
        "runtime_profile" => %{"ports" => %{"app" => "bad", "api" => 6002}}
      }

      ports = PreviewServer.metadata_ports(metadata)
      assert Enum.sort(ports) == [6001, 6002]
    end

    test "out-of-range preview_server port is ignored" do
      metadata = %{"preview_server" => %{"port" => 70_000}}
      assert PreviewServer.metadata_ports(metadata) == []
    end

    test "missing preview_server still reads profile ports" do
      metadata = %{"runtime_profile" => %{"ports" => %{"app" => 7777}}}
      assert PreviewServer.metadata_ports(metadata) == [7777]
    end
  end
end
