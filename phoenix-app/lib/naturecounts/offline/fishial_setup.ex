defmodule Naturecounts.Offline.FishialSetup do
  @moduledoc """
  Auto-downloads Fishial model artifacts on startup if not present.
  """

  require Logger

  @model_dir "/models/fishial"

  @model_zip_url "https://storage.googleapis.com/fishial-ml-resources/classification_model_v0.10.zip"

  def ensure_model do
    model_dir = model_dir()

    # Try to create dir — may fail on read-only volumes
    case File.mkdir_p(model_dir) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[FishialSetup] Cannot create #{model_dir} (#{reason}) — volume may be read-only. Place model files on the host.")
    end

    writable? = writable?(model_dir)

    model_ckpt = Path.join(model_dir, "model.ckpt")
    database_pt = Path.join(model_dir, "database.pt")
    inference_py = Path.join(model_dir, "inference.py")

    missing = not File.exists?(model_ckpt) or not File.exists?(database_pt) or not File.exists?(inference_py)

    if missing and writable? do
      download_model(model_dir)
    end

    cond do
      not File.exists?(model_ckpt) ->
        Logger.warning("[FishialSetup] model.ckpt not found in #{model_dir}. Download the model zip and extract to the /models/fishial/ volume.")
        :error

      not File.exists?(database_pt) ->
        Logger.warning("[FishialSetup] database.pt not found in #{model_dir}.")
        :error

      not File.exists?(inference_py) ->
        Logger.warning("[FishialSetup] inference.py not found in #{model_dir}.")
        :error

      true ->
        Logger.info("[FishialSetup] Model ready at #{model_dir}")
        :ok
    end
  end

  def ready? do
    model_dir = model_dir()
    File.exists?(Path.join(model_dir, "model.ckpt")) and
      File.exists?(Path.join(model_dir, "database.pt")) and
      File.exists?(Path.join(model_dir, "inference.py"))
  end


  defp download_model(model_dir) do
    Logger.info("[FishialSetup] Downloading model from #{@model_zip_url}...")
    zip_path = Path.join(System.tmp_dir!(), "fishial_model.zip")

    case Req.get(@model_zip_url, receive_timeout: 300_000, into: File.stream!(zip_path)) do
      {:ok, %{status: 200}} ->
        Logger.info("[FishialSetup] Download complete, extracting...")
        extract_zip(zip_path, model_dir)
        File.rm(zip_path)

      {:ok, %{status: status}} ->
        Logger.warning("[FishialSetup] Failed to download model (HTTP #{status})")
        File.rm(zip_path)

      {:error, reason} ->
        Logger.warning("[FishialSetup] Failed to download model: #{inspect(reason)}")
        File.rm(zip_path)
    end
  end

  defp extract_zip(zip_path, dest_dir) do
    case System.cmd("unzip", ["-o", zip_path, "-d", dest_dir], stderr_to_stdout: true) do
      {_output, 0} ->
        # Find any .pt/.pth files and ensure one is named as expected
        extracted =
          dest_dir
          |> File.ls!()
          |> Enum.filter(fn f -> String.ends_with?(f, ".pt") or String.ends_with?(f, ".pth") end)

        Logger.info("[FishialSetup] Extracted #{length(extracted)} checkpoint(s) to #{dest_dir}")

      {output, code} ->
        Logger.warning("[FishialSetup] unzip failed (exit #{code}): #{output}")
    end
  end

  defp writable?(dir) do
    test_file = Path.join(dir, ".write_test")
    case File.write(test_file, "") do
      :ok -> File.rm(test_file); true
      _ -> false
    end
  end

  defp model_dir do
    System.get_env("FISHIAL_MODEL_DIR", @model_dir)
  end
end
