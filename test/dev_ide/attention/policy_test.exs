defmodule Casein.Attention.PolicyTest do
  use Casein.TestCase, async: true

  alias Casein.Attention.Policy

  describe "surface_state/1" do
    test "normalizes client state strings" do
      assert Policy.surface_state("focused") == :focused
      assert Policy.surface_state("visible") == :visible
      assert Policy.surface_state("hidden") == :hidden
      assert Policy.surface_state("unknown") == :unknown
      assert Policy.surface_state("other") == :unknown
    end
  end

  describe "quiet_agent_transition/1" do
    test "keeps a focused current target silent" do
      assert Policy.quiet_agent_transition(%{
               surface_state: :focused,
               target_state: :focused,
               observed_working?: true
             }) == :nothing
    end

    test "uses inline chrome while the workspace is focused" do
      assert Policy.quiet_agent_transition(%{
               surface_state: :focused,
               target_state: :visible,
               observed_working?: true
             }) == :inline
    end

    test "notifies when the browser surface is no longer focused" do
      for surface <- [:visible, :hidden, :unknown] do
        assert Policy.quiet_agent_transition(%{
                 surface_state: surface,
                 target_state: :visible,
                 observed_working?: true
               }) == :notify
      end
    end

    test "cold ready windows never notify" do
      assert Policy.quiet_agent_transition(%{
               surface_state: :hidden,
               target_state: :hidden,
               observed_working?: false
             }) == :inline
    end
  end

  describe "quiet_agent_decision/1" do
    test "returns normalized inputs and the reason behind the reaction" do
      assert %{
               reaction: :inline,
               reason: :focused_workspace,
               surface_state: :focused,
               target_state: :visible,
               observed_working?: true
             } =
               Policy.quiet_agent_decision(%{
                 surface_state: "focused",
                 target_state: "visible",
                 observed_working?: true
               })
    end

    test "labels cold ready windows separately from focused inline routing" do
      assert %{reaction: :inline, reason: :cold_ready, observed_working?: false} =
               Policy.quiet_agent_decision(%{
                 surface_state: :focused,
                 target_state: :visible,
                 observed_working?: false
               })
    end
  end

  describe "quiet_agent_window/1" do
    test "maps quiet windows to inline attention" do
      assert Policy.quiet_agent_window(%{quiet?: true}) == :inline
      assert Policy.quiet_agent_window(%{quiet?: false}) == :nothing
    end
  end
end
