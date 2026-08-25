defmodule Casein.Agents.PrHandoff do
  @moduledoc """
  Validated, redacted receipt exchanged between a Casein worker and Dash.

  The receipt identifies one exact commit. It is intentionally limited to
  merge-relevant facts; review text, command output, credentials, and tokens do
  not belong in this boundary.
  """

  @schema_version 1
  @max_string 256
  @max_url 2_048
  @max_items 32
  @item_fields ~w(command name status conclusion commit_sha finished_at)a

  @type receipt :: %{
          required(:schema_version) => pos_integer(),
          required(:handoff_id) => String.t(),
          required(:repository) => String.t(),
          required(:base_branch) => String.t(),
          required(:head_branch) => String.t(),
          required(:head_sha) => String.t(),
          optional(:worker_run_id) => String.t(),
          optional(:pr_number) => pos_integer(),
          optional(:pr_url) => String.t(),
          optional(:tests) => [map()],
          optional(:checks) => [map()],
          optional(:review_threads) => map(),
          optional(:approvals) => map(),
          optional(:merge_readiness) => map(),
          optional(:handoff_status) => String.t(),
          optional(:created_at) => String.t()
        }

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec validate(map()) :: {:ok, receipt()} | {:error, map()}
  def validate(attrs) when is_map(attrs) do
    receipt = normalize(attrs)

    with :ok <- require_string(receipt, :handoff_id, &valid_id?/1),
         :ok <- require_string(receipt, :repository, &valid_repository?/1),
         :ok <- require_string(receipt, :base_branch, &valid_branch?/1),
         :ok <- require_string(receipt, :head_branch, &valid_branch?/1),
         :ok <- require_string(receipt, :head_sha, &valid_sha?/1),
         :ok <- optional_valid(receipt, :worker_run_id, &valid_id?/1),
         :ok <- optional_valid(receipt, :pr_number, &valid_pr_number?/1),
         :ok <- optional_valid(receipt, :pr_url, &valid_url?/1),
         :ok <- optional_valid(receipt, :handoff_status, &valid_status?/1),
         :ok <- optional_valid(receipt, :created_at, &is_binary/1) do
      {:ok, Map.put_new(receipt, :handoff_status, "ready")}
    end
  end

  def validate(_attrs), do: {:error, error(:invalid_handoff, :receipt)}

  @spec idempotency_key(map()) :: String.t() | nil
  def idempotency_key(attrs) when is_map(attrs) do
    with {:ok, receipt} <- validate(attrs) do
      suffix =
        case Map.get(receipt, :pr_number) do
          number when is_integer(number) -> "pr:#{number}"
          _ -> "branch:#{receipt.head_branch}"
        end

      Enum.join([receipt.repository, suffix, receipt.head_sha], ":")
    else
      _ -> nil
    end
  end

  def idempotency_key(_attrs), do: nil

  @spec key(map()) :: String.t() | nil
  def key(attrs), do: idempotency_key(attrs)

  defp normalize(attrs) do
    %{
      schema_version: @schema_version,
      handoff_id: string_value(attrs, :handoff_id),
      worker_run_id: string_value(attrs, :worker_run_id),
      repository: string_value(attrs, :repository),
      base_branch: string_value(attrs, :base_branch),
      head_branch: string_value(attrs, :head_branch),
      head_sha: string_value(attrs, :head_sha),
      pr_number: value(attrs, :pr_number),
      pr_url: string_value(attrs, :pr_url, @max_url),
      tests: safe_items(value(attrs, :tests)),
      checks: safe_items(value(attrs, :checks)),
      review_threads: safe_review_threads(value(attrs, :review_threads)),
      approvals: safe_approvals(value(attrs, :approvals)),
      merge_readiness: safe_merge_readiness(value(attrs, :merge_readiness)),
      handoff_status: string_value(attrs, :handoff_status),
      created_at: string_value(attrs, :created_at)
    }
    |> Enum.reject(fn {_key, item} -> is_nil(item) end)
    |> Map.new()
  end

  defp require_string(receipt, key, validator) do
    case Map.get(receipt, key) do
      value when is_binary(value) ->
        if validator.(value), do: :ok, else: {:error, error(:invalid_handoff, key)}

      _ ->
        {:error, error(:missing_handoff_field, key)}
    end
  end

  defp optional_valid(receipt, key, validator) do
    case Map.get(receipt, key) do
      nil -> :ok
      value -> if validator.(value), do: :ok, else: {:error, error(:invalid_handoff, key)}
    end
  end

  defp valid_id?(value) do
    is_binary(value) and byte_size(value) in 1..@max_string and
      value == String.trim(value) and not String.match?(value, ~r/\s/) and
      not String.contains?(value, [<<0>>, ":"])
  end

  defp valid_repository?(value) do
    is_binary(value) and byte_size(value) <= @max_string and
      Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, value)
  end

  defp valid_branch?(value) do
    is_binary(value) and byte_size(value) in 1..@max_string and
      value == String.trim(value) and not String.match?(value, ~r/\s/) and
      not String.starts_with?(value, "-") and not String.ends_with?(value, ".") and
      not String.ends_with?(value, "/") and
      not String.contains?(value, ["..", "~", "^", ":", "?", "*", "[", "\\", <<0>>])
  end

  defp valid_sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, value)
  defp valid_pr_number?(value), do: is_integer(value) and value > 0

  defp valid_url?(value) do
    is_binary(value) and byte_size(value) <= @max_url and String.starts_with?(value, "https://")
  end

  defp valid_status?(value), do: value in ["ready", "awaiting_dash", "completed"]

  defp safe_items(items) when is_list(items) do
    items
    |> Enum.take(@max_items)
    |> Enum.map(&safe_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp safe_items(_items), do: nil

  defp safe_item(item) when is_map(item) do
    @item_fields
    |> Enum.map(fn key -> {key, scalar_value(item, key)} end)
    |> Enum.reject(fn {_key, item} -> is_nil(item) end)
    |> Map.new()
  end

  defp safe_item(_item), do: nil

  defp safe_review_threads(%{} = threads) do
    %{
      total: non_negative(value(threads, :total)),
      unresolved: non_negative(value(threads, :unresolved)),
      items: safe_thread_items(value(threads, :items))
    }
    |> Enum.reject(fn {_key, item} -> is_nil(item) end)
    |> Map.new()
  end

  defp safe_review_threads(_threads), do: nil

  defp safe_thread_items(items) when is_list(items) do
    items
    |> Enum.take(@max_items)
    |> Enum.map(fn item ->
      id = scalar_value(item, :id)
      resolved = scalar_value(item, :resolved)
      if is_binary(id), do: %{id: id, resolved: resolved == true}, else: nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp safe_thread_items(_items), do: nil

  defp safe_approvals(%{} = approvals) do
    %{
      required: non_negative(value(approvals, :required)),
      current: non_negative(value(approvals, :current)),
      required_teams: safe_strings(value(approvals, :required_teams))
    }
    |> Enum.reject(fn {_key, item} -> is_nil(item) end)
    |> Map.new()
  end

  defp safe_approvals(_approvals), do: nil

  defp safe_merge_readiness(%{} = readiness) do
    %{
      ready: scalar_value(readiness, :ready),
      branch_up_to_date: scalar_value(readiness, :branch_up_to_date),
      conflicts: scalar_value(readiness, :conflicts),
      reason: scalar_value(readiness, :reason)
    }
    |> Enum.reject(fn {_key, item} -> is_nil(item) end)
    |> Map.new()
  end

  defp safe_merge_readiness(_readiness), do: nil

  defp safe_strings(items) when is_list(items) do
    items
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.slice(&1, 0, @max_string))
    |> Enum.take(@max_items)
  end

  defp safe_strings(_items), do: nil

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: nil

  defp scalar_value(map, key) when is_map(map) do
    case value(map, key) do
      item when is_binary(item) -> String.slice(item, 0, @max_string)
      item when is_boolean(item) or is_integer(item) -> item
      _ -> nil
    end
  end

  defp scalar_value(_map, _key), do: nil

  defp string_value(map, key, max \\ @max_string) do
    case value(map, key) do
      item when is_binary(item) -> String.slice(item, 0, max)
      _ -> nil
    end
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, item} -> item
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp error(reason, field), do: %{error: reason, field: field}
end
