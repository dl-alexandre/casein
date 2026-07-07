defmodule DevIDE.Config.FilterParametersTest do
  use ExUnit.Case, async: true

  @auth_keys ~w(
    authorization
    token
    api_token
    bearer
    access_token
    refresh_token
    workspace_api_tokens
    dev_ide_api_token
    password
    secret
  )

  test "phoenix filter_parameters redacts auth-sensitive request params" do
    contents = File.read!(Path.expand("config/config.exs", File.cwd!()))

    assert contents =~ "config :phoenix, :filter_parameters"

    for key <- @auth_keys do
      assert contents =~ ~s("#{key}")
    end
  end
end
