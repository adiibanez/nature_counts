defmodule Naturecounts.Offline.MetricsScanner do
  @moduledoc """
  Video metrics scanner. Spawns a Python subprocess per video file
  so each gets its own GIL and memory — true parallelism.
  """

  require Logger

  @script_path Path.join(:code.priv_dir(:naturecounts), "python/scan_metrics.py")
  @timeout 300_000

  @doc """
  Scan a single video file. Returns `{:ok, result}` or `{:error, reason}`.
  """
  def scan_file(video_path, opts \\ []) do
    model_path = System.get_env("YOLO_MODEL_PATH", "/models/cfd-yolov12x-1.00.onnx")
    sample_frames = Keyword.get(opts, :sample_frames, 60)

    python = find_python()

    args = [
      @script_path,
      video_path,
      model_path,
      to_string(sample_frames)
    ]

    Logger.info("[MetricsScanner] Scanning #{Path.basename(video_path)} (#{sample_frames} frames)")

    try do
      {output, exit_code} = cmd_with_timeout(python, args, @timeout)

      case exit_code do
        0 ->
          parse_result(output, video_path)

        exit_code ->
          reason = extract_error(output, exit_code)
          Logger.error("[MetricsScanner] Failed #{Path.basename(video_path)}: #{reason}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("[MetricsScanner] Crash scanning #{Path.basename(video_path)}: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  @doc """
  Legacy scan interface for backwards compatibility with old batch workers.
  Scans files sequentially in one call.
  """
  def scan(directory, opts \\ []) do
    batch_files = Keyword.get(opts, :batch_files, [])
    force = Keyword.get(opts, :force, false)
    sample_frames = Keyword.get(opts, :sample_frames, 60)

    files =
      if batch_files != [] do
        Enum.map(batch_files, &Path.join(directory, &1))
      else
        list_video_files(directory, force)
      end

    total = length(files)
    scanned = Enum.count(files, fn path ->
      case scan_file(path, sample_frames: sample_frames) do
        {:ok, _} -> true
        _ -> false
      end
    end)

    {:ok, %{"scanned" => scanned, "total" => total, "skipped" => total - scanned}}
  end

  defp parse_result(output, video_path) do
    # Find the last line that looks like JSON
    json_line =
      output
      |> String.split("\n")
      |> Enum.reverse()
      |> Enum.find(&String.starts_with?(String.trim(&1), "{"))

    case json_line && Jason.decode(String.trim(json_line)) do
      {:ok, %{"status" => "ok"} = result} ->
        {:ok, result}

      {:ok, %{"error" => reason}} ->
        {:error, reason}

      _ ->
        Logger.warning("[MetricsScanner] No JSON output for #{Path.basename(video_path)}, raw: #{String.slice(output, 0, 200)}")
        {:error, "no valid output"}
    end
  end

  defp extract_error(output, exit_code) do
    json_line =
      output
      |> String.split("\n")
      |> Enum.reverse()
      |> Enum.find(&String.starts_with?(String.trim(&1), "{"))

    case json_line && Jason.decode(String.trim(json_line)) do
      {:ok, %{"error" => reason}} -> reason
      _ -> "exit code #{exit_code}: #{String.slice(output, -300, 300)}"
    end
  end

  defp find_python do
    # Check explicit env var first
    case System.get_env("PYTHON_PATH") do
      nil -> :skip
      "" -> :skip
      path -> if File.exists?(path), do: path
    end
    |> case do
      path when is_binary(path) ->
        path

      _ ->
        # Use Pythonx's managed venv — probe the build dir
        pythonx_venv =
          [:code.priv_dir(:pythonx)]
          |> Enum.map(&Path.join([to_string(&1), "uv", "project", ".venv", "bin", "python3"]))
          |> Enum.find(&File.exists?/1)

        pythonx_venv || System.find_executable("python3") || "python3"
    end
  end

  defp cmd_with_timeout(cmd, args, timeout_ms) do
    port =
      Port.open({:spawn_executable, System.find_executable(cmd)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: [{~c"PYTHONUNBUFFERED", ~c"1"}]
      ])

    collect_port_output(port, "", timeout_ms)
  end

  defp collect_port_output(port, acc, timeout_ms) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, acc <> data, timeout_ms)

      {^port, {:exit_status, status}} ->
        {acc, status}
    after
      timeout_ms ->
        # Kill the OS process
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} -> System.cmd("kill", ["-9", to_string(os_pid)])
          _ -> :ok
        end

        Port.close(port)
        {acc <> "\n[TIMEOUT after #{div(timeout_ms, 1000)}s]", 124}
    end
  end

  defp list_video_files(directory, force) do
    extensions = ~w(.mp4 .avi .mkv .mov .ts)

    case File.ls(directory) do
      {:ok, names} ->
        names
        |> Enum.filter(fn name ->
          ext = name |> Path.extname() |> String.downcase()
          path = Path.join(directory, name)
          File.regular?(path) and ext in extensions
        end)
        |> Enum.reject(fn name ->
          not force and File.exists?(Path.join(directory, name) <> ".metrics.json")
        end)
        |> Enum.map(&Path.join(directory, &1))
        |> Enum.sort()

      _ ->
        []
    end
  end
end
