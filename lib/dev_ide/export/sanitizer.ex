defmodule DevIDE.Export.Sanitizer do
  @moduledoc """
  Deny-list-based redaction for outbound JSON payloads.

  This is the second-line defense behind the per-subsystem sanitizers
  (`Workspaces.State.sanitize_manager_payload/1`, `DbIsolation.summary`,
  redaction during isolation probe). The rule of thumb: anything coming
  from a manager payload, env, or external system passes through here
  before it leaves the BEAM via the API.
  """

  @secret_keys ~w(database_url postgres_url pg_url db_url
                  password pgpassword postgres_password
                  secret token api_key auth bearer cookie session_id)

  @env_keys ~w(env environment envs envvars)

  @spec scrub(any()) :: any()
  def scrub(%DateTime{} = value), do: value
  def scrub(%NaiveDateTime{} = value), do: value
  def scrub(%Date{} = value), do: value
  def scrub(%Time{} = value), do: value
  def scrub(%_{} = value), do: value |> Map.from_struct() |> scrub()

  def scrub(map) when is_map(map) do
    map
    |> Enum.reject(fn {k, _v} -> secret_key?(k) end)
    |> Enum.map(fn {k, v} ->
      cond do
        env_key?(k) -> {k, scrub_env(v)}
        true -> {k, scrub(v)}
      end
    end)
    |> Map.new()
  end

  def scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)
  def scrub(value), do: value

  @doc """
  Redact obvious secret material from text streams before they are logged,
  broadcast, or stored as operator-facing output.
  """
  @spec redact_text(binary()) :: binary()
  def redact_text(value) when is_binary(value) do
    value
    |> String.replace(
      ~r/\b(database_url|postgres_url|pg_url|db_url|password|pgpassword|postgres_password|secret|token|api_key|authorization|bearer)=\S+/i,
      "\\1=[REDACTED]"
    )
    |> String.replace(~r/\bBearer\s+[A-Za-z0-9._~+\/=-]+/i, "Bearer [REDACTED]")
    |> String.replace(~r/(\w+:\/\/)[^:\s\/@]+:[^@\s\/]+@/, "\\1[REDACTED]@")
  end

  def redact_text(value), do: value

  defp secret_key?(k) when is_binary(k), do: String.downcase(k) in @secret_keys
  defp secret_key?(k) when is_atom(k), do: secret_key?(Atom.to_string(k))
  defp secret_key?(_), do: false

  defp env_key?(k) when is_binary(k), do: String.downcase(k) in @env_keys
  defp env_key?(k) when is_atom(k), do: env_key?(Atom.to_string(k))
  defp env_key?(_), do: false

  defp scrub_env(list) when is_list(list) do
    Enum.map(list, fn
      bin when is_binary(bin) ->
        case String.split(bin, "=", parts: 2) do
          [k, _v] -> if secret_key?(k), do: "#{k}=[REDACTED]", else: bin
          _ -> bin
        end

      other ->
        scrub(other)
    end)
  end

  defp scrub_env(other), do: scrub(other)
end
