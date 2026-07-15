defmodule DevIDE.ReadinessTest do
  use DevIDE.DataCase, async: true

  alias DevIDE.Readiness

  test "reports ready when the configured database answers" do
    assert Readiness.status() == %{ok: true, checks: %{database: :ready}}
  end

  test "reports unavailable without exposing query errors" do
    assert Readiness.status(query: fn -> {:error, :database_details} end) == %{
             ok: false,
             checks: %{database: :unavailable}
           }
  end

  test "turns a database process exit into an unavailable result" do
    assert Readiness.status(query: fn -> exit(:noproc) end) == %{
             ok: false,
             checks: %{database: :unavailable}
           }
  end
end
