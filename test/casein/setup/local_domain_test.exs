defmodule Casein.Setup.LocalDomainTest do
  use ExUnit.Case, async: true

  alias Casein.Setup.LocalDomain

  test "put_hosts_entry adds a managed local-domain block" do
    content = "127.0.0.1 localhost\n"

    assert LocalDomain.put_hosts_entry(content, "devide.test", "192.168.1.240") == """
           127.0.0.1 localhost

           # BEGIN Casein local domain
           192.168.1.240 devide.test
           # END Casein local domain
           """
  end

  test "put_hosts_entry replaces a previous managed block" do
    content = """
    127.0.0.1 localhost

    # BEGIN Casein local domain
    192.168.1.2 devide.test
    # END Casein local domain
    """

    assert LocalDomain.put_hosts_entry(content, "devide.test", "192.168.1.240") =~
             "192.168.1.240 devide.test"

    refute LocalDomain.put_hosts_entry(content, "devide.test", "192.168.1.240") =~
             "192.168.1.2 devide.test"
  end

  test "put_hosts_entry removes stale domain aliases elsewhere" do
    content = "127.0.0.1 localhost devide.test # keep comment\n"

    updated = LocalDomain.put_hosts_entry(content, "devide.test", "192.168.1.240")

    assert updated =~ "127.0.0.1 localhost # keep comment"
    assert updated =~ "192.168.1.240 devide.test"
  end

  test "hosts_mapping finds existing mapping" do
    content = "127.0.0.1 localhost\n192.168.1.240 devide.test\n"

    assert LocalDomain.hosts_mapping(content, "devide.test") == "192.168.1.240"
  end
end
