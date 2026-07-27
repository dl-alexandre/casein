defmodule CaseinMob.AndroidConfigurationTest do
  use ExUnit.Case, async: true

  @manifest Path.expand("../../android/app/src/main/AndroidManifest.xml", __DIR__)

  test "uses the canonical public app label without changing stable routing identifiers" do
    manifest = File.read!(@manifest)

    assert manifest =~ ~s(android:label="Casein")
    refute manifest =~ ~s(android:label="CaseinMob")
    assert manifest =~ ~s(package="com.example.casein_mob")
    assert manifest =~ ~s(android:scheme="casein")
  end
end
