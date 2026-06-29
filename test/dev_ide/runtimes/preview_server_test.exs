defmodule DevIDE.Runtimes.PreviewServerTest do
  use ExUnit.Case, async: true

  alias DevIDE.Runtimes.PreviewServer
  alias DevIDE.Workspaces.State.WorkspaceRecord

  # All of these tests exercise the PURE derivation/construction logic of
  # PreviewServer. The only IO touch-points are:
  #   * allocate_port/2 -> port_available?/1 (gen_tcp.listen) — avoided by always
  #     supplying an explicit port through attrs.
  #   * default_launcher_path/0 (File/System/Application) — made deterministic by
  #     setting DEV_IDE_RUNTIME_PREVIEW_LAUNCHER for the default-command branch.

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
      System.put_env("DEV_IDE_RUNTIME_PREVIEW_LAUNCHER", "/custom/launch.sh")

      attrs = %{
        "port" => 6003,
        "runtime_profile" => %{
          "command" => ["bash", "scripts/preview-env.sh", "dirty", "--port", "6003"]
        }
      }

      {:ok, server} = PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", attrs, [])
      assert server["command"] == ["bash", "/custom/launch.sh", "--port", "6003"]
    after
      System.delete_env("DEV_IDE_RUNTIME_PREVIEW_LAUNCHER")
    end

    test "default command uses configured launcher path and string port" do
      System.put_env("DEV_IDE_RUNTIME_PREVIEW_LAUNCHER", "/opt/launcher.sh")

      {:ok, server} =
        PreviewServer.build_for_worktree(record(), "rt", "tmux", "/wt", %{"port" => 6004}, [])

      assert server["command"] == ["bash", "/opt/launcher.sh", "--port", "6004"]
    after
      System.delete_env("DEV_IDE_RUNTIME_PREVIEW_LAUNCHER")
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
      assert env["DEVIDE_RUNTIME_ID"] == "rt-env"
      assert env["DEVIDE_WORKSPACE_ID"] == "ws-env"
      assert env["DEVIDE_TMUX_SESSION"] == "tmux-env"
      assert env["DEVIDE_PREVIEW_HOME"] == "/host/root/.devide-preview"

      assert env["DEVIDE_RUNTIME_PREVIEW_SOCKET"] ==
               Path.join(["/host/root", ".devide-preview", "sockets", socket_name("rt-env")])
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
      assert env["DEVIDE_PREVIEW_HOME"] == "/wt/only/.devide-preview"
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
