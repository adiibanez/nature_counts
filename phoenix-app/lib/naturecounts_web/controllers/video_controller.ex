defmodule NaturecountsWeb.VideoController do
  use NaturecountsWeb, :controller

  @videos_root "/videos"

  def show(conn, %{"path" => path_segments}) do
    relative = Path.join(path_segments)

    if String.contains?(relative, "..") do
      send_resp(conn, 403, "Forbidden")
    else
      full_path = Path.join(@videos_root, relative)

      if File.exists?(full_path) and File.regular?(full_path) do
        %{size: file_size} = File.stat!(full_path)
        mime = MIME.from_path(full_path)

        case get_req_header(conn, "range") do
          ["bytes=" <> range_spec] ->
            {range_start, range_end} = parse_range(range_spec, file_size)
            length = range_end - range_start + 1

            conn
            |> put_resp_content_type(mime, nil)
            |> put_resp_header("accept-ranges", "bytes")
            |> put_resp_header("content-range", "bytes #{range_start}-#{range_end}/#{file_size}")
            |> put_resp_header("content-length", "#{length}")
            |> send_file(206, full_path, range_start, length)

          _ ->
            conn
            |> put_resp_content_type(mime, nil)
            |> put_resp_header("accept-ranges", "bytes")
            |> put_resp_header("content-length", "#{file_size}")
            |> send_file(200, full_path)
        end
      else
        send_resp(conn, 404, "Not found")
      end
    end
  end

  defp parse_range(spec, file_size) do
    case String.split(spec, "-", parts: 2) do
      [start_str, ""] ->
        start = String.to_integer(start_str)
        {start, file_size - 1}

      ["", suffix_str] ->
        suffix = String.to_integer(suffix_str)
        {file_size - suffix, file_size - 1}

      [start_str, end_str] ->
        {String.to_integer(start_str), min(String.to_integer(end_str), file_size - 1)}
    end
  end
end
