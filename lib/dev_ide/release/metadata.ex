defmodule Casein.Release.Metadata do
  @moduledoc """
  Embedded release metadata (`releases/dev_ide.relmeta.json`).

  See `docs/lan-release-updates.md` for the v1 schema. `revision` is the update
  identity; `version` is display-only.
  """

  @metadata_version 1
  @default_app "devide"
  @default_manifest_url "https://github.com/dl-alexandre/dev_ide/releases/latest/download/devide-canary.json"

  @type t :: %{
          metadata_version: pos_integer(),
          app: String.t(),
          version: String.t(),
          revision: String.t(),
          profile: String.t(),
          repo_adapter: String.t(),
          target: String.t(),
          channel: String.t(),
          update_manifest_url: String.t(),
          built_at: String.t()
        }

  @metadata_filename "dev_ide.relmeta.json"
  @metadata_dir "releases"

  @doc "Relative path inside a release tree."
  @spec relative_path() :: String.t()
  def relative_path, do: Path.join(@metadata_dir, @metadata_filename)

  @doc "Build metadata for the current assemble step."
  @spec build_for_assemble(keyword()) :: t()
  def build_for_assemble(opts \\ []) do
    %{
      metadata_version: @metadata_version,
      app: Keyword.get(opts, :app, @default_app),
      version: Keyword.get(opts, :version, app_version()),
      revision: Keyword.get(opts, :revision, resolve_revision()),
      profile: Keyword.get(opts, :profile, env_or_default("DEVIDE_RELEASE_PROFILE", "devbox")),
      repo_adapter:
        Keyword.get(
          opts,
          :repo_adapter,
          env_or_default("DEVIDE_RELEASE_REPO_ADAPTER", default_repo_adapter())
        ),
      target:
        Keyword.get(opts, :target, env_or_default("DEVIDE_RELEASE_TARGET", default_target())),
      channel: Keyword.get(opts, :channel, env_or_default("DEVIDE_RELEASE_CHANNEL", "canary")),
      update_manifest_url:
        Keyword.get(
          opts,
          :update_manifest_url,
          env_or_default("DEVIDE_UPDATE_MANIFEST_URL", @default_manifest_url)
        ),
      built_at: Keyword.get(opts, :built_at, DateTime.utc_now() |> DateTime.to_iso8601())
    }
  end

  @doc "Write metadata into a release directory."
  @spec write!(Path.t(), t()) :: :ok
  # release_path is an operator/build-system path, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  def write!(release_path, %{} = metadata) do
    path = Path.join(release_path, relative_path())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(metadata, pretty: true) <> "\n")
    :ok
  end

  @doc "Read metadata from a release root, returning `{:ok, map}` or `{:error, reason}`."
  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  # release_root is an operator/build-system path, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  def read(release_root) when is_binary(release_root) do
    path = Path.join(release_root, relative_path())

    with {:ok, body} <- File.read(path),
         {:ok, map} <- Jason.decode(body),
         :ok <- validate(map) do
      {:ok, normalize(map)}
    else
      {:error, %Jason.DecodeError{} = err} ->
        {:error, {:invalid_json, err}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Load metadata for the active release root.

  Resolution order:
  1. `DEVIDE_RELEASE_ROOT` when set.
  2. `release-out/` under the current checkout when present.
  3. `_build/prod/rel/dev_ide` when present.
  4. Synthesized dev metadata from git + Mix version.
  """
  @spec load_current() :: {:ok, t(), Path.t()} | {:error, term()}
  def load_current do
    case locate_release_root() do
      {:ok, root} ->
        case read(root) do
          {:ok, metadata} -> {:ok, metadata, root}
          {:error, :enoent} -> {:ok, build_for_assemble(revision: resolve_revision()), root}
          {:error, reason} -> {:error, reason}
        end

      :synthesized ->
        {:ok, build_for_assemble(revision: resolve_revision(), profile: "dev"), File.cwd!()}
    end
  end

  @doc "Return the manifest URL for update checks (env override wins)."
  @spec manifest_url(t()) :: String.t()
  def manifest_url(%{update_manifest_url: url}) when is_binary(url) do
    System.get_env("DEVIDE_UPDATE_MANIFEST_URL") || url
  end

  @doc false
  @spec supported_metadata_version() :: pos_integer()
  def supported_metadata_version, do: @metadata_version

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(map) when is_map(map) do
    required =
      ~w(metadata_version app version revision profile repo_adapter target channel
         update_manifest_url built_at)

    missing = Enum.reject(required, &Map.has_key?(map, &1))

    cond do
      missing != [] ->
        {:error, {:missing_fields, missing}}

      map["metadata_version"] != @metadata_version ->
        {:error, {:unsupported_metadata_version, map["metadata_version"]}}

      not is_binary(map["revision"]) or map["revision"] == "" ->
        {:error, :missing_revision}

      true ->
        :ok
    end
  end

  defp normalize(map) do
    %{
      metadata_version: map["metadata_version"],
      app: map["app"],
      version: map["version"],
      revision: map["revision"],
      profile: map["profile"],
      repo_adapter: map["repo_adapter"],
      target: map["target"],
      channel: map["channel"],
      update_manifest_url: map["update_manifest_url"],
      built_at: map["built_at"]
    }
  end

  defp locate_release_root do
    candidates =
      [
        System.get_env("DEVIDE_RELEASE_ROOT"),
        Path.join(File.cwd!(), "release-out"),
        Path.join(File.cwd!(), "_build/prod/rel/dev_ide")
      ]
      |> Enum.reject(&is_nil/1)

    case Enum.find_value(candidates, &existing_dir/1) do
      nil -> :synthesized
      root -> {:ok, root}
    end
  end

  defp existing_dir(path) do
    expanded = Path.expand(path)
    if File.dir?(expanded), do: expanded
  end

  defp resolve_revision do
    System.get_env("DEVIDE_GIT_REVISION") ||
      case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
        {sha, 0} -> String.trim(sha)
        _ -> "unknown"
      end
  end

  defp app_version do
    Mix.Project.config()[:version] |> to_string()
  rescue
    _ -> "0.0.0"
  end

  defp default_target do
    case :os.type() do
      {:unix, :linux} -> "linux-" <> normalize_arch(:erlang.system_info(:system_architecture))
      {:unix, :darwin} -> "darwin-" <> normalize_arch(:erlang.system_info(:system_architecture))
      {:win32, _} -> "windows-" <> normalize_arch(:erlang.system_info(:system_architecture))
      _ -> "unknown"
    end
  end

  defp normalize_arch(arch) when is_list(arch), do: normalize_arch(List.to_string(arch))

  defp normalize_arch(arch) when is_binary(arch) do
    cond do
      String.starts_with?(arch, "x86_64") -> "x86_64"
      String.starts_with?(arch, "aarch64") -> "aarch64"
      true -> arch |> String.split("-") |> List.first() |> String.downcase()
    end
  end

  defp default_repo_adapter do
    env_or_default("DEV_IDE_REPO_ADAPTER", "postgres")
  end

  defp env_or_default(var, default) do
    case System.get_env(var) do
      nil -> default
      "" -> default
      value -> value
    end
  end
end
