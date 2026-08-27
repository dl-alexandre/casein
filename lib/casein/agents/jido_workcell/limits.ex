defmodule Casein.Agents.JidoWorkcell.Limits do
  @moduledoc """
  Shared bounds for the headless Jido Workcell contract.

  The manager, worker, and MCP schemas must agree on the same action envelope.
  Keeping the values here prevents one boundary from accepting a larger batch
  than the next boundary can safely execute or report.
  """

  @max_actions 16
  @max_paths 256
  @max_tests 64
  @max_artifacts 64
  # Apply this only to the dedicated scalar-ID fields. Git branches,
  # repositories, URLs, paths, commands, SHAs, and opaque provider references
  # have their own validators.
  @scalar_id_re ~r/\A[a-z][a-z0-9_-]{2,63}\z/
  # CASEIN_INPUT_MAX_BYTES is deliberately a compile-time contract. It is not
  # an application setting: changing it in one layer must never make another
  # layer accept a larger request.
  @input_max_bytes 8_192

  @spec max_actions() :: pos_integer()
  def max_actions, do: @max_actions

  @spec max_paths() :: pos_integer()
  def max_paths, do: @max_paths

  @spec max_tests() :: pos_integer()
  def max_tests, do: @max_tests

  @spec max_artifacts() :: pos_integer()
  def max_artifacts, do: @max_artifacts

  @spec input_max_bytes() :: pos_integer()
  def input_max_bytes, do: @input_max_bytes

  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: input_max_bytes()

  @doc "Whether a value is a Gate 0 lowercase scalar identifier."
  @spec valid_scalar_id?(term()) :: boolean()
  def valid_scalar_id?(value),
    do: is_binary(value) and Regex.match?(@scalar_id_re, value)

  @doc "Validate the JSON-sized input envelope used by protocol and workers."
  @spec validate_input(term()) :: :ok | {:error, :input_too_large | :invalid_input}
  def validate_input(value) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= @input_max_bytes -> :ok
      {:ok, _encoded} -> {:error, :input_too_large}
      {:error, _reason} -> {:error, :invalid_input}
    end
  end

  @doc "Whether a workspace is in the configured Workcell allowlist."
  @spec workspace_allowed?(String.t()) :: boolean()
  def workspace_allowed?(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    case Application.get_env(:casein, :jido_workcell_workspace_ids, :all) do
      :all -> true
      nil -> true
      ids when is_list(ids) -> workspace_id in ids
      %{} = ids -> Map.get(ids, workspace_id, false) in [true, "true", 1, "1"]
      _ -> false
    end
  end

  def workspace_allowed?(_workspace_id), do: false
end
