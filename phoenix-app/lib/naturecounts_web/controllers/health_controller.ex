defmodule NaturecountsWeb.HealthController do
  use NaturecountsWeb, :controller

  def index(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
