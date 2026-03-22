defmodule NaturecountsWeb.CropsController do
  use NaturecountsWeb, :controller

  @crops_dir "/videos/vlm_crops"

  def show(conn, %{"filename" => filename}) do
    # Prevent path traversal
    safe_name = Path.basename(filename)
    path = Path.join(@crops_dir, safe_name)

    if File.exists?(path) do
      conn
      |> put_resp_content_type("image/jpeg")
      |> send_file(200, path)
    else
      send_resp(conn, 404, "Not found")
    end
  end
end
