defmodule DevIdeWeb.PageHTML do
  @moduledoc """
  Static page templates rendered by `PageController`, embedded from `page_html/`.
  """
  use DevIdeWeb, :html

  embed_templates "page_html/*"
end
