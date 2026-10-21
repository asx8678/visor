defmodule VisorWeb.ClientLayoutTest do
  use ExUnit.Case, async: true

  import VisorWeb.ClientLayout, only: [guess: 1]

  test "guesses a layout from the user agent" do
    assert guess("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile/15E148") ==
             "phone"

    assert guess("Mozilla/5.0 (Linux; Android 15; Pixel 9) Chrome/131.0 Mobile Safari/537.36") ==
             "phone"

    assert guess("Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)") == "tablet"

    assert guess("Mozilla/5.0 (Linux; Android 14; SM-X710) Chrome/131.0 Safari/537.36") ==
             "tablet"

    assert guess("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0 Safari/537.36") ==
             "desktop"

    assert guess("") == "desktop"
  end
end
