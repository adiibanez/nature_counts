defmodule Naturecounts.Pipeline.CameraPipeline do
  @moduledoc """
  Per-viewer Membrane pipeline for a camera stream.

  Supports two source modes:
    - {:rtsp, uri}  — connects to a live RTSP stream (e.g. DeepStream output)
    - {:file, path} — plays a local MP4 file, looping on EOS (fake camera)

  Both RTSP.Source and MP4.Demuxer use dynamic output pads — tracks are
  discovered at runtime and linked via handle_child_notification callbacks.
  """

  use Membrane.Pipeline

  require Logger

  @impl true
  def handle_init(_ctx, opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    source = Keyword.fetch!(opts, :source)
    signaling = Keyword.fetch!(opts, :signaling)

    Logger.info("CameraPipeline starting: camera=#{camera_id} source=#{inspect(source)}")

    spec = source_spec(source)
    {[spec: spec], %{camera_id: camera_id, source: source, signaling: signaling}}
  end

  # -- RTSP source: handle {:set_up_tracks, tracks} notification -----------

  @impl true
  def handle_child_notification({:set_up_tracks, tracks}, :rtsp_source, _ctx, state) do
    Logger.info("CameraPipeline #{state.camera_id}: RTSP tracks discovered: #{inspect(Enum.map(tracks, & &1.type))}")

    video_track = Enum.find(tracks, &(&1.type == :video))

    if video_track do
      spec =
        get_child(:rtsp_source)
        |> via_out(Pad.ref(:output, video_track.control_path))
        |> child(:realtimer, Membrane.Realtimer)
        |> child(:webrtc_sink, %Membrane.WebRTC.Sink{
          signaling: state.signaling,
          tracks: [:video],
          video_codec: :h264
        })

      {[spec: spec], state}
    else
      Logger.warning("CameraPipeline #{state.camera_id}: no video track found in RTSP stream")
      {[], state}
    end
  end

  # -- File source: handle {:new_tracks, tracks} from MP4 demuxer ----------

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :mp4_demuxer, _ctx, state) do
    Logger.info("CameraPipeline #{state.camera_id}: MP4 tracks discovered: #{inspect(Map.keys(tracks))}")

    video_track =
      Enum.find(tracks, fn {_id, %{content: content}} ->
        match?(%Membrane.H264{}, content)
      end)

    case video_track do
      {track_id, _track_info} ->
        spec =
          get_child(:mp4_demuxer)
          |> via_out(Pad.ref(:output, track_id))
          |> child(:realtimer, Membrane.Realtimer)
          |> child(:webrtc_sink, %Membrane.WebRTC.Sink{
            signaling: state.signaling,
            tracks: [:video],
            video_codec: :h264
          })

        {[spec: spec], state}

      nil ->
        Logger.warning("CameraPipeline #{state.camera_id}: no H264 track found in MP4")
        {[], state}
    end
  end

  @impl true
  def handle_child_notification(_notification, _element, _ctx, state) do
    {[], state}
  end

  # -- End of stream: loop file sources ------------------------------------

  @impl true
  def handle_element_end_of_stream(:webrtc_sink, _pad, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    case state.source do
      {:file, path} ->
        Logger.info("CameraPipeline #{state.camera_id}: file ended, looping #{path}")
        # Remove source elements and re-create them; webrtc_sink stays
        {[
           remove_children: [:file_source, :mp4_demuxer, :realtimer],
           spec: source_spec(state.source)
         ], state}

      _ ->
        {[], state}
    end
  end

  # -- Source specs (only the source part; output linking is dynamic) -------

  defp source_spec({:file, path}) do
    child(:file_source, %Membrane.File.Source{location: path})
    |> child(:mp4_demuxer, Membrane.MP4.Demuxer.ISOM)
  end

  defp source_spec({:rtsp, uri}) do
    child(:rtsp_source, %Membrane.RTSP.Source{
      stream_uri: uri,
      allowed_media_types: [:video],
      on_connection_closed: :send_eos
    })
  end
end
