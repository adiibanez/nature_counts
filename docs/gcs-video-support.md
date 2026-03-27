# GCS Video Support — Design Document

## Goal

Enable the platform to browse, seek, and process videos stored in Google Cloud Storage,
in addition to (not replacing) local `/videos` filesystem storage. This is foundational
for evolving toward a P2P marine monitoring platform where multiple stations share video
through a common cloud bucket.

## Current Architecture

### Storage
- Videos live on local filesystem at `/videos` (Docker volume, hardcoded as `@videos_root`)
- `VideoController.show/2` serves files with HTTP Range support (`send_file/5`)
- `VideosLive` lists videos by scanning the local directory with `File.ls!/1`
- `ProcessVideoWorker` passes `video.path` (local path) to `PythonBridge.run/3`
- Python opens videos with `cv2.VideoCapture(video_path)` — expects a local file
- `MetricsScanner` also uses `cv2.VideoCapture` on local paths

### Key Integration Points

| Component | File | Coupling to local FS |
|-----------|------|---------------------|
| Video listing | `videos_live.ex` (`list_dir/2`) | `File.ls!`, `File.stat`, `File.dir?` |
| Video playback | `video_controller.ex` | `File.exists?`, `File.stat!`, `send_file` |
| Detection pipeline | `python_bridge.ex` | `File.exists?`, `cv2.VideoCapture(path)` |
| Metrics scanning | `metrics_scanner.ex` | `os.listdir`, `cv2.VideoCapture` |
| Video deletion | `videos_live.ex` | `File.rm` |
| Video DB record | `video.ex` schema | `path` column stores local path |

## Design: GCS as a Video Source

### Approach: Signed URL Streaming + Local Cache for Processing

GCS videos cannot be opened directly by `cv2.VideoCapture`. Two strategies handle this:

1. **Browsing & playback**: Generate GCS signed URLs and redirect the browser.
   The browser/video player fetches bytes directly from GCS (supports Range requests natively).

2. **Processing**: Download GCS video to a local temp file before running the detection
   pipeline. Delete after processing (or keep as cache with TTL).

### Storage Abstraction

Introduce a `Naturecounts.Storage` behaviour that both local and GCS backends implement:

```elixir
defmodule Naturecounts.Storage do
  @type entry :: %{name: String.t(), type: :file | :directory, size: integer(), updated_at: DateTime.t()}

  @callback list_dir(path :: String.t()) :: {:ok, [entry()]} | {:error, term()}
  @callback playback_url(path :: String.t()) :: {:ok, String.t()}
  @callback ensure_local(path :: String.t()) :: {:ok, local_path :: String.t()} | {:error, term()}
  @callback delete(path :: String.t()) :: :ok | {:error, term()}
  @callback exists?(path :: String.t()) :: boolean()
end
```

**Backends:**
- `Naturecounts.Storage.Local` — wraps current `File.*` calls (no behavior change)
- `Naturecounts.Storage.GCS` — uses `goth` + `Req` for GCS JSON/XML API

### Video Schema Changes

The `videos.path` column currently stores a local path like `/videos/reef-survey.mp4`.
For GCS videos, this becomes a URI: `gcs://bucket-name/prefix/reef-survey.mp4`.

```elixir
# video.ex — add field
field :storage_backend, :string, default: "local"  # "local" | "gcs"
```

The `path` field stores:
- Local: `/videos/reef-survey.mp4`
- GCS: `gs://my-bucket/videos/reef-survey.mp4`

A helper resolves the backend:

```elixir
def storage_module(%Video{storage_backend: "gcs"}), do: Naturecounts.Storage.GCS
def storage_module(_video), do: Naturecounts.Storage.Local
```

### Component Changes

#### 1. VideosLive — Browsing

Currently scans local filesystem. Add a source selector (local / GCS) in the UI.
When GCS is selected, call `Storage.GCS.list_dir(prefix)` to list objects.

- Directory navigation maps to GCS prefixes (GCS has no real directories)
- File metadata (size, last modified) comes from GCS object metadata
- Existing sort/filter logic works unchanged on the entry structs

#### 2. VideoController — Playback / Seeking

