defmodule VisorWeb.ClientLayout do
  @moduledoc """
  Picks the first layout from the browser's user agent, so a phone gets the
  phone layout on its very first paint. Once connected, the page checks the
  real screen (touch, size, orientation) and corrects it.
  """

  @layouts ~w(phone tablet desktop)

  def layouts, do: @layouts

  @doc "Session data for the harness live_session."
  def session(conn) do
    mobile_hint = Plug.Conn.get_req_header(conn, "sec-ch-ua-mobile")
    user_agent = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
    %{"layout" => if(mobile_hint == ["?1"], do: "phone", else: guess(user_agent))}
  end

  @doc "A layout for a user agent string."
  def guess(user_agent) do
    cond do
      user_agent =~ ~r/iPhone|iPod|Android.+Mobile|Windows Phone|Mobile.+Firefox/i -> "phone"
      user_agent =~ ~r/iPad|Android|Tablet/i -> "tablet"
      true -> "desktop"
    end
  end
end
