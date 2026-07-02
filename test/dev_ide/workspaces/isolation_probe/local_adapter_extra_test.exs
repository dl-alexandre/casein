defmodule DevIDE.Workspaces.IsolationProbe.LocalAdapterExtraTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Workspaces.IsolationProbe.LocalAdapter

  # Mirrors isolation_test.exs: a real temp dir holds crafted env/compose
  # files, and the shared/unsafe host patterns are configured per-run so the
  # classification arms are deterministic.
  setup do
    root = Path.join(System.tmp_dir!(), "iso-extra-#{System.unique_integer([:positive])}")
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

  ## Manager-signal classification arms

  test "manager isolation \"shared_stage\" classifies as :shared_stage", %{root: root} do
    iso = LocalAdapter.detect(%{metadata: %{"db" => %{"isolation" => "shared_stage"}}}, root)
    assert iso.isolation == :shared_stage
    assert iso.source == :manager
    assert iso.summary == "manager: shared_stage"
  end

  test "manager isolation \"local\" classifies as :local", %{root: root} do
    iso = LocalAdapter.detect(%{metadata: %{"db" => %{"isolation" => "local"}}}, root)
    assert iso.isolation == :local
    assert iso.source == :manager
    assert iso.summary == "manager: local"
  end

  test "manager isolation is case-insensitive", %{root: root} do
    iso = LocalAdapter.detect(%{metadata: %{"db" => %{"isolation" => "EPHEMERAL"}}}, root)
    assert iso.isolation == :ephemeral
    assert iso.summary == "manager: EPHEMERAL"
  end

  test "unrecognized manager isolation string -> :unknown but still a manager signal",
       %{root: root} do
    iso = LocalAdapter.detect(%{metadata: %{"db" => %{"isolation" => "weird-value"}}}, root)
    assert iso.isolation == :unknown
    assert iso.source == :manager
    assert iso.summary == "manager: weird-value"
  end

  test "manager metadata with non-binary isolation is ignored (falls through)", %{root: root} do
    # value is an integer, not binary -> add_manager_signal/2 catch-all clause.
    iso = LocalAdapter.detect(%{metadata: %{"db" => %{"isolation" => 1}}}, root)
    assert iso.isolation == :unknown
    assert iso.source == :none
    assert iso.signals == []
  end

  test "metadata without the db/isolation shape is ignored", %{root: root} do
    iso = LocalAdapter.detect(%{metadata: %{"unrelated" => true}}, root)
    assert iso.isolation == :unknown
    assert iso.source == :none
  end

  ## Alternate env URL keys

  test "POSTGRES_URL is treated as a DATABASE_URL signal", %{root: root} do
    File.write!(Path.join(root, ".env"), ~s|POSTGRES_URL=postgres://x:y@localhost:5432/app\n|)
    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :local
    assert iso.source == :env_file
  end

  test "DB_URL pointing at a container service name -> :ephemeral", %{root: root} do
    File.write!(Path.join(root, ".env"), ~s|DB_URL=postgres://x:y@postgres:5432/app\n|)
    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :ephemeral
  end

  ## Host-key (kind: :host) classification

  test "DATABASE_HOST env key produces a host signal and redacted summary", %{root: root} do
    File.write!(Path.join(root, ".env"), ~s|DATABASE_HOST=localhost\n|)
    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :local
    assert iso.source == :env_file
    assert iso.summary == "host: localhost"
  end

  test "PGHOST pointing at a stage host -> :shared_stage via host signal", %{root: root} do
    File.write!(Path.join(root, ".env"), ~s|PGHOST=stage.rds.amazonaws.com\n|)
    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :shared_stage
    assert iso.summary == "host: stage.rds.amazonaws.com"
  end

  ## Env parsing helpers: comments, blanks, quoting, malformed lines

  test "comments, blank lines, quoted values and junk lines are parsed correctly",
       %{root: root} do
    File.write!(Path.join(root, ".env"), """
    # a comment line

    NOT_A_DB_KEY=ignored
    JUST_A_FLAG
    DATABASE_URL="postgres://u:p@localhost:5432/app"
    """)

    iso = LocalAdapter.detect(%{}, root)
    # Quoted URL is unquoted before parsing, host -> localhost.
    assert iso.isolation == :local
    assert iso.source == :env_file
    refute iso.summary =~ "\""
  end

  test "single-quoted DATABASE_URL is unquoted", %{root: root} do
    File.write!(
      Path.join(root, ".env"),
      ~s|DATABASE_URL='postgres://u:p@stage.rds.amazonaws.com:5432/app'\n|
    )

    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :shared_stage
    refute iso.summary =~ "'"
    assert iso.summary =~ "stage.rds.amazonaws.com"
  end

  ## URL shapes: sqlite (empty host) keeps a summary; empty value (nil host) drops it

  test "sqlite URL (empty host) yields :unknown but keeps a path-only summary", %{root: root} do
    # URI.parse returns host "" (not nil) for sqlite:///..., so the url signal
    # classifies :unknown yet still carries a credential-free, path-only summary.
    File.write!(Path.join(root, ".env"), ~s|DATABASE_URL=sqlite:///priv/repo/dev.sqlite3\n|)
    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :unknown
    assert iso.source == :env_file
    assert iso.summary == "/priv/repo/dev.sqlite3"
    assert [%{kind: :url}] = iso.signals
  end

  test "empty DATABASE_URL value (nil host) yields :unknown with no summary", %{root: root} do
    File.write!(Path.join(root, ".env"), ~s|DATABASE_URL=\n|)
    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :unknown
    assert iso.source == :none
    assert is_nil(iso.summary)
  end

  ## Redacted summary includes db name and port for a localhost URL

  test "redacted summary keeps host:port/db but drops credentials", %{root: root} do
    File.write!(
      Path.join(root, ".env"),
      ~s|DATABASE_URL=postgres://admin:s3cr3t@localhost:5433/mydb\n|
    )

    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :local
    assert iso.summary == "localhost:5433/mydb"
    refute iso.summary =~ "admin"
    refute iso.summary =~ "s3cr3t"
  end

  test "url without port or db path is summarized as host only", %{root: root} do
    File.write!(Path.join(root, ".env"), ~s|DATABASE_URL=postgres://u:p@localhost\n|)
    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :local
    assert iso.summary == "localhost"
  end

  ## Unknown host classification arm

  test "unrecognized host -> :unknown isolation", %{root: root} do
    File.write!(Path.join(root, ".env"), ~s|DATABASE_HOST=some.random.internal\n|)
    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :unknown
    # Host signal still carries a summary, so source is env_file (not :none).
    assert iso.source == :env_file
    assert iso.summary == "host: some.random.internal"
  end

  ## Docker Compose source: raw summary + inline env grep

  test "compose file with DATABASE_URL line is detected", %{root: root} do
    File.write!(Path.join(root, "docker-compose.yml"), """
    services:
      web:
        environment:
          - DATABASE_URL=postgres://x:y@db:5432/app
    """)

    iso = LocalAdapter.detect(%{}, root)
    # The inline `- DATABASE_URL=...@db...` resolves to a container host.
    assert iso.isolation == :ephemeral
    assert iso.source == :docker_compose
  end

  test "compose file with bare DATABASE_URL= and POSTGRES_HOST= lines", %{root: root} do
    File.write!(Path.join(root, "compose.yaml"), """
    DATABASE_URL=postgres://x:y@localhost:5432/app
    POSTGRES_HOST=db
    """)

    iso = LocalAdapter.detect(%{}, root)
    # localhost (:local) and db (:ephemeral) both present, no unsafe/shared ->
    # aggregate prefers :ephemeral over :local.
    assert iso.isolation == :ephemeral
    assert iso.source == :docker_compose
  end

  test "compose-only file with no recognizable env yields a raw signal and :unknown",
       %{root: root} do
    File.write!(Path.join(root, "docker-compose.yaml"), """
    services:
      app:
        image: myapp:latest
    """)

    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :unknown
    # Only a raw signal (nil summary) -> pick_primary -> {nil, :none}.
    assert iso.source == :none
    assert is_nil(iso.summary)
    assert Enum.any?(iso.signals, &(&1.kind == :raw))
  end

  test "raw compose summary is truncated past 200 bytes with an ellipsis", %{root: root} do
    big = "services:\n  app:\n    image: x\n    # " <> String.duplicate("z", 400) <> "\n"
    File.write!(Path.join(root, "compose.yml"), big)

    iso = LocalAdapter.detect(%{}, root)
    raw = Enum.find(iso.signals, &(&1.kind == :raw))
    assert raw
    assert String.ends_with?(raw.value, "…")
    # 200 content bytes + the multibyte ellipsis.
    assert byte_size(raw.value) == 200 + byte_size("…")
  end

  test "short compose content is summarized verbatim (no ellipsis)", %{root: root} do
    short = "POSTGRES_HOST=localhost\n"
    File.write!(Path.join(root, "compose.yml"), short)

    iso = LocalAdapter.detect(%{}, root)
    raw = Enum.find(iso.signals, &(&1.kind == :raw))
    assert raw
    assert raw.value == short
    refute String.ends_with?(raw.value, "…")
    # POSTGRES_HOST=localhost -> :local
    assert iso.isolation == :local
  end

  ## read_safe guards: oversized and non-regular files are skipped

  test "an oversized env file is skipped (no signal)", %{root: root} do
    # > 64 KiB so the File.Stat size guard rejects it.
    padding = String.duplicate("# pad\n", 12_000)

    File.write!(
      Path.join(root, ".env"),
      "DATABASE_URL=postgres://x:y@stage.rds.amazonaws.com:5432/app\n" <> padding
    )

    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :unknown
    assert iso.source == :none
    assert iso.signals == []
  end

  test "a directory in place of an env file is skipped (non-regular)", %{root: root} do
    File.mkdir_p!(Path.join(root, ".env"))
    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :unknown
    assert iso.source == :none
    assert iso.signals == []
  end

  ## Aggregation precedence across multiple env files

  test "ephemeral + unknown signals aggregate to :ephemeral", %{root: root} do
    File.write!(Path.join(root, ".env"), ~s|DATABASE_URL=postgres://x:y@db:5432/app\n|)
    File.write!(Path.join(root, ".env.local"), ~s|DATABASE_HOST=some.random.internal\n|)

    iso = LocalAdapter.detect(%{}, root)
    assert iso.isolation == :ephemeral
  end
end
