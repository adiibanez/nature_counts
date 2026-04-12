# deepstream-app-fish

DeepStream 6.0 inference configs for the fish detection pipeline.

## Model artifacts

Model files are **not stored in git**. They fall into four tiers:

| Tier | Files | Source | How to obtain |
|---|---|---|---|
| Source checkpoints | `*.pt`, `*.pth` | Upstream GitHub releases | `mix models.fetch` |
| ONNX exports | `*.onnx`, `*.onnx.data` | Derived from sources | `mix models.export` |
| TensorRT engines | `*.engine` | Built by DeepStream from ONNX | First DeepStream launch (cached) |
| Custom plugins | `libnvdsinfer_custom_impl_*.so` | Built from `nvdsinfer_custom_impl_*/` | `make` (see below) |

The manifest of source checkpoints lives in [`models.json`](models.json). To
add or update a model, edit the manifest and run `mix models.fetch` — the
script downloads via HTTPS, verifies SHA256, and pins the hash on first fetch.

## First-time setup

From the repo root:

```bash
cd phoenix-app
mix models.fetch          # download .pt/.pth from GitHub releases
mix models.export         # produce ONNX exports (needs python env)
cd ../deepstream-app-fish
( cd nvdsinfer_custom_impl_rfdetr && make )
( cd nvdsinfer_custom_impl_Yolo   && make )
```

The first DeepStream run will build the `.engine` files from the ONNX
(several minutes; cached on disk afterwards). Engine files are device-specific
and must never be committed.

## CI

Use `mix models.check` to verify all manifest entries are present and match
their pinned checksums without downloading.

## Updating a model

1. Bump the `url` and clear `sha256` (set to `null`) in `models.json`.
2. Run `mix models.fetch` — the new file is downloaded and the new hash is
   pinned automatically.
3. Review the diff to `models.json` and commit it.
