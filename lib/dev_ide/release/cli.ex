defmodule Casein.Release.CLI do
  @moduledoc """
  Operator CLI entrypoints for LAN release metadata and update checks.

  Invoked from `scripts/devide` (checkout) and `bin/devide` (release) — see
  `docs/lan-release-updates.md`.
  """

  alias Casein.Release.Metadata
  alias Casein.Release.Update.Check

  @doc "Run CLI argv and return an exit code."
  @spec main([String.t()]) :: non_neg_integer()
  def main(argv \\ argv_from_env()) do
    case argv do
      ["version" | rest] ->
        print_version(rest)
        0

      ["update", "check" | rest] ->
        case print_update_check(rest) do
          :error -> 1
          _ -> 0
        end

      _ ->
        IO.puts(:stderr, usage())
        2
    end
  end

  @doc "Decode base64 NUL-separated argv (release `bin/devide` transport)."
  @spec main_base64(String.t()) :: non_neg_integer()
  def main_base64(encoded) when is_binary(encoded) do
    argv =
      encoded
      |> Base.decode64!()
      |> decode_argv_transport()

    main(argv)
  end

  @spec print_version([String.t()]) :: :ok
  def print_version(argv) do
    json? = "--json" in argv

    case Metadata.load_current() do
      {:ok, metadata, _root} ->
        if json? do
          IO.puts(Jason.encode!(version_payload(metadata), pretty: true))
        else
          IO.puts(format_version(metadata))
        end

      {:error, reason} ->
        if json? do
          IO.puts(Jason.encode!(%{error: format_error(reason)}))
        else
          IO.puts(:stderr, "error: #{format_error(reason)}")
        end
    end
  end

  @spec print_update_check([String.t()]) :: Check.status()
  def print_update_check(argv) do
    json? = "--json" in argv
    result = Check.run()

    if json? do
      IO.puts(Jason.encode!(check_payload(result), pretty: true))
    else
      IO.puts(format_check(result))
    end

    result.status
  end

  defp version_payload(metadata) do
    %{
      app: metadata.app,
      version: metadata.version,
      revision: metadata.revision,
      profile: metadata.profile,
      repo_adapter: metadata.repo_adapter,
      target: metadata.target,
      channel: metadata.channel,
      update_manifest_url: metadata.update_manifest_url,
      built_at: metadata.built_at,
      metadata_version: metadata.metadata_version
    }
  end

  defp check_payload(%{status: status, current: current, available: available} = result) do
    %{
      status: Atom.to_string(status),
      message: result.message,
      manifest_url: result.manifest_url,
      current: current && version_payload(current),
      available: available && artifact_payload(available)
    }
  end

  defp artifact_payload(artifact) do
    %{
      app: artifact.app,
      version: artifact.version,
      revision: artifact.revision,
      profile: artifact.profile,
      repo_adapter: artifact.repo_adapter,
      target: artifact.target,
      url: artifact.url,
      sha256: artifact.sha256,
      size: artifact.size,
      changelog_url: artifact.changelog_url
    }
  end

  defp format_version(metadata) do
    "#{metadata.app} #{metadata.version} (#{short_revision(metadata.revision)}) #{metadata.profile}/#{metadata.target} #{metadata.channel}"
  end

  defp format_check(%{status: :current} = result) do
    current = result.current

    """
    current: #{short_revision(current.revision)} (#{current.version})
    channel: #{current.channel}
    status:  up to date
    """
    |> String.trim()
  end

  defp format_check(%{status: :update_available} = result) do
    current = result.current
    available = result.available

    """
    current:   #{short_revision(current.revision)} (#{current.version})
    available: #{short_revision(available.revision)} (#{available.version})
    channel:   #{result.manifest.channel}
    install:   sudo devide update install
    """
    |> String.trim()
  end

  defp format_check(%{status: :error} = result) do
    "error: #{result.message}"
  end

  defp short_revision(revision) when is_binary(revision) do
    String.slice(revision, 0, 7)
  end

  defp format_error(reason), do: inspect(reason)

  defp argv_from_env do
    case System.get_env("DEVIDE_CLI_ARGV") do
      nil -> System.argv()
      raw -> decode_argv_transport(raw)
    end
  end

  defp decode_argv_transport(raw) when is_binary(raw) do
    if String.contains?(raw, <<0>>) do
      String.split(raw, <<0>>, trim: true)
    else
      String.split(raw, "\n", trim: true)
    end
  end

  defp usage do
    """
    Usage:
      devide version [--json]
      devide update check [--json]
    """
    |> String.trim()
  end
end
