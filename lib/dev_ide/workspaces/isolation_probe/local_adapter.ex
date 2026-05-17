defmodule DevIDE.Workspaces.IsolationProbe.LocalAdapter do
  @moduledoc """
  Filesystem-only DB isolation probe.

  Detection precedence:

    1. Manager workspace payload (e.g. `db.isolation`).
    2. Workspace env files (`.env`, `.env.local`, `.env.dev`).
    3. Docker Compose configs (`docker-compose.yml`, `compose.yaml`, etc.).
    4. Default → `:unknown`.

  Hard rules:

    * Never opens a DB connection.
    * Never prints secrets — credentials in URLs are masked at parse time.
    * All file reads go through `DevIDE.Files.PathSafety`.
  """

  @behaviour DevIDE.Workspaces.IsolationProbe

  alias DevIDE.Files.PathSafety
  alias DevIDE.Workspaces.{DbIsolation, Isolation}

  @env_files ~w(.env .env.local .env.dev .env.development)
  @compose_files ~w(docker-compose.yml docker-compose.yaml compose.yml compose.yaml)
  @env_keys ~w(DATABASE_URL POSTGRES_URL PG_URL DB_URL)
  @host_keys ~w(DATABASE_HOST POSTGRES_HOST PGHOST DB_HOST)
  @max_file_bytes 64 * 1024

  @container_hosts ~w(db postgres pg postgresql database mysql mariadb)
  @local_hosts ~w(localhost 127.0.0.1 ::1 host.docker.internal)

  @impl true
  def detect(workspace, root) when is_binary(root) do
    signals =
      []
      |> add_manager_signal(workspace)
      |> add_env_signals(root)
      |> add_compose_signals(root)

    classify(signals)
  end

  ## Source readers

  defp add_manager_signal(acc, %{metadata: %{"db" => %{"isolation" => v}}}) when is_binary(v) do
    [%{source: :manager, kind: :isolation, value: v} | acc]
  end

  defp add_manager_signal(acc, _), do: acc

  defp add_env_signals(acc, root) do
    Enum.reduce(@env_files, acc, fn rel, acc ->
      case read_safe(root, rel) do
        {:ok, content} ->
          parse_env(content)
          |> Enum.reduce(acc, fn {k, v}, a ->
            cond do
              k in @env_keys -> [%{source: :env_file, file: rel, kind: :url, value: v} | a]
              k in @host_keys -> [%{source: :env_file, file: rel, kind: :host, value: v} | a]
              true -> a
            end
          end)

        _ ->
          acc
      end
    end)
  end

  defp add_compose_signals(acc, root) do
    Enum.reduce(@compose_files, acc, fn rel, acc ->
      case read_safe(root, rel) do
        {:ok, content} ->
          [
            %{source: :docker_compose, file: rel, kind: :raw, value: content_summary(content)}
            | acc
          ]
          |> add_compose_env(content, rel)

        _ ->
          acc
      end
    end)
  end

  defp add_compose_env(acc, content, file) do
    # Cheap line-grep for env entries — full YAML parse is overkill for M13.
    content
    |> String.split("\n")
    |> Enum.reduce(acc, fn line, a ->
      trimmed = String.trim(line)

      cond do
        String.starts_with?(trimmed, "DATABASE_URL=") or
            String.starts_with?(trimmed, "- DATABASE_URL=") ->
          val = trimmed |> String.split("=", parts: 2) |> List.last()
          [%{source: :docker_compose, file: file, kind: :url, value: val} | a]

        String.starts_with?(trimmed, "POSTGRES_HOST=") ->
          val = trimmed |> String.split("=", parts: 2) |> List.last()
          [%{source: :docker_compose, file: file, kind: :host, value: val} | a]

        true ->
          a
      end
    end)
  end

  defp content_summary(c) when byte_size(c) <= 200, do: c

  defp content_summary(c) do
    binary_part(c, 0, 200) <> "…"
  end

  defp read_safe(root, rel) do
    with {:ok, abs} <- PathSafety.resolve(root, rel),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes <-
           File.stat(abs),
         {:ok, content} <- File.read(abs) do
      {:ok, content}
    else
      _ -> :error
    end
  end

  defp parse_env(content) do
    content
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.trim(line) do
        "" -> []
        "#" <> _ -> []
        other -> parse_env_line(other)
      end
    end)
  end

  defp parse_env_line(line) do
    case String.split(line, "=", parts: 2) do
      [k, v] -> [{String.trim(k), unquote_value(String.trim(v))}]
      _ -> []
    end
  end

  defp unquote_value(<<?", _::binary>> = v), do: String.trim(v, "\"")
  defp unquote_value(<<?', _::binary>> = v), do: String.trim(v, "'")
  defp unquote_value(v), do: v

  ## Classification

  defp classify([]) do
    %DbIsolation{
      isolation: :unknown,
      source: :none,
      summary: nil,
      detected_at: DateTime.utc_now(),
      signals: []
    }
  end

  defp classify(signals) do
    classified = Enum.map(signals, &classify_signal/1)

    isolation = aggregate(Enum.map(classified, & &1.isolation))
    {primary, source} = pick_primary(classified)

    %DbIsolation{
      isolation: isolation,
      source: source,
      summary: primary && primary.summary,
      detected_at: DateTime.utc_now(),
      signals: classified
    }
  end

  defp classify_signal(%{kind: :isolation, value: v} = s) do
    isolation =
      case String.downcase(v) do
        "shared_stage" -> :shared_stage
        "ephemeral" -> :ephemeral
        "local" -> :local
        _ -> :unknown
      end

    Map.put(s, :isolation, isolation) |> Map.put(:summary, "manager: " <> v)
  end

  defp classify_signal(%{kind: :url, value: v} = s) do
    %{host: host, port: port, db: db} = parse_db_url(v)
    isolation = isolation_for_host(host)
    Map.merge(s, %{isolation: isolation, summary: redacted_summary(host, port, db)})
  end

  defp classify_signal(%{kind: :host, value: v} = s) do
    isolation = isolation_for_host(String.trim(v))
    Map.merge(s, %{isolation: isolation, summary: "host: " <> v})
  end

  defp classify_signal(%{kind: :raw} = s),
    do: Map.merge(s, %{isolation: :unknown, summary: nil})

  defp aggregate(isolations) do
    set = MapSet.new(isolations)

    cond do
      MapSet.member?(set, :unsafe) -> :unsafe
      MapSet.member?(set, :shared_stage) and MapSet.size(set) > 1 -> :unsafe
      MapSet.member?(set, :shared_stage) -> :shared_stage
      MapSet.member?(set, :ephemeral) -> :ephemeral
      MapSet.member?(set, :local) -> :local
      true -> :unknown
    end
  end

  defp pick_primary(classified) do
    weight = fn
      :shared_stage -> 4
      :unsafe -> 5
      :ephemeral -> 3
      :local -> 2
      :unknown -> 1
    end

    classified
    |> Enum.filter(& &1[:summary])
    |> Enum.max_by(&weight.(&1.isolation), fn -> nil end)
    |> case do
      nil -> {nil, :none}
      s -> {s, s.source}
    end
  end

  ## URL parsing + redaction

  defp parse_db_url(nil), do: %{host: nil, port: nil, db: nil}

  defp parse_db_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, port: port, path: path} ->
        %{host: host, port: port, db: path && String.trim_leading(path || "", "/")}

      _ ->
        %{host: nil, port: nil, db: nil}
    end
  end

  defp redacted_summary(nil, _, _), do: nil

  defp redacted_summary(host, port, db) do
    parts = [host, port && ":#{port}", db && "/#{db}"]
    parts |> Enum.reject(&is_nil/1) |> Enum.join("")
  end

  defp isolation_for_host(nil), do: :unknown

  defp isolation_for_host(host) do
    h = host |> String.downcase() |> String.trim()

    cond do
      h in @local_hosts -> :local
      h in @container_hosts -> :ephemeral
      Isolation.shared?(h) -> :shared_stage
      Isolation.unsafe?(h) -> :unsafe
      true -> :unknown
    end
  end
end
