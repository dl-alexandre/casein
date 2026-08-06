defmodule Casein.DesktopDownloads do
  @moduledoc """
  Operator-configured desktop installers exposed through fixed download routes.

  A configured path must be absolute and name a regular file directly. Casein
  deliberately does not scan a directory, follow symlinks, or accept a path
  from the request. A configured SHA-256 is required and is verified against
  the file's bytes before the download is offered.

  Verification streams the file in chunks and memoizes its verdict per distinct
  `{path, sha256, size, mtime}`, so serving a request never reads the installer
  into memory and a rejected configuration is logged once rather than per
  request.
  """

  require Logger

  @windows_filename "Casein-Setup.exe"
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @chunk_bytes 65_536
  @cache_key {__MODULE__, :verification}

  @type download :: %{
          id: :windows,
          label: String.t(),
          path: String.t(),
          filename: String.t(),
          sha256: String.t(),
          size: non_neg_integer(),
          url: String.t(),
          sha256_url: String.t()
        }

  @doc """
  Platforms with a verified installer, without the on-disk path.

  Safe to place in a socket assign: the filesystem location never reaches the
  client.
  """
  @spec available_platforms() :: [map()]
  def available_platforms do
    case fetch(:windows) do
      {:ok, download} -> [Map.drop(download, [:path])]
      :error -> []
    end
  end

  @doc """
  The verified download for `platform`, or `:error` when none is offered.

  Returns `:error` for every failure — unconfigured, malformed, missing, or
  hash mismatch — so callers cannot distinguish them; the reason is logged.
  """
  @spec fetch(:windows) :: {:ok, download()} | :error
  def fetch(:windows) do
    config = Application.get_env(:casein, :desktop_downloads, []) |> platform_config(:windows)

    case config_value(config, :path) do
      # Not configured at all: the feature is simply off, which is not a fault.
      nil -> :error
      path -> resolve({path, configured_sha256(config), signature(path)})
    end
  end

  defp platform_config(config, platform) when is_list(config), do: Keyword.get(config, platform)
  defp platform_config(_config, _platform), do: nil

  defp config_value(config, key) when is_list(config) do
    case Keyword.get(config, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp config_value(_config, _key), do: nil

  defp configured_sha256(config) do
    case config_value(config, :sha256) do
      nil -> nil
      sha256 -> String.downcase(sha256)
    end
  end

  # lstat/1 does not follow a final symlink, so a symlinked path reports
  # :symlink here and is refused rather than silently resolved.
  defp signature(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} -> {:regular, size, mtime}
      {:ok, %File.Stat{type: type}} -> {:not_regular, type}
      {:error, reason} -> {:unreadable, reason}
    end
  end

  defp resolve(key) do
    case :persistent_term.get(@cache_key, nil) do
      {^key, verdict} ->
        verdict

      _ ->
        verdict = verify(key)
        :persistent_term.put(@cache_key, {key, verdict})
        verdict
    end
  end

  defp verify({path, sha256, signature}) do
    cond do
      is_nil(sha256) ->
        refuse(path, "no SHA-256 is configured (set CASEIN_WINDOWS_DOWNLOAD_SHA256)")

      not Regex.match?(@sha256_pattern, sha256) ->
        refuse(path, "configured SHA-256 must be 64 hexadecimal characters")

      Path.type(path) != :absolute ->
        refuse(path, "configured path must be absolute")

      true ->
        verify_bytes(path, sha256, signature)
    end
  end

  defp verify_bytes(path, sha256, {:regular, size, _mtime}) do
    case stream_sha256(path) do
      {:ok, ^sha256} ->
        {:ok,
         %{
           id: :windows,
           label: "Windows",
           path: path,
           filename: @windows_filename,
           sha256: sha256,
           size: size,
           url: "/downloads/windows/#{@windows_filename}",
           sha256_url: "/downloads/windows/#{@windows_filename}.sha256"
         }}

      {:ok, actual} ->
        refuse(path, "SHA-256 mismatch: configured #{sha256}, file is #{actual}")

      {:error, reason} ->
        refuse(path, "could not be read (#{format_error(reason)})")
    end
  end

  defp verify_bytes(path, _sha256, {:not_regular, type}),
    do: refuse(path, "is a #{type}, not a regular file")

  defp verify_bytes(path, _sha256, {:unreadable, reason}),
    do: refuse(path, "could not be inspected (#{format_error(reason)})")

  defp refuse(path, reason) do
    Logger.warning("Desktop download at #{path} is not being served: #{reason}")
    :error
  end

  # Chunked so verifying a large installer never allocates it whole.
  defp stream_sha256(path) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          digest(io, :crypto.hash_init(:sha256))
        after
          :file.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp digest(io, state) do
    case :file.read(io, @chunk_bytes) do
      {:ok, chunk} -> digest(io, :crypto.hash_update(state, chunk))
      :eof -> {:ok, state |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_error(reason), do: reason |> :file.format_error() |> List.to_string()
end
