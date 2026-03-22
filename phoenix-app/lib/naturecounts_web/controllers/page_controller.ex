defmodule NaturecountsWeb.PageController do
  use NaturecountsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
