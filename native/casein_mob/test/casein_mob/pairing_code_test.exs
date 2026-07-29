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

  test "trims scanner whitespace and accepts one percent-decoded path segment" do
    [vector] = Jason.decode!(File.read!(@vector_path))
    encoded = String.replace_prefix(vector["uri"], "casein://pair/", "")
    escaped = String.replace_prefix(encoded, "e", "%65")

    assert {:ok, expected} = PairingCode.decode(vector["uri"])
    assert {:ok, ^expected} = PairingCode.decode("\n  casein://pair/#{escaped}\t")
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
  end
end
