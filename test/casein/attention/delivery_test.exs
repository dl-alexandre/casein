defmodule Casein.Attention.DeliveryTest do
  use ExUnit.Case, async: true

  alias Casein.Attention.Delivery

  describe "delivery_decision/1" do
    test "preserves Policy focus table (post-#696 delivery_* vocabulary)" do
      assert Delivery.delivery_decision(%{
               surface_state: :hidden,
               target_state: :hidden,
               observed_working?: false
             }).reason == :cold_ready

      assert Delivery.delivery_decision(%{
               surface_state: :focused,
               target_state: :focused,
               observed_working?: true
             }) == %{
               reaction: :nothing,
               reason: :focused_target,
               surface_state: :focused,
               target_state: :focused,
               observed_working?: true
             }

      assert Delivery.delivery_reaction(%{
               surface_state: :hidden,
               target_state: :visible,
               observed_working?: true
             }) == :notify
    end
  end

  describe "window_delivery/1" do
    test "quiet window is inline chrome only" do
      assert Delivery.window_delivery(%{quiet?: true}) == :inline
      assert Delivery.window_delivery(%{quiet?: false}) == :nothing
    end
  end

  describe "session_classification/1" do
    test "idle signal is needs_you idle — not a suppress reason" do
      assert Delivery.session_classification(%{signal: :idle}) == %{
               section: :needs_you,
               reason: :idle
             }
    end
  end
end
