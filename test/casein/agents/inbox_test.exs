defmodule Casein.Agents.InboxTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.AgentEvents
  alias Casein.Agents.Inbox
  alias Casein.Agents.Inbox.Address

  setup do
    AgentEvents.clear()
    on_exit(fn -> AgentEvents.clear() end)
    %{ws: "ws-inbox-#{System.unique_integer([:positive])}"}
  end

  describe "send/1" do
    test "leaves a message at an address", %{ws: ws} do
      assert {:ok, event, :inserted} =
               Inbox.send(%{
                 workspace_id: ws,
                 to: Address.for_pane("%3"),
                 from: Address.for_pane("%1"),
                 body: "I changed the auth schema; rebase before editing"
               })

      assert event.event_type == Inbox.message_type()
      # A message body is content, not metadata.
      assert event.privacy_class == "operator_content"
      assert event.payload["body"] =~ "auth schema"
    end

    test "the summary carries addresses, never the body", %{ws: ws} do
      {:ok, event, _} =
        Inbox.send(%{
          workspace_id: ws,
          to: Address.for_pane("%3"),
          from: Address.for_pane("%1"),
          body: "secret-sounding detail"
        })

      # Summaries land in surfaces not entitled to operator content.
      refute event.summary =~ "secret-sounding"
      assert event.summary =~ "%1"
      assert event.summary =~ "%3"
    end

    test "a retried send with the same id coalesces", %{ws: ws} do
      attrs = %{
        workspace_id: ws,
        to: Address.for_pane("%3"),
        body: "rebase before editing",
        message_id: "msg-1"
      }

      assert {:ok, first, :inserted} = Inbox.send(attrs)
      assert {:ok, second, :duplicate} = Inbox.send(attrs)
      assert first.id == second.id

      assert length(Inbox.list(ws, Address.for_pane("%3"))) == 1
    end

    test "two different messages to one address both survive", %{ws: ws} do
      to = Address.for_pane("%3")
      assert {:ok, _, :inserted} = Inbox.send(%{workspace_id: ws, to: to, body: "first"})
      assert {:ok, _, :inserted} = Inbox.send(%{workspace_id: ws, to: to, body: "second"})

      assert length(Inbox.list(ws, to)) == 2
    end

    test "refuses an empty body and a non-canonical address", %{ws: ws} do
      to = Address.for_pane("%3")
      assert {:error, :empty_body} = Inbox.send(%{workspace_id: ws, to: to, body: "   "})
      assert {:error, :invalid_address} = Inbox.send(%{workspace_id: ws, to: "%3", body: "hi"})
      assert {:error, :missing_workspace_id} = Inbox.send(%{to: to, body: "hi"})
    end

    test "caps a runaway body rather than storing it whole", %{ws: ws} do
      body = String.duplicate("x", Inbox.body_limit() * 2)
      {:ok, event, _} = Inbox.send(%{workspace_id: ws, to: Address.for_pane("%3"), body: body})

      assert String.length(event.payload["body"]) == Inbox.body_limit()
    end
  end

  describe "list/3" do
    test "returns every uncollected message, oldest first", %{ws: ws} do
      # The starvation trap: the clarification projector keeps only the newest
      # per pane, which for a mailbox permanently hides the earlier message.
      to = Address.for_pane("%3")
      Inbox.send(%{workspace_id: ws, to: to, body: "first", message_id: "m1"})
      Inbox.send(%{workspace_id: ws, to: to, body: "second", message_id: "m2"})
      Inbox.send(%{workspace_id: ws, to: to, body: "third", message_id: "m3"})

      bodies = ws |> Inbox.list(to) |> Enum.map(& &1.body)
      assert bodies == ["first", "second", "third"]
    end

    test "only messages for this address", %{ws: ws} do
      Inbox.send(%{workspace_id: ws, to: Address.for_pane("%3"), body: "for three"})
      Inbox.send(%{workspace_id: ws, to: Address.for_pane("%4"), body: "for four"})

      assert [%{body: "for three"}] = Inbox.list(ws, Address.for_pane("%3"))
    end

    test "a worktree address is its own mailbox", %{ws: ws} do
      to = Address.for_worktree("/data/worktrees/wt-a")
      Inbox.send(%{workspace_id: ws, to: to, body: "for whoever is in this checkout"})

      assert [%{body: "for whoever is in this checkout"}] = Inbox.list(ws, to)
      assert Inbox.list(ws, Address.for_pane("%3")) == []
    end

    test "a handle address is its own mailbox and survives listing by many", %{ws: ws} do
      to = Address.for_handle("coord-1")
      Inbox.send(%{workspace_id: ws, to: to, body: "role mail"})
      Inbox.send(%{workspace_id: ws, to: Address.for_pane("%3"), body: "pane mail"})

      assert [%{body: "role mail"}] = Inbox.list(ws, to)

      bodies =
        ws
        |> Inbox.list([to, Address.for_pane("%3")])
        |> Enum.map(& &1.body)

      assert bodies == ["role mail", "pane mail"]
    end

    test "an empty mailbox is empty, not an error", %{ws: ws} do
      assert Inbox.list(ws, Address.for_pane("%9")) == []
    end

    test "orphaned lists pane mailboxes whose pane is gone", %{ws: ws} do
      Inbox.send(%{workspace_id: ws, to: Address.for_pane("%5"), body: "stranded"})
      Inbox.send(%{workspace_id: ws, to: Address.for_pane("%3"), body: "live"})
      Inbox.send(%{workspace_id: ws, to: Address.for_handle("coord-1"), body: "role"})

      assert [%{address: "pane:%5", pending: 1, orphaned: true}] =
               Inbox.orphaned(ws, ["%3"])
    end
  end

  describe "collect/3" do
    test "collected messages leave the mailbox", %{ws: ws} do
      to = Address.for_pane("%3")
      {:ok, event, _} = Inbox.send(%{workspace_id: ws, to: to, body: "read me"})

      assert [%{id: id}] = Inbox.list(ws, to)
      assert id == event.id

      assert {:ok, _receipt, :inserted} = Inbox.collect(ws, event.id, %{to: to})
      assert Inbox.list(ws, to) == []
    end

    test "collecting one message does not collect the others", %{ws: ws} do
      to = Address.for_pane("%3")
      {:ok, first, _} = Inbox.send(%{workspace_id: ws, to: to, body: "first", message_id: "m1"})
      Inbox.send(%{workspace_id: ws, to: to, body: "second", message_id: "m2"})

      Inbox.collect(ws, first.id, %{to: to})

      assert [%{body: "second"}] = Inbox.list(ws, to)
    end

    test "collecting twice is a duplicate receipt, not a second one", %{ws: ws} do
      to = Address.for_pane("%3")
      {:ok, event, _} = Inbox.send(%{workspace_id: ws, to: to, body: "read me"})

      assert {:ok, _, :inserted} = Inbox.collect(ws, event.id, %{to: to})
      assert {:ok, _, :duplicate} = Inbox.collect(ws, event.id, %{to: to})
    end

    test "sent-but-never-read stays visible", %{ws: ws} do
      # The property the pane path could never provide: an uncollected message
      # is distinguishable from a delivered one.
      to = Address.for_pane("%3")
      Inbox.send(%{workspace_id: ws, to: to, body: "never read"})

      assert [%{body: "never read"}] = Inbox.list(ws, to)
      assert length(Inbox.list(ws, to, include_collected: true)) == 1
    end

    test "a receipt is metadata, carrying no body", %{ws: ws} do
      to = Address.for_pane("%3")
      {:ok, event, _} = Inbox.send(%{workspace_id: ws, to: to, body: "sensitive"})
      {:ok, receipt, _} = Inbox.collect(ws, event.id, %{to: to})

      assert receipt.privacy_class == "metadata"
      refute inspect(receipt) =~ "sensitive"
    end
  end

  # #911 — constraints in the artifact. If a later change reports collected on
  # send, fails to clear unread on collect, or double-delivers on re-collect,
  # these fail first (briefs die with the pane; pane writes stay disabled).
  describe "lifecycle honesty #911" do
    test "sent message is queued and unread until collect", %{ws: ws} do
      to = Address.for_pane("%3")

      assert {:ok, _event, :inserted} =
               Inbox.send(%{
                 workspace_id: ws,
                 to: to,
                 body: "waiting",
                 message_id: "stable-wait"
               })

      assert [%{status: :queued, unread?: true, message_id: "stable-wait", collected_at: nil}] =
               Inbox.list(ws, to)

      assert %{pending: 1, unread: 1, collected: 0} = Inbox.summary(ws, to)

      assert {:ok, %{status: :queued, unread?: true}} =
               Inbox.get_by_message_id(ws, "stable-wait")
    end

    test "collect clears unread and marks collected — never leaves queued+collected", %{ws: ws} do
      to = Address.for_pane("%3")
      {:ok, event, _} = Inbox.send(%{workspace_id: ws, to: to, body: "act", message_id: "m-act"})

      assert {:ok, _, :inserted} = Inbox.collect(ws, event.id, %{to: to})

      assert Inbox.list(ws, to) == []
      assert %{pending: 0, unread: 0, collected: 1} = Inbox.summary(ws, to)

      assert [%{status: :collected, unread?: false, collected_at: %DateTime{}}] =
               Inbox.list(ws, to, include_collected: true)

      # Honest get_by_message_id after collect
      assert {:ok, %{status: :collected, unread?: false}} =
               Inbox.get_by_message_id(ws, "m-act")
    end

    test "double-collect by event id is idempotent — no second receipt", %{ws: ws} do
      to = Address.for_pane("%3")

      {:ok, event, _} =
        Inbox.send(%{workspace_id: ws, to: to, body: "once", message_id: "once-1"})

      assert {:ok, first, :inserted} = Inbox.collect(ws, event.id, %{to: to})
      assert {:ok, second, :duplicate} = Inbox.collect(ws, event.id, %{to: to})
      assert first.id == second.id
      assert %{pending: 0, unread: 0, collected: 1} = Inbox.summary(ws, to)
    end

    test "double-collect by stable message_id is idempotent", %{ws: ws} do
      to = Address.for_pane("%3")
      message_id = "stable-collect-key"

      assert {:ok, _event, :inserted} =
               Inbox.send(%{workspace_id: ws, to: to, body: "by key", message_id: message_id})

      assert {:ok, first, :inserted} = Inbox.collect(ws, message_id, %{to: to})
      assert {:ok, second, :duplicate} = Inbox.collect(ws, message_id, %{to: to})
      assert first.id == second.id

      # Still a single collected message — not two deliveries
      assert length(Inbox.list(ws, to, include_collected: true)) == 1
      assert %{unread: 0, collected: 1} = Inbox.summary(ws, to)
    end

    test "send never invents collected status", %{ws: ws} do
      to = Address.for_pane("%3")
      Inbox.send(%{workspace_id: ws, to: to, body: "only sent", message_id: "only-sent"})

      for msg <- Inbox.list(ws, to, include_collected: true) do
        refute msg.status == :collected
        assert msg.unread? == true
        assert msg.status == :queued
      end
    end
  end
end
