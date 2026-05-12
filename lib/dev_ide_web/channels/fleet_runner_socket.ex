defmodule DevIdeWeb.FleetRunnerSocket do
  use Phoenix.Socket

  channel "runner:*", DevIdeWeb.FleetRunnerChannel

  @impl true
  def connect(params, socket, _connect_info) do
    case configured_tokens() do
      [] ->
        :error

      tokens ->
        if Enum.any?(tokens, &secure_match?(params["token"], &1)) do
          {:ok, assign(socket, :transport, "devide.fleet.channel.v1")}
        else
          :error
        end
    end
  end

  @impl true
  def id(socket), do: "fleet_runner:#{socket.assigns[:runner_id] || "unknown"}"

  defp configured_tokens do
    [
      Application.get_env(:dev_ide, :runner_token),
      System.get_env("DEV_IDE_RUNNER_TOKEN"),
      Application.get_env(:dev_ide, :api_token),
      System.get_env("DEV_IDE_API_TOKEN")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp secure_match?(token, expected) when is_binary(token) and is_binary(expected) do
    byte_size(token) == byte_size(expected) and Plug.Crypto.secure_compare(token, expected)
  end

  defp secure_match?(_token, _expected), do: false
end
