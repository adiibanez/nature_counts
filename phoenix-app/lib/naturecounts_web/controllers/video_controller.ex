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

  def show_gcs(conn, %{"path" => path_segments}) do
    object_path = Path.join(path_segments)
    bucket_id = conn.params["bucket_id"] || ""

    if bucket_id == "" do
      send_resp(conn, 400, "Missing bucket_id parameter")
    else
      case Naturecounts.Storage.GCSBuckets.get(bucket_id) do
        nil ->
          send_resp(conn, 404, "Bucket config not found")

        bucket_config ->
          case Naturecounts.Storage.GCS.signed_url(bucket_config, object_path) do
            {:ok, url} ->
              conn
              |> put_resp_header("cache-control", "private, max-age=3500")
              |> redirect(external: url)

            {:error, reason} ->
              send_resp(conn, 502, "GCS error: #{reason}")
          end
      end
    end
  end

  def clip(conn, %{"path" => path_segments}) do
    relative = Path.join(path_segments)

    if String.contains?(relative, "..") do
      send_resp(conn, 403, "Forbidden")
    else
      full_path = Path.join(@videos_root, relative)
      t = conn.params["t"] || "0"
      dur = conn.params["dur"] || "20"

      if File.exists?(full_path) and File.regular?(full_path) do
        # Use ffmpeg to extract a short clip with faststart for reliable browser seeking
        clip_path = clip_cache_path(full_path, t, dur)

        unless File.exists?(clip_path) do
          File.mkdir_p!(Path.dirname(clip_path))

          {_output, exit_code} =
            System.cmd("ffmpeg", [
              "-ss", t,
              "-i", full_path,
              "-t", dur,
              "-c", "copy",
              "-movflags", "+faststart",
              "-avoid_negative_ts", "make_zero",
              "-y",
              clip_path
            ], stderr_to_stdout: true)

          if exit_code != 0, do: File.rm(clip_path)
        end

        if File.exists?(clip_path) do
          %{size: file_size} = File.stat!(clip_path)
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
              |> put_resp_header("cache-control", "private, max-age=60")
              |> send_file(206, clip_path, range_start, length)

            _ ->
              conn
              |> put_resp_content_type(mime, nil)
              |> put_resp_header("accept-ranges", "bytes")
              |> put_resp_header("content-length", "#{file_size}")
              |> put_resp_header("cache-control", "private, max-age=60")
              |> send_file(200, clip_path)
          end
        else
          send_resp(conn, 500, "Failed to extract clip")
        end
      else
        send_resp(conn, 404, "Not found")
      end
    end
  end

  defp clip_cache_path(video_path, t, dur) do
    hash = :crypto.hash(:md5, "#{video_path}:#{t}:#{dur}") |> Base.encode16(case: :lower) |> binary_part(0, 12)
    Path.join([System.tmp_dir!(), "video_clips", "#{hash}.mp4"])
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
