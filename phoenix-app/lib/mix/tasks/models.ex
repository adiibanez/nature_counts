defmodule Mix.Tasks.Models.Fetch do
  @moduledoc """
  Fetch model files declared in `deepstream-app-fish/models.json`.

      mix models.fetch              # download missing/mismatched files
      mix models.fetch --force      # re-download everything
      mix models.fetch --check      # verify only, no download (CI)
      mix models.fetch --role source

  On first download of an entry whose `sha256` is `null`, the computed hash is
  written back to `models.json`. Review the diff before committing.
  """
  use Mix.Task
  require Logger

  @shortdoc "Fetch model files declared in models.json"

  @switches [force: :boolean, check: :boolean, role: :string]

  @impl true
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: @switches)
    Application.ensure_all_started(:req)

    {manifest_path, manifest, models_dir} = Naturecounts.Models.Manifest.load!()
    entries = filter_role(manifest["models"], opts[:role])

    results =
      entries
      |> Task.async_stream(
        fn entry -> process(entry, models_dir, opts) end,
        max_concurrency: 2,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, r} -> r end)

    updated? = Enum.any?(results, &match?({:pinned, _}, &1))

    if updated? and opts[:check] != true do
      new_manifest = update_in(manifest, ["models"], &apply_pins(&1, results))
      Naturecounts.Models.Manifest.write!(manifest_path, new_manifest)
      Mix.shell().info("\nmodels.json updated with newly pinned sha256 values.")
      Mix.shell().info("Review the diff before committing.")
    end

    failed = for {:error, path, reason} <- results, do: {path, reason}

    if failed != [] do
      Enum.each(failed, fn {p, r} -> Mix.shell().error("  #{p}: #{r}") end)
      exit({:shutdown, 1})
    end
  end

  defp filter_role(models, nil), do: models
  defp filter_role(models, role), do: Enum.filter(models, &(&1["role"] == role))

  defp process(entry, dir, opts) do
    path = Path.join(dir, entry["path"])
    expected = entry["sha256"]
    check_only = opts[:check] || false
    force = opts[:force] || false

    cond do
      File.exists?(path) and not force ->
        case sha256_of(path) do
          ^expected when is_binary(expected) ->
            log(:ok, "#{entry["path"]} ✓")
            :ok

          actual when is_binary(expected) ->
            msg = "checksum mismatch (have #{short(actual)}, want #{short(expected)})"
            log(:warn, "#{entry["path"]} #{msg}")
            if check_only, do: {:error, path, msg}, else: download(entry, path, dir)

          actual when is_nil(expected) ->
            log(:info, "#{entry["path"]} present, pinning sha256")
            {:pinned, %{path: entry["path"], sha256: actual}}
        end

      check_only ->
        {:error, path, "missing"}

      true ->
        download(entry, path, dir)
    end
  end

  defp download(entry, path, dir) do
    File.mkdir_p!(dir)
    tmp = path <> ".tmp"
    File.rm(tmp)
    url = entry["url"]
    log(:info, "↓ #{entry["path"]}")

    case Req.get(url, into: File.stream!(tmp), connect_options: [timeout: 30_000], retry: :transient) do
      {:ok, %Req.Response{status: 200}} ->
        actual = sha256_of(tmp)
        File.rename!(tmp, path)
        expected = entry["sha256"]

        cond do
          is_nil(expected) ->
            log(:ok, "#{entry["path"]} ✓ (sha256 pinned: #{short(actual)})")
            {:pinned, %{path: entry["path"], sha256: actual}}

          actual == expected ->
            log(:ok, "#{entry["path"]} ✓")
            :ok

          true ->
            File.rm(path)
            {:error, path, "downloaded checksum #{short(actual)} ≠ expected #{short(expected)}"}
        end

      {:ok, %Req.Response{status: status}} ->
        File.rm(tmp)
        {:error, path, "HTTP #{status}"}

      {:error, reason} ->
        File.rm(tmp)
        {:error, path, inspect(reason)}
    end
  end

  defp apply_pins(models, results) do
    pins =
      for {:pinned, %{path: p, sha256: s}} <- results, into: %{}, do: {p, s}

    Enum.map(models, fn m ->
      case Map.get(pins, m["path"]) do
        nil -> m
        sha -> Map.put(m, "sha256", sha)
      end
    end)
  end

  defp sha256_of(path) do
    path
    |> File.stream!(2_097_152)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp short(<<a::binary-size(12), _::binary>>), do: a
  defp short(other), do: other

  defp log(:ok, msg), do: Mix.shell().info("  " <> msg)
  defp log(:info, msg), do: Mix.shell().info("  " <> msg)
  defp log(:warn, msg), do: Mix.shell().info("  ⚠ " <> msg)
end

defmodule Mix.Tasks.Models.Check do
  @moduledoc "Verify all model files are present and checksums match (CI)."
  use Mix.Task
  @shortdoc "Verify model files without downloading"

  @impl true
  def run(argv), do: Mix.Tasks.Models.Fetch.run(["--check" | argv])
end

defmodule Mix.Tasks.Models.Export do
  @moduledoc """
  Run ONNX export scripts for source checkpoints.

      mix models.export

  Invokes the `export_*.py` scripts in `deepstream-app-fish/`. Requires the
  Python environment with torch / ultralytics / rfdetr to be active.
  """
  use Mix.Task
  @shortdoc "Export ONNX from source checkpoints"

  @impl true
  def run(_argv) do
    {_, _, dir} = Naturecounts.Models.Manifest.load!()

    scripts = [
      "export_rfdetr_onnx.py",
      "export_yolov12_onnx.py"
    ]

    Enum.each(scripts, fn script ->
      path = Path.join(dir, script)

      if File.exists?(path) do
        Mix.shell().info("→ python #{script}")
        {out, status} = System.cmd("python", [script], cd: dir, stderr_to_stdout: true)
        IO.write(out)
        if status != 0, do: Mix.raise("#{script} failed (exit #{status})")
      else
        Mix.shell().info("  (skipped, missing: #{script})")
      end
    end)
  end
end
