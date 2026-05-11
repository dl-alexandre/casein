defmodule DevIDE.Workspaces.IsolationTest do
  use ExUnit.Case, async: false

  alias DevIDE.Workspaces.{Isolation, IsolationProbe.LocalAdapter}

  setup do
    root = Path.join(System.tmp_dir!(), "iso-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev_shared = Application.get_env(:dev_ide, :shared_db_patterns)
    prev_unsafe = Application.get_env(:dev_ide, :unsafe_db_patterns)

    Application.put_env(:dev_ide, :shared_db_patterns, ["stage.rds.amazonaws.com", "stage-db."])
    Application.put_env(:dev_ide, :unsafe_db_patterns, ["prod-db.", ".prod.rds.amazonaws.com"])

    on_exit(fn ->
      File.rm_rf!(root)
      restore(:shared_db_patterns, prev_shared)
      restore(:unsafe_db_patterns, prev_unsafe)
    end)

    {:ok, root: root}
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)

  test "no signals -> :unknown / :none source", %{root: root} do
    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :unknown
    assert iso.source == :none
    assert is_nil(iso.summary)
    assert %DateTime{} = iso.detected_at
  end

  test "DATABASE_URL pointing at known stage host -> :shared_stage", %{root: root} do
    File.write!(
      Path.join(root, ".env"),
      ~s|DATABASE_URL=postgres://user:secret@stage.rds.amazonaws.com:5432/app\n|
    )

    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :shared_stage
    assert iso.source == :env_file
    refute iso.summary =~ "secret"
    refute iso.summary =~ "user"
    assert iso.summary =~ "stage.rds.amazonaws.com"
  end

  test "DATABASE_URL pointing at localhost -> :local", %{root: root} do
    File.write!(Path.join(root, ".env"), ~s|DATABASE_URL=postgres://x:y@localhost:5432/app\n|)
    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :local
    refute iso.summary =~ "y"
  end

  test "DATABASE_URL pointing at compose service name -> :ephemeral", %{root: root} do
    File.write!(Path.join(root, ".env"), ~s|DATABASE_URL=postgres://x:y@db:5432/app\n|)
    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :ephemeral
  end

  test "production-looking host -> :unsafe", %{root: root} do
    File.write!(
      Path.join(root, ".env"),
      ~s|DATABASE_URL=postgres://x:y@prod-db.example.com:5432/app\n|
    )

    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :unsafe
  end

  test "conflicting stage + local signals -> :unsafe", %{root: root} do
    File.write!(Path.join(root, ".env"), """
    DATABASE_URL=postgres://x:y@stage.rds.amazonaws.com:5432/app
    """)

    File.write!(Path.join(root, ".env.local"), """
    DATABASE_URL=postgres://x:y@localhost:5432/app
    """)

    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :unsafe
  end

  test "manager metadata wins as a precedence signal", %{root: root} do
    iso =
      LocalAdapter.detect(
        %{raw: %{"db" => %{"isolation" => "ephemeral"}}},
        root
      )

    assert iso.isolation == :ephemeral
    assert iso.source == :manager
  end

  test "shared?/unsafe? respect configured patterns" do
    assert Isolation.shared?("stage.rds.amazonaws.com")
    assert Isolation.shared?("STAGE.RDS.AMAZONAWS.COM")
    refute Isolation.shared?("dev.example.com")

    assert Isolation.unsafe?("prod-db.example.com")
    refute Isolation.unsafe?("stage.rds.amazonaws.com")
  end

  test "non-binary host is not considered shared/unsafe" do
    refute Isolation.shared?("")
    refute Isolation.unsafe?("")
  end
end
