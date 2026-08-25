defmodule Casein.Agents.Inbox.AddressTest do
  use ExUnit.Case, async: true

  alias Casein.Agents.Inbox.Address

  describe "validate/1" do
    test "accepts the canonical forms" do
      assert {:ok, "pane:%3"} = Address.validate("pane:%3")
      assert {:ok, "worktree:/data/wt-a"} = Address.validate("worktree:/data/wt-a")
      assert {:ok, "handle:abc123"} = Address.validate("handle:abc123")
      assert {:ok, "pane:%3"} = Address.validate("  pane:%3  ")
    end

    test "rejects anything else, so a typo cannot become a mailbox nobody reads" do
      for value <- ["%3", "worker-2", "pane:", "worktree:  ", "handle:", "handle:  ", "", nil, 3] do
        assert {:error, :invalid_address} = Address.validate(value)
      end
    end
  end

  describe "resolve/2" do
    test "passes a live canonical address through untouched" do
      assert {:ok, "pane:%3"} = Address.resolve("pane:%3", topology())
      assert {:ok, "handle:abc123"} = Address.resolve("handle:abc123", topology())
    end

    test "resolves an exact pane id that exists" do
      assert {:ok, "pane:%3"} = Address.resolve("%3", topology())
    end

    test "an exact pane id that does not exist is not silently accepted" do
      assert {:error, :unknown_recipient} = Address.resolve("%99", topology())
    end

    test "a canonical pane: address whose pane is gone is not silently accepted" do
      assert {:error, :unknown_recipient} = Address.resolve("pane:%99", topology())
    end

    test "resolves a unique window name to its agent pane" do
      assert {:ok, "pane:%3"} = Address.resolve("api-gateway", topology())
      assert {:ok, "pane:%3"} = Address.resolve("API-Gateway", topology())
    end

    test "refuses a name matching two windows, and says which" do
      # Misdelivery is worse than non-delivery: the sender believes it landed
      # and the recipient acts on work that was not theirs.
      assert {:error, {:ambiguous, candidates}} = Address.resolve("worker", ambiguous_topology())

      assert Enum.map(candidates, & &1.address) |> Enum.sort() == ["pane:%7", "pane:%8"]
      assert Enum.all?(candidates, &(&1.name == "worker"))
    end

    test "an unknown name is an error rather than a new mailbox" do
      assert {:error, :unknown_recipient} = Address.resolve("nobody", topology())
    end

    test "a blank recipient is invalid" do
      assert {:error, :invalid_address} = Address.resolve("   ", topology())
      assert {:error, :invalid_address} = Address.resolve(nil, topology())
    end
  end

  describe "constructors" do
    test "worktree addresses are expanded, so one checkout is one mailbox" do
      assert Address.for_worktree("/data/wt-a/../wt-a") == "worktree:/data/wt-a"
    end

    test "handle addresses wrap the durable id" do
      assert Address.for_handle("abc123") == "handle:abc123"
      assert Address.handle_id("handle:abc123") == "abc123"
      assert Address.pane_id("pane:%3") == "%3"
      assert Address.pane_id("handle:abc123") == nil
    end
  end

  ## Fixtures

  defp topology do
    pane = %{id: "%3", role: "agent"}

    %{
      panes: [pane, %{id: "%1", role: "shell"}],
      windows: [%{id: "@1", name: "api-gateway", pane_list: [pane]}]
    }
  end

  defp ambiguous_topology do
    a = %{id: "%7", role: "agent"}
    b = %{id: "%8", role: "agent"}

    %{
      panes: [a, b],
      windows: [
        %{id: "@1", name: "worker", pane_list: [a]},
        %{id: "@2", name: "worker", pane_list: [b]}
      ]
    }
  end
end
