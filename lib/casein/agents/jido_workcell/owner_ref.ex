defmodule Casein.Agents.JidoWorkcell.OwnerRef do
  @moduledoc """
  Canonical, non-secret owner reference for Gate 0 receipts.

  An owner reference is structured identity, not a display address. In
  particular, an email address is never accepted as the subject id and the
  whole value is never serialized into a receipt as an opaque string.
  """

  alias Casein.Agents.JidoWorkcell.Limits

  @keys [:provider, :id, :role]

  @type t :: %{
          required(:provider) => String.t(),
          required(:id) => String.t(),
          required(:role) => String.t()
        }

  @spec normalize(term()) :: {:ok, t()} | {:error, atom()}
  def normalize(value) when is_map(value) do
    if unknown_keys?(value) do
      {:error, :unknown_owner_ref_field}
    else
      with {:ok, provider} <- required_value(value, :provider),
           {:ok, id} <- required_id(value),
           {:ok, role} <- required_value(value, :role) do
        {:ok, %{provider: provider, id: id, role: role}}
      end
    end
  end

  def normalize(_value), do: {:error, :invalid_owner_ref}

  @spec valid?(term()) :: boolean()
  def valid?(value), do: match?({:ok, _}, normalize(value))

  @spec for_workspace(String.t()) :: t()
  def for_workspace(workspace_id) when is_binary(workspace_id) do
    id =
      if Limits.valid_scalar_id?(workspace_id) do
        workspace_id
      else
        digest =
          :crypto.hash(:sha256, workspace_id)
          |> Base.encode16(case: :lower)
          |> binary_part(0, 32)

        "workspace-" <> digest
      end

    %{provider: "casein", id: id, role: "worker"}
  end

  defp required_id(value) do
    with {:ok, id} <- required_value(value, :id) do
      cond do
        String.contains?(id, "@") -> {:error, :owner_ref_email_not_allowed}
        Limits.valid_scalar_id?(id) -> {:ok, id}
        true -> {:error, :invalid_owner_ref_id}
      end
    end
  end

  defp required_value(value, key) do
    case fetch(value, key) do
      item when is_binary(item) ->
        item = String.trim(item)

        if item != "" and safe_text?(item),
          do: {:ok, item},
          else: {:error, :invalid_owner_ref}

      _ ->
        {:error, :invalid_owner_ref}
    end
  end

  defp safe_text?(value) do
    byte_size(value) <= 160 and
      not String.contains?(value, <<0>>) and
      not String.contains?(value, "\n") and
      not credential?(value)
  end

  defp unknown_keys?(value) do
    Enum.any?(Map.keys(value), fn
      key when is_atom(key) -> key not in @keys
      key when is_binary(key) -> key not in Enum.map(@keys, &Atom.to_string/1)
      _ -> true
    end)
  end

  defp fetch(value, key), do: Map.get(value, key, Map.get(value, Atom.to_string(key)))

  defp credential?(value) do
    Regex.match?(
      ~r/(?:bearer\s+|password\s*=|token\s*=|api[_-]?key\s*=|gh[pousr]_|xox[baprs]-|-----begin .* private key)/i,
      value
    )
  end
end
