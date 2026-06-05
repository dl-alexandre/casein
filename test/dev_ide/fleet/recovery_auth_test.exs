defmodule DevIDE.Fleet.RecoveryAuthTest do
  use ExUnit.Case, async: true

  alias DevIDE.Fleet.RecoveryAuth

  @projection %{workspace_id: "ws-1"}

  test "admin can request, apply, and dismiss recovery" do
    admin = %{role: :admin, email: "admin@local", username: "admin"}

    assert RecoveryAuth.can_request_recovery?(admin, @projection)
    assert RecoveryAuth.can_apply_recovery?(admin, @projection)
    assert RecoveryAuth.can_dismiss_recovery?(admin, @projection)
    assert RecoveryAuth.can_grant_recovery?(admin)
  end

  test "non-admin cannot grant recovery" do
    refute RecoveryAuth.can_grant_recovery?(%{role: :owner, email: "dev@local"})
  end

  test "unknown actor cannot request recovery" do
    refute RecoveryAuth.can_request_recovery?(nil, @projection)
    refute RecoveryAuth.can_apply_recovery?(%{}, @projection)
  end
end
