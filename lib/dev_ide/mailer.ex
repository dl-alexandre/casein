defmodule DevIde.Mailer do
  use Boundary, deps: [], exports: []

  use Swoosh.Mailer, otp_app: :dev_ide
end
