defmodule NaturecountsWeb.VideoController do
  use NaturecountsWeb, :controller
  require Logger

  @videos_root "/videos"
  @faststart_cache Path.join(System.tmp_dir!(), "video_faststart")

  def show(conn, %{"path" => path_segments}) do
    relative = Path.join(path_segments)

    if String.contains?(relative, "..") do
      send_resp(conn, 403, "Forbidden")
    else
      full_path = Path.join(@videos_root, relative)

      if File.exists?(full_path) and File.regular?(full_path) do
        serve_path = ensure_faststart(full_path)
        %{size: file_size} = File.stat!(serve_path)
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
            |> send_file(206, serve_path, range_start, length)

          _ ->
            conn
            |> put_resp_content_type(mime, nil)
            |> put_resp_header("accept-ranges", "bytes")
            |> put_resp_header("content-length", "#{file_size}")
            |> send_file(200, serve_path)
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

  # Returns a path to a faststart-ready version of the video.
  # If the moov atom is already at the front, returns the original path.
  # Otherwise remuxes to a cached copy with +faststart (no re-encoding).
  defp ensure_faststart(path) do
    ext = Path.extname(path) |> String.downcase()

    # Only MP4/MOV benefit from faststart; other formats (TS, MKV, AVI) don't use moov atoms
    if ext in [".mp4", ".mov"] and not has_faststart?(path) do
      cached = faststart_cache_path(path)

      if File.exists?(cached) do
        cached
      else
        File.mkdir_p!(Path.dirname(cached))
        tmp = cached <> ".tmp"

        {_output, exit_code} =
          System.cmd("ffmpeg", [
            "-i", path,
            "-c", "copy",
            "-movflags", "+faststart",
            "-y",
            tmp
          ], stderr_to_stdout: true)

        if exit_code == 0 do
          File.rename!(tmp, cached)
          Logger.info("[VideoController] Created faststart cache for #{Path.basename(path)}")
          cached
        else
          File.rm(tmp)
          Logger.warning("[VideoController] faststart remux failed for #{Path.basename(path)}, serving original")
          path
        end
      end
    else
      path
    end
  end

  # Check if the moov atom appears before mdat by reading the first chunk of the file.
  # MP4 is a sequence of boxes: [size(4 bytes)][type(4 bytes)][...]. We scan for moov vs mdat.
  defp has_faststart?(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        result = scan_mp4_atoms(file, 0, File.stat!(path).size)
        File.close(file)
        result

      _ ->
        false
    end
  end

  defp scan_mp4_atoms(_file, offset, file_size) when offset >= file_size, do: false

  defp scan_mp4_atoms(file, offset, file_size) do
    case :file.pread(file, offset, 8) do
      {:ok, <<size::32, type::binary-size(4)>>} ->
        box_size = if size == 0, do: file_size - offset, else: size
        # size == 1 means 64-bit extended size
        box_size =
          if size == 1 do
            case :file.pread(file, offset + 8, 8) do
              {:ok, <<extended::64>>} -> extended
              _ -> file_size - offset
            end
          else
            box_size
          end

        cond do
          type == "moov" -> true    # moov before mdat = faststart
          type == "mdat" -> false   # mdat before moov = not faststart
          box_size < 8 -> false     # corrupt/unexpected
          true -> scan_mp4_atoms(file, offset + box_size, file_size)
        end

      _ ->
        false
    end
  end

  defp faststart_cache_path(video_path) do
    hash = :crypto.hash(:md5, video_path) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    %{size: size, mtime: mtime} = File.stat!(video_path)
    # Include size+mtime so cache invalidates if the source file changes
    key = :crypto.hash(:md5, "#{hash}:#{size}:#{:erlang.phash2(mtime)}") |> Base.encode16(case: :lower) |> binary_part(0, 16)
    Path.join(@faststart_cache, "#{key}#{Path.extname(video_path)}")
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
