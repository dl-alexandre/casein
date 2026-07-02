defmodule DevIDE.AgentsFacadeTest do
  use ExUnit.Case, async: false

  alias DevIDE.Agents
  alias DevIDE.Agents.{Artifact, Capability, ReviewCommand}

  defmodule Stub do
    @behaviour DevIDE.Agents

    @impl true
    def detect(root, ws) do
      send(stub_pid(), {:detect, root, ws})

      [
        %Capability{kind: :opencode, status: :detected, source: :workspace_fs, path: ".opencode"}
      ]
    end

    @impl true
    def transcripts(root) do
      send(stub_pid(), {:transcripts, root})

      [
        %Artifact{
          rel_path: ".opencode/logs/run.log",
          name: "run.log",
          size: 42,
          mtime: nil
        }
      ]
    end

    @impl true
    def review_commands(caps) do
      send(stub_pid(), {:review_commands, caps})
      Enum.filter(ReviewCommand.all(), &ReviewCommand.available?(&1, caps))
    end

    defp stub_pid, do: Application.fetch_env!(:dev_ide, :agents_facade_stub_pid)
  end

  setup do
    prev = Application.get_env(:dev_ide, :agents_adapter)
    Application.put_env(:dev_ide, :agents_adapter, Stub)
    Application.put_env(:dev_ide, :agents_facade_stub_pid, self())

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:dev_ide, :agents_adapter)
        value -> Application.put_env(:dev_ide, :agents_adapter, value)
      end

      Application.delete_env(:dev_ide, :agents_facade_stub_pid)
    end)

    :ok
  end

  test "detect/2 delegates to the configured adapter" do
    root = "/tmp/ws"
    ws = %{metadata: %{}}

    assert [%Capability{kind: :opencode, status: :detected}] = Agents.detect(root, ws)
    assert_receive {:detect, ^root, ^ws}
  end

  test "detect/1 defaults manager workspace to nil" do
    root = "/tmp/ws-only"

    assert [%Capability{kind: :opencode}] = Agents.detect(root)
    assert_receive {:detect, ^root, nil}
  end

  test "transcripts/1 delegates to the configured adapter" do
    root = "/tmp/transcripts"

    assert [%Artifact{name: "run.log"}] = Agents.transcripts(root)
    assert_receive {:transcripts, ^root}
  end

  test "review_commands/1 delegates to the configured adapter" do
    caps = [%Capability{kind: :opencode, status: :detected}]

    cmds = Agents.review_commands(caps)
    assert is_list(cmds)
    assert Enum.all?(cmds, &match?(%ReviewCommand{}, &1))
    assert_receive {:review_commands, ^caps}
  end

  test "split_preview_pane/3 delegates through the agents facade" do
    workspace = %{id: "ws-agents-facade", metadata: %{}}

    assert {:error, :no_tmux_session} =
             Agents.split_preview_pane(workspace, "http://localhost:5173/", tmux_session: nil)
  end
end
