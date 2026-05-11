defmodule DevIDE.Agents.LocalAdapter do
  @moduledoc """
  Filesystem-based detection of agent capabilities for a workspace. All path
  access goes through `DevIDE.Files.PathSafety` so traversal/symlink-escape
  cannot reach the disk through this adapter.

  This module is intentionally read-only: it inspects, never starts.
  """

  @behaviour DevIDE.Agents

  alias DevIDE.Agents.{Capability, Artifact, ReviewCommand}
  alias DevIDE.Files.PathSafety

  @opencode_markers [".opencode", "opencode.json", "opencode.jsonc"]
  @fff_markers [".fff", "fff-mcp.json"]
  @browser_dirs ~w(screenshots downloads traces profiles)
  @browser_roots [".agent", ".opencode/.agent"]
  @transcript_dirs [".opencode/sessions", ".opencode/logs"]
  @max_transcripts 20

  @impl true
  def detect(root, manager_workspace \\ nil) when is_binary(root) do
    [
      detect_opencode(root),
      detect_tidewave(manager_workspace),
      detect_fff(root),
      detect_browser(root)
    ]
  end

  @impl true
  def review_commands(caps) when is_list(caps) do
    Enum.filter(ReviewCommand.all(), &ReviewCommand.available?(&1, caps))
  end

  @impl true
  def transcripts(root) when is_binary(root) do
    @transcript_dirs
    |> Enum.flat_map(fn d -> safe_list(root, d) end)
    |> Enum.sort_by(& &1.mtime, {:desc, NaiveDateTime})
    |> Enum.take(@max_transcripts)
  end

  ## Detection

  defp detect_opencode(root) do
    case first_existing(root, @opencode_markers) do
      {:ok, rel, abs, stat} ->
        %Capability{
          kind: :opencode,
          status: :detected,
          source: :workspace_fs,
          path: rel,
          mtime: erl_to_naive(stat.mtime),
          details: %{absolute: abs}
        }

      :missing ->
        %Capability{kind: :opencode, status: :missing}
    end
  end

  defp detect_tidewave(%{ports: %{"tidewave" => port}, domain_base: domain})
       when is_integer(port) and is_binary(domain) do
    %Capability{
      kind: :tidewave,
      status: :detected,
      source: :manager,
      url: "https://tidewave.#{domain}",
      details: %{port: port}
    }
  end

  defp detect_tidewave(%{type: :v3, domain_base: domain}) when is_binary(domain) do
    %Capability{
      kind: :tidewave,
      status: :detected,
      source: :manager,
      url: "https://tidewave.#{domain}",
      details: %{inferred: true}
    }
  end

  defp detect_tidewave(_), do: %Capability{kind: :tidewave, status: :missing}

  defp detect_fff(root) do
    case first_existing(root, @fff_markers) do
      {:ok, rel, abs, stat} ->
        %Capability{
          kind: :fff,
          status: :detected,
          source: :workspace_fs,
          path: rel,
          mtime: erl_to_naive(stat.mtime),
          details: %{absolute: abs}
        }

      :missing ->
        %Capability{kind: :fff, status: :missing}
    end
  end

  defp detect_browser(root) do
    Enum.find_value(@browser_roots, %Capability{kind: :browser_artifacts, status: :missing}, fn
      base ->
        case PathSafety.resolve(root, base) do
          {:ok, abs} ->
            case File.stat(abs) do
              {:ok, %File.Stat{type: :directory, mtime: mt}} ->
                present = Enum.filter(@browser_dirs, &File.dir?(Path.join(abs, &1)))

                if present == [] do
                  nil
                else
                  %Capability{
                    kind: :browser_artifacts,
                    status: :detected,
                    source: :workspace_fs,
                    path: base,
                    mtime: erl_to_naive(mt),
                    details: %{subdirs: present, absolute: abs}
                  }
                end

              _ ->
                nil
            end

          _ ->
            nil
        end
    end)
  end

  ## Helpers

  defp first_existing(root, candidates) do
    Enum.find_value(candidates, :missing, fn rel ->
      with {:ok, abs} <- PathSafety.resolve(root, rel),
           {:ok, stat} <- File.stat(abs) do
        {:ok, rel, abs, stat}
      else
        _ -> nil
      end
    end)
  end

  defp safe_list(root, rel) do
    with {:ok, abs} <- PathSafety.resolve(root, rel),
         {:ok, %File.Stat{type: :directory}} <- File.stat(abs),
         {:ok, names} <- File.ls(abs) do
      names
      |> Enum.flat_map(fn name -> stat_artifact(abs, rel, name) end)
    else
      _ -> []
    end
  end

  defp stat_artifact(abs, rel, name) do
    full = Path.join(abs, name)

    case File.stat(full) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mt}} ->
        [
          %Artifact{
            rel_path: Path.join(rel, name),
            name: name,
            size: size,
            mtime: erl_to_naive(mt)
          }
        ]

      _ ->
        []
    end
  end

  defp erl_to_naive({{y, mo, d}, {h, mi, s}}) do
    case NaiveDateTime.new(y, mo, d, h, mi, s) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp erl_to_naive(_), do: nil
end
