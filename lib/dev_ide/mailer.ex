defmodule Casein.Mailer do
  use Boundary, top_level?: true, deps: [], exports: []

  use Swoosh.Mailer, otp_app: :casein
end
