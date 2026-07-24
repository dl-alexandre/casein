defmodule CaseinWeb.RuntimeSSLPlug do
  @moduledoc false

  @default_options [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

  def init(opts), do: opts

  def call(%{request_path: "/healthz"} = conn, _opts), do: conn

  def call(conn, _opts) do
    if enabled?() do
      @default_options
      |> Keyword.merge(Application.get_env(:dev_ide, :runtime_force_ssl_options, []))
      |> Plug.SSL.init()
      |> then(&Plug.SSL.call(conn, &1))
    else
      conn
    end
  end

  def enabled? do
    Application.get_env(:dev_ide, :runtime_force_ssl, false) and
      not Application.get_env(:dev_ide, :lan_insecure_http, false)
  end
end
