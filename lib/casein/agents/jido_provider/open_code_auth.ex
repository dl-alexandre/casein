defmodule Casein.Agents.JidoProvider.OpenCodeAuth do
  @moduledoc """
  Resolves OpenCode's existing Zen credential without copying or caching it.

  OpenCode reads `OPENCODE_AUTH_CONTENT` first. When that value is absent or is
  not JSON, it reads `auth.json` from its XDG data directory. This module follows
  the same order and extracts only the `opencode` API record.

  The returned key is intentionally short-lived caller data. This module never
  logs it, places it in application configuration, or includes source contents
  in errors.
  """

  @provider_id "opencode"

  @type reason ::
          :credential_not_found
          | :credential_invalid
          | :credential_type_unsupported
          | :credential_source_unavailable
          | :credential_unreadable

  @spec fetch_api_key() :: {:ok, String.t()} | {:error, reason()}
  def fetch_api_key do
    case System.get_env("OPENCODE_AUTH_CONTENT") do
      nil -> fetch_file_api_key()
      content -> fetch_content_or_file_api_key(content)
    end
  end

  defp fetch_content_or_file_api_key(content) when is_binary(content) do
    case decode_api_key(content) do
      {:error, :credential_invalid} -> fetch_file_api_key()
      result -> result
    end
  end

  defp fetch_file_api_key do
    with {:ok, path} <- auth_path(),
         {:ok, content} <- read_auth_file(path) do
      decode_api_key(content)
    end
  end

  defp auth_path do
    case default_auth_path() do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :credential_source_unavailable}
    end
  end

  defp default_auth_path do
    case absolute_env("XDG_DATA_HOME") do
      nil -> default_home_auth_path()
      data_home -> Path.join([data_home, "opencode", "auth.json"])
    end
  end

  defp default_home_auth_path do
    case absolute_env("HOME") do
      nil -> nil
      home -> Path.join([home, ".local", "share", "opencode", "auth.json"])
    end
  end

  defp absolute_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        if Path.type(value) == :absolute, do: value

      _ ->
        nil
    end
  end

  # The path is assembled only from trusted process XDG/HOME environment roots;
  # callers cannot provide a filesystem path.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_auth_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :credential_not_found}
      {:error, _reason} -> {:error, :credential_unreadable}
    end
  end

  defp decode_api_key(content) do
    with {:ok, records} when is_map(records) <- Jason.decode(content) do
      extract_api_key(Map.get(records, @provider_id))
    else
      _ -> {:error, :credential_invalid}
    end
  end

  defp extract_api_key(%{"type" => "api", "key" => key})
       when is_binary(key) and byte_size(key) > 0,
       do: {:ok, key}

  defp extract_api_key(%{"type" => "api"}), do: {:error, :credential_invalid}
  defp extract_api_key(%{"type" => _type}), do: {:error, :credential_type_unsupported}
  defp extract_api_key(nil), do: {:error, :credential_not_found}
  defp extract_api_key(_record), do: {:error, :credential_invalid}
end
