defmodule Casein.Setup.LocalDomainTest do
  use ExUnit.Case, async: true

  alias Casein.Setup.LocalDomain

  test "put_hosts_entry adds a managed local-domain block" do
    content = "127.0.0.1 localhost\n"

    assert LocalDomain.put_hosts_entry(content, "casein.test", "192.168.1.240") == """
           127.0.0.1 localhost

           # BEGIN Casein local domain
           192.168.1.240 casein.test
           # END Casein local domain
           """
  end

  test "put_hosts_entry replaces a previous managed block" do
    content = """
    127.0.0.1 localhost

    # BEGIN Casein local domain
    192.168.1.2 casein.test
    # END Casein local domain
    """

    assert LocalDomain.put_hosts_entry(content, "casein.test", "192.168.1.240") =~
             "192.168.1.240 casein.test"

    refute LocalDomain.put_hosts_entry(content, "casein.test", "192.168.1.240") =~
             "192.168.1.2 casein.test"
  end

  test "put_hosts_entry removes stale domain aliases elsewhere" do
    content = "127.0.0.1 localhost casein.test # keep comment\n"

    updated = LocalDomain.put_hosts_entry(content, "casein.test", "192.168.1.240")

    assert updated =~ "127.0.0.1 localhost # keep comment"
    assert updated =~ "192.168.1.240 casein.test"
  end

  test "hosts_mapping finds existing mapping" do
    content = "127.0.0.1 localhost\n192.168.1.240 casein.test\n"

    assert LocalDomain.hosts_mapping(content, "casein.test") == "192.168.1.240"
  end
end
