defmodule CaseinMob.PairingCodeTest do
  use ExUnit.Case, async: true

  alias CaseinMob.PairingCode

  @vector_path Path.expand("../fixtures/compact_pairing_vectors.json", __DIR__)

  test "canonical QR byte vectors decode to only the compact descriptor" do
    for vector <- Jason.decode!(File.read!(@vector_path)) do
      assert {:ok, payload} = PairingCode.decode(vector["uri"])

      assert payload == %{
               "h" => vector["handle"],
               "o" => vector["origin"],
               "v" => vector["version"]
             }
    end
  end

  # Exact non-secret structural fixture from issue #457 / compact_pairing_vectors.json.
  # Camera decode places this full URI in the pairing field; pre-exchange validation
  # must accept it without contacting the server.
  test "DairyPhone golden compact URI is accepted before exchange" do
    uri =
      "casein://pair/eyJoIjoiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsIm8iOiJodHRwczovL2Nhc2Vpbi5kZXZib3gubWlsY2dyb3VwLmNvbSIsInYiOjF9"

    assert {:ok, payload} = PairingCode.decode(uri)

    assert payload == %{
             "h" => "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
             "o" => "https://casein.devbox.milcgroup.com",
             "v" => 1
           }

    # Emitter shape (controller map key order v/o/h) must also decode.
    handle = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    origin = "https://casein.devbox.milcgroup.com"

    emitter =
      "casein://pair/" <>
        (%{"v" => 1, "o" => origin, "h" => handle}
         |> Jason.encode!()
         |> Base.url_encode64(padding: false))

    assert {:ok, ^payload} = PairingCode.decode(emitter)
  end

  test "trims scanner whitespace and accepts one percent-decoded path segment" do
    [vector] = Jason.decode!(File.read!(@vector_path))
    encoded = String.replace_prefix(vector["uri"], "casein://pair/", "")
    escaped = String.replace_prefix(encoded, "e", "%65")

    assert {:ok, expected} = PairingCode.decode(vector["uri"])
    assert {:ok, ^expected} = PairingCode.decode("\n  casein://pair/#{escaped}\t")
  end

  test "accepts the current compact shape with native scanner boundary artifacts" do
    [vector] = Jason.decode!(File.read!(@vector_path))
    uri = vector["uri"]
    encoded = String.replace_prefix(uri, "casein://pair/", "")

    assert byte_size(uri) == 146
    assert byte_size(encoded) == 132
    assert {:ok, expected} = PairingCode.decode(uri)

    for scanned <- [
          uri <> "\0",
          "\uFEFF" <> uri,
          "\u2066" <> uri <> "\u2069",
          "\n\u200B" <> uri <> "\u2060\t",
          "\uFEFF \u200B" <> uri <> "\u2060 \u2069"
        ] do
      assert {:ok, ^expected} = PairingCode.decode(scanned)
    end
  end

  test "scanner boundary normalization never permits embedded artifacts" do
    [vector] = Jason.decode!(File.read!(@vector_path))
    uri = vector["uri"]
    encoded = String.replace_prefix(uri, "casein://pair/", "")
    split_at = div(byte_size(encoded), 2)
    {left, right} = String.split_at(encoded, split_at)

    for artifact <- ["\0", "\uFEFF", "\u200B", "\u2060", "\u2066"] do
      assert {:error, _reason} =
               PairingCode.decode("casein://pair/" <> left <> artifact <> right)
    end
  end

  test "query compatibility remains exact to the Casein pair host" do
    [vector] = Jason.decode!(File.read!(@vector_path))
    encoded = String.replace_prefix(vector["uri"], "casein://pair/", "")

    assert {:ok, _payload} =
             PairingCode.decode("casein://pair?code=#{URI.encode_www_form(encoded)}")

    assert {:error, :invalid_structure} =
             PairingCode.decode("https://attacker.test/?code=#{URI.encode_www_form(encoded)}")
  end

  test "malformed URI components and tampered payloads fail closed" do
    [vector] = Jason.decode!(File.read!(@vector_path))

    for code <-
          vector["reject_uris"] ++
            [
              "casein://pair/",
              "casein://pair/not+base64url",
              vector["uri"] <> "x"
            ] do
      assert {:error, _reason} = PairingCode.decode(code)
    end
  end

  test "raw JSON legacy descriptors keep their explicit compatibility path" do
    legacy = %{
      "url" => "https://casein.devbox.milcgroup.com",
      "token" => "fixture-token",
      "workspace_id" => "fixture-workspace"
    }

    assert {:ok, ^legacy} = PairingCode.decode(Jason.encode!(legacy))
  end

  test "scanner values are bounded before decoding" do
    assert {:error, :invalid_structure} =
             PairingCode.decode("casein://pair/" <> String.duplicate("A", 4_097))

    assert {:error, :invalid_structure} =
             PairingCode.decode(
               String.duplicate("\u200B", 4_097) <>
                 "casein://pair/" <>
                 String.duplicate("A", 132)
             )
  end
end
