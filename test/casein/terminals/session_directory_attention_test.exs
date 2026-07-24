defmodule Casein.Terminals.SessionDirectory.AttentionTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.Session.Info, as: SessionInfo
  alias Casein.Terminals.SessionDirectory.Attention

  describe "classify/1" do
    test "puts blocked and failed sessions in Needs You" do
      assert Attention.classify(session(agent_state: :blocked)) ==
               %{section: :needs_you, reason: :blocked}

      failed = %{session() | status: :error}

      assert Attention.classify(failed) == %{section: :needs_you, reason: :error}
    end

    test "puts completed and quiet agents in Needs You" do
      assert Attention.classify(session(agent_state: "done")) ==
               %{section: :needs_you, reason: :completed}

      assert Attention.classify(session(quiet: true)) ==
               %{section: :needs_you, reason: :quiet}
    end

    test "blocked wins over done, quiet, and working signals" do
      info =
        session(
          windows: [
            %{agent_state: :working},
            %{agent_state: :done, quiet: true},
            %{agent_state: :blocked}
          ]
        )

      assert Attention.classify(info) == %{section: :needs_you, reason: :blocked}
    end

    test "puts active semantic work in Working and ordinary shells in Recent" do
      assert Attention.classify(session(agent_state: :working)) ==
               %{section: :working, reason: :working}

      assert Attention.classify(session()) == %{section: :recent, reason: :recent}
    end

    test "accepts JSON-style string-keyed metadata without provider fields" do
      info = %{
        "status" => "active",
        "metadata" => %{"windows" => [%{"agent_state" => "running"}]}
      }

      assert Attention.classify(info) == %{section: :working, reason: :working}
    end
  end

  describe "group/1" do
    test "stable-partitions existing row order into Needs You, Working, and Recent" do
      recent_old = session(id: "recent-old")
      working_old = session(id: "working-old", agent_state: :working)
      blocked = session(id: "blocked", agent_state: :blocked)
      recent_new = session(id: "recent-new")
      working_new = session(id: "working-new", agent_state: :working)
      quiet = session(id: "quiet", quiet: true)

      assert %{
               needs_you: [^blocked, ^quiet],
               working: [^working_old, ^working_new],
               recent: [^recent_old, ^recent_new]
             } =
               Attention.group([
                 recent_old,
                 working_old,
                 blocked,
                 recent_new,
                 working_new,
                 quiet
               ])
    end
  end

  defp session(opts \\ []) do
    id = Keyword.get(opts, :id, "session")

    windows =
      case Keyword.fetch(opts, :windows) do
        {:ok, windows} ->
          windows

        :error ->
          [
            %{}
            |> maybe_put(:agent_state, Keyword.get(opts, :agent_state))
            |> maybe_put(:quiet, Keyword.get(opts, :quiet))
          ]
      end

    SessionInfo.new_shell("workspace", id, metadata: %{windows: windows})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
