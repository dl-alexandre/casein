defmodule CaseinWeb.PreviewProxy.SessionCookieIsolationTest do
  @moduledoc """
  Security regression: the preview proxy serves arbitrary workspace apps from the
  *cockpit origin*, so Casein's own session cookie must not cross the boundary in
  either direction.

  Outbound, forwarding it hands a previewed app the operator's Casein session.
  Inbound, letting the app emit `Set-Cookie: _casein_key=...` is session
  fixation — and because Phoenix stores the CSRF token inside the session, a
  fixated session carries a valid CSRF token with it.

  Every *other* cookie stays forwarded in both directions: previewed apps
  legitimately depend on their own cookies, and that pass-through is a tested
  product behaviour.
  """
  use ExUnit.Case, async: true

  alias CaseinWeb.PreviewProxy.Rewrite

  describe "outbound: scrub_request_cookie/1" do
    test "removes Casein's session cookie and keeps the rest" do
      assert Rewrite.scrub_request_cookie("_casein_key=secret; sid=old; theme=light") ==
               "sid=old; theme=light"
    end

    test "removes it regardless of position or surrounding whitespace" do
      assert Rewrite.scrub_request_cookie("sid=old;   _casein_key=secret  ; theme=light") ==
               "sid=old; theme=light"

      assert Rewrite.scrub_request_cookie("sid=old; _casein_key=secret") == "sid=old"
    end

    test "returns nil when only the session cookie was present so the header is dropped" do
      assert Rewrite.scrub_request_cookie("_casein_key=secret") == nil
      assert Rewrite.scrub_request_cookie("") == nil
    end

    test "leaves an unrelated cookie jar untouched" do
      assert Rewrite.scrub_request_cookie("sid=old; theme=light") == "sid=old; theme=light"
    end

    test "does not strip cookies that merely share a prefix" do
      # `_casein_keyring` is a different cookie and must survive.
      assert Rewrite.scrub_request_cookie("_casein_keyring=abc") == "_casein_keyring=abc"
    end

    test "follows the configured session cookie key" do
      Application.put_env(:casein, :session_cookie_key, "_custom_key")
      on_exit(fn -> Application.delete_env(:casein, :session_cookie_key) end)

      assert Rewrite.scrub_request_cookie("_custom_key=secret; sid=old") == "sid=old"
      # The default name is no longer privileged once the key is overridden.
      assert Rewrite.scrub_request_cookie("_casein_key=x") == "_casein_key=x"
    end
  end

  describe "inbound: forward_headers/1 blocks session fixation" do
    test "drops an upstream set-cookie targeting Casein's session cookie" do
      out =
        Rewrite.forward_headers(%{
          "set-cookie" => [
            "_casein_key=attacker; Path=/",
            "sid=one; Path=/; HttpOnly"
          ]
        })

      refute Enum.any?(out, fn {name, value} ->
               name == "set-cookie" and String.starts_with?(value, "_casein_key=")
             end)

      # The previewed app's own cookie still reaches the browser.
      assert {"set-cookie", "sid=one; Path=/; HttpOnly"} in out
    end

    test "session_set_cookie?/1 identifies only the session cookie" do
      assert Rewrite.session_set_cookie?("_casein_key=x; Path=/")
      assert Rewrite.session_set_cookie?("  _casein_key=x")
      refute Rewrite.session_set_cookie?("sid=x; Path=/")
      refute Rewrite.session_set_cookie?("_casein_keyring=x")
      refute Rewrite.session_set_cookie?(nil)
    end
  end
end
