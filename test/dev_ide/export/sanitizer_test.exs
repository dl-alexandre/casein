defmodule DevIDE.Export.SanitizerTest do
  use DevIDE.TestCase, async: true
  alias DevIDE.Export.Sanitizer

  test "strips top-level secret keys regardless of case" do
    map = %{
      "DATABASE_URL" => "postgres://u:p@x/y",
      "Password" => "hunter2",
      "secret" => "shh",
      "name" => "alpha"
    }

    out = Sanitizer.scrub(map)
    refute Map.has_key?(out, "DATABASE_URL")
    refute Map.has_key?(out, "Password")
    refute Map.has_key?(out, "secret")
    assert out["name"] == "alpha"
  end

  test "scrubs nested maps recursively" do
    map = %{"meta" => %{"db" => %{"password" => "p", "host" => "h"}}}
    out = Sanitizer.scrub(map)
    assert out["meta"]["db"] == %{"host" => "h"}
  end

  test "redacts credential entries inside env arrays" do
    map = %{"env" => ["FOO=bar", "POSTGRES_PASSWORD=hunter2", "DATABASE_URL=postgres://u:p@x"]}
    out = Sanitizer.scrub(map)
    env = out["env"]
    assert "FOO=bar" in env
    assert Enum.any?(env, &String.contains?(&1, "[REDACTED]"))
    refute Enum.any?(env, &String.contains?(&1, "hunter2"))
    refute Enum.any?(env, &String.contains?(&1, "postgres://u:p"))
  end

  test "atom keys are also recognized" do
    out = Sanitizer.scrub(%{password: "p", name: "alpha"})
    refute Map.has_key?(out, :password)
    assert out[:name] == "alpha"
  end

  test "passes through non-map non-list values unchanged" do
    assert Sanitizer.scrub(42) == 42
    assert Sanitizer.scrub("hello") == "hello"
    assert Sanitizer.scrub(nil) == nil
  end

  test "passes timestamp structs through as scalar values" do
    timestamp = ~U[2026-06-29 12:01:00Z]

    assert Sanitizer.scrub(%{metadata: %{seen_at: timestamp, token: "secret"}}) == %{
             metadata: %{seen_at: timestamp}
           }
  end

  test "scrubs arbitrary structs recursively instead of passing them through" do
    struct = %DevIDE.TestSupport.ExportSecretStruct{
      name: "visible",
      token: "secret",
      nested: %{"password" => "hidden", "host" => "localhost"}
    }

    assert Sanitizer.scrub(%{metadata: struct}) == %{
             metadata: %{name: "visible", nested: %{"host" => "localhost"}}
           }
  end
end
