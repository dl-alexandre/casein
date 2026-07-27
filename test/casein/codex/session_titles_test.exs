defmodule Casein.Codex.SessionTitlesTest do
  use ExUnit.Case, async: true

  alias Casein.Codex.SessionTitles

  test "returns a short first-prompt title for requested Codex sessions" do
    path = Path.join(System.tmp_dir!(), "casein-codex-history-#{System.unique_integer()}.jsonl")
    first_id = "019f9cae-1033-7a22-8c54-7ff3a0f2f92c"
    second_id = "019fa414-828c-7fa3-9475-0aca5a3ecb70"

    File.write!(
      path,
      [
        Jason.encode!(%{
          "session_id" => first_id,
          "ts" => 1,
          "text" => "Fix friendly window titles"
        }),
        "\n",
        Jason.encode!(%{"session_id" => first_id, "ts" => 2, "text" => "A later prompt"}),
        "\n",
        Jason.encode!(%{"session_id" => second_id, "ts" => 3, "text" => "Unrequested"}),
        "\n"
      ]
    )

    server = start_supervised!({SessionTitles, path: path, name: nil}, id: __MODULE__)

    assert SessionTitles.titles(server, [first_id]) == %{
             first_id => "Fix friendly window titles"
           }
  end
end
