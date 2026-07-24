defmodule Casein.Deployment.OperatorConfig do
  @moduledoc """
  Validates the data-only contract between Casein core and an operator overlay.

  The overlay may provide deployment-specific values in a JSON file selected by
  `CASEIN_OPERATOR_CONFIG_FILE`. Keeping the contract data-only prevents a host
  overlay from becoming a second application configuration language and makes it
  possible to audit the public core independently of private infrastructure.
  """

  @capabilities %{
    "deploy_drift" => :deploy_drift,
    "deploy_status" => :deploy_status,
    "poller" => :poller,
    "reverse_proxy" => :reverse_proxy,
    "socket" => :socket
  }

  @string_deployment_keys %{
    "default_host" => :default_host,
    "deploy_service" => :deploy_service,
    "git_branch" => :git_branch,
    "git_credential_helper" => :git_credential_helper,
    "git_remote" => :git_remote,
    "github_repo" => :github_repo,
    "last_deploy_path" => :last_deploy_path
  }

  @integer_deployment_keys %{
    "ls_remote_timeout_ms" => :ls_remote_timeout_ms,
    "poller_watch_interval_ms" => :poller_watch_interval_ms,
    "remote_head_cache_ttl_ms" => :remote_head_cache_ttl_ms,
    "stale_in_progress_ms" => :stale_in_progress_ms
  }

  @map_deployment_keys %{
    "phase_stale_in_progress_ms" => :phase_stale_in_progress_ms
  }

  @contract_version 1
  @top_level_keys ~w(contract_version deployment deployment_capabilities)
  @site_specific_deployment_keys [
    :github_webhook_secret | Map.values(@string_deployment_keys)
  ]

  @type parsed :: keyword()

  @doc "Current public operator-profile contract version."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc "Reads and validates an operator configuration file."
  @spec load(Path.t()) :: {:ok, parsed()} | {:error, term()}
  # The path is supplied by a trusted release operator, never by an HTTP or MCP caller.
  # sobelow_skip ["Traversal.FileModule"]
  def load(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, parsed} <- parse(decoded) do
      {:ok, parsed}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, error}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reads an operator configuration file and raises on invalid configuration."
  @spec load!(Path.t()) :: parsed()
  def load!(path) do
    case load(path) do
      {:ok, config} ->
        config

      {:error, reason} ->
        raise ArgumentError,
              "invalid CASEIN_OPERATOR_CONFIG_FILE #{inspect(path)}: #{format_error(reason)}"
    end
  end

  @doc "Validates a decoded operator configuration map."
  @spec parse(term()) :: {:ok, parsed()} | {:error, term()}
  def parse(config) when is_map(config) do
    with :ok <- reject_unknown_keys(config, @top_level_keys, :root),
         {:ok, contract_version} <- parse_contract_version(Map.get(config, "contract_version")),
         {:ok, capabilities} <- parse_capabilities(Map.get(config, "deployment_capabilities")),
         {:ok, deployment} <- parse_deployment(Map.get(config, "deployment")) do
      parsed = []

      parsed =
        if is_nil(contract_version), do: parsed, else: [contract_version: contract_version]

      parsed =
        if is_nil(capabilities),
          do: parsed,
          else: Keyword.put(parsed, :deployment_capabilities, capabilities)

      parsed =
        if is_nil(deployment), do: parsed, else: Keyword.put(parsed, :deployment, deployment)

      {:ok, parsed}
    end
  end

  def parse(_config), do: {:error, {:invalid_type, :root, "an object"}}

  @doc "Capabilities accepted by the public operator-profile contract."
  @spec capability_names() :: [String.t()]
  def capability_names, do: @capabilities |> Map.keys() |> Enum.sort()

  @doc "Returns the explicit capabilities from a parsed overlay, defaulting to none."
  @spec deployment_capabilities(parsed()) :: [atom()]
  def deployment_capabilities(config),
    do: Keyword.get(config, :deployment_capabilities, [])

  @doc "Applies an overlay without inheriting site-specific values from core."
  @spec deployment(keyword(), parsed()) :: keyword()
  def deployment(core_config, operator_config) do
    core_config
    |> Keyword.drop(@site_specific_deployment_keys)
    |> Keyword.merge(Keyword.get(operator_config, :deployment, []))
    |> Enum.sort()
  end

  defp parse_contract_version(nil), do: {:ok, nil}
  defp parse_contract_version(@contract_version), do: {:ok, @contract_version}

  defp parse_contract_version(value),
    do: {:error, {:unsupported_contract_version, value, @contract_version}}

  defp parse_capabilities(nil), do: {:ok, nil}

  defp parse_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.reduce_while({:ok, []}, fn
      name, {:ok, parsed} when is_binary(name) ->
        case Map.fetch(@capabilities, name) do
          {:ok, capability} -> {:cont, {:ok, [capability | parsed]}}
          :error -> {:halt, {:error, {:unknown_capability, name}}}
        end

      value, _acc ->
        {:halt,
         {:error,
          {:invalid_value, [:deployment_capabilities],
           "list containing only supported capability names; got #{inspect(value)}"}}}
    end)
    |> case do
      {:ok, parsed} -> {:ok, parsed |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp parse_capabilities(value),
    do:
      {:error,
       {:invalid_type, :deployment_capabilities,
        "a list of supported capability names; got #{inspect(value)}"}}

  defp parse_deployment(nil), do: {:ok, nil}

  defp parse_deployment(deployment) when is_map(deployment) do
    allowed_keys =
      Map.keys(@string_deployment_keys) ++
        Map.keys(@integer_deployment_keys) ++ Map.keys(@map_deployment_keys)

    with :ok <- reject_unknown_keys(deployment, allowed_keys, :deployment) do
      Enum.reduce_while(deployment, {:ok, []}, fn {key, value}, {:ok, parsed} ->
        case parse_deployment_value(key, value) do
          {:ok, pair} -> {:cont, {:ok, [pair | parsed]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, parsed} -> {:ok, Enum.sort(parsed)}
        error -> error
      end
    end
  end

  defp parse_deployment(value),
    do: {:error, {:invalid_type, :deployment, "an object; got #{inspect(value)}"}}

  defp parse_deployment_value(key, value) when is_map_key(@string_deployment_keys, key) do
    if is_binary(value) and String.trim(value) != "" do
      {:ok, {Map.fetch!(@string_deployment_keys, key), value}}
    else
      {:error, {:invalid_value, [:deployment, key], "non-empty string"}}
    end
  end

  defp parse_deployment_value(key, value) when is_map_key(@integer_deployment_keys, key) do
    if is_integer(value) and value > 0 do
      {:ok, {Map.fetch!(@integer_deployment_keys, key), value}}
    else
      {:error, {:invalid_value, [:deployment, key], "positive integer"}}
    end
  end

  defp parse_deployment_value("phase_stale_in_progress_ms", value) when is_map(value) do
    if Enum.all?(value, fn {phase, timeout} ->
         is_binary(phase) and String.trim(phase) != "" and is_integer(timeout) and timeout > 0
       end) do
      {:ok, {:phase_stale_in_progress_ms, value}}
    else
      {:error,
       {:invalid_value, [:deployment, "phase_stale_in_progress_ms"],
        "object of phase names to positive integer milliseconds"}}
    end
  end

  defp reject_unknown_keys(map, allowed_keys, scope) do
    case Map.keys(map) -- allowed_keys do
      [] -> :ok
      unknown -> {:error, {:unknown_keys, scope, Enum.sort(unknown)}}
    end
  end

  defp format_error({:invalid_json, error}), do: Exception.message(error)
  defp format_error({:unknown_keys, scope, keys}), do: "unknown #{scope} keys #{inspect(keys)}"
  defp format_error({:unknown_capability, name}), do: "unknown capability #{inspect(name)}"

  defp format_error({:unsupported_contract_version, actual, expected}),
    do: "contract_version #{inspect(actual)} is unsupported; expected #{expected}"

  defp format_error({:invalid_type, field, expected}), do: "#{field} must be #{expected}"

  defp format_error({:invalid_value, path, expected}),
    do: "#{Enum.join(path, ".")} must be a #{expected}"

  defp format_error(reason), do: inspect(reason)
end