For GCS videos, generate a signed URL and redirect:

```elixir
def show(conn, %{"path" => path_segments}) do
  # ... resolve video ...
  case Video.storage_module(video) do
    Storage.Local -> send_file(conn, ...)  # existing logic
    Storage.GCS ->
      {:ok, url} = Storage.GCS.playback_url(path)
      redirect(conn, external: url)
  end
end
```

GCS signed URLs support Range requests natively, so the browser `<video>` element
can seek freely without any proxy logic.

Signed URL TTL: 1 hour (re-generated on each page load).

#### 3. ProcessVideoWorker — Processing

Before running detection, ensure the video is local:

```elixir
{:ok, local_path} = Video.storage_module(video) |> apply(:ensure_local, [video.path])
PythonBridge.run(local_path, profile, ...)
```

`ensure_local/1` for GCS downloads the object to `/tmp/gcs_cache/` and returns the
temp path. For local backend, it's a no-op returning the path as-is.

Cache strategy: keep downloaded files for 24h, LRU eviction when cache exceeds
a configurable size (default 50 GB). This avoids re-downloading when reprocessing.

#### 4. MetricsScanner — Scanning

Same pattern as ProcessVideoWorker: `ensure_local` before `cv2.VideoCapture`.
Consider scanning only on-demand for GCS videos (not batch-scanning a whole bucket).

### GCS Authentication

Use `goth` library for Google auth. Supports:
- Service account JSON key (file path or env var)
- Workload identity (GKE)
- Application default credentials (`gcloud auth application-default login`)

Config:

```elixir
# runtime.exs
config :naturecounts, Naturecounts.Storage.GCS,
  bucket: System.get_env("GCS_BUCKET"),
  credentials: System.get_env("GOOGLE_APPLICATION_CREDENTIALS"),
  prefix: System.get_env("GCS_PREFIX", ""),
  cache_dir: System.get_env("GCS_CACHE_DIR", "/tmp/gcs_cache"),
  cache_max_bytes: String.to_integer(System.get_env("GCS_CACHE_MAX_GB", "50")) * 1_000_000_000
```

### Dependencies

```elixir
# mix.exs
{:goth, "~> 1.4"},       # Google auth (OAuth2 + service accounts)
# Req is already a dependency — use it for GCS REST API calls
```

No need for the full `google_api_storage` client. The GCS JSON API is simple enough
to call directly with `Req` + `goth` tokens:

- List: `GET https://storage.googleapis.com/storage/v1/b/{bucket}/o?prefix={prefix}&delimiter=/`
- Download: `GET https://storage.googleapis.com/storage/v1/b/{bucket}/o/{object}?alt=media`
- Signed URL: generate with `goth` credentials (HMAC or RSA)

### New Files

```
lib/naturecounts/storage.ex                  # Behaviour
lib/naturecounts/storage/local.ex            # Local backend (extract from existing code)
lib/naturecounts/storage/gcs.ex              # GCS backend
lib/naturecounts/storage/gcs_cache.ex        # Local download cache with TTL/LRU
priv/repo/migrations/xxx_add_storage_backend.exs
```

### UI Changes (VideosLive)

- Add source toggle: "Local" | "GCS" (only shown when GCS is configured)
- GCS bucket/prefix shown in breadcrumbs
- Processing a GCS video shows download progress before detection starts
- No changes to inventory, crops, or other views (they work from DB data)

## What This Does NOT Cover

- Uploading local videos to GCS (future: P2P sync layer)
- Multi-node federation or P2P discovery
- GCS Pub/Sub notifications
- Streaming inference directly from GCS (always download-first)

## Implementation Order

1. Add `goth` dependency, configure GCS credentials
2. Implement `Storage` behaviour + `Storage.Local` (refactor existing code)
3. Implement `Storage.GCS` (list, signed URLs, download)
4. Implement `GCS Cache` (temp file management)
5. Add `storage_backend` to video schema + migration
6. Update `VideoController` for signed URL redirect
7. Update `VideosLive` with source selector + GCS browsing
8. Update `ProcessVideoWorker` and `MetricsScanner` to use `ensure_local`
9. Test with real GCS bucket
