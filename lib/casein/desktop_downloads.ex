defmodule Casein.DesktopDownloads do
  @moduledoc """
  Operator-configured desktop installers exposed through fixed download routes.

  A configured path must be absolute and name a regular file directly. Casein
  deliberately does not scan a directory, follow symlinks, or accept a path
  from the request. A configured SHA-256 is required and verified before bytes
  are served.
  """

  @windows_filename "Casein-Setup.exe"
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @spec available_platforms() :: [map()]
  def available_platforms do
    case fetch(:windows) do
      {:ok, download} -> [Map.drop(download, [:path])]
      :error -> []
    end
  end

  @spec fetch(:windows) :: {:ok, map()} | :error
  def fetch(:windows) do
    with config when is_list(config) <- configured(:windows),
         path when is_binary(path) and path != "" <- Keyword.get(config, :path),
         :absolute <- Path.type(path),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         sha256 when is_binary(sha256) <- Keyword.get(config, :sha256),
         sha256 <- String.downcase(sha256),
         true <- Regex.match?(@sha256_pattern, sha256) do
      {:ok,
       %{
         id: :windows,
         label: "Windows",
         path: path,
         filename: @windows_filename,
         sha256: sha256,
         url: "/downloads/windows/#{@windows_filename}",
         sha256_url: "/downloads/windows/#{@windows_filename}.sha256"
       }}
    else
      _ -> :error
    end
  end

  defp configured(platform),
    do: Application.get_env(:casein, :desktop_downloads, []) |> Keyword.get(platform)
end
