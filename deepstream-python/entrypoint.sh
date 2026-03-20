#!/bin/bash
# Strip audio from source video files before running DeepStream.
# qtdemux errors fatally when audio pads are not linked.

set -e

INPUT_DIR="/videos"
PROCESSED_DIR="/videos/processed"
mkdir -p "$PROCESSED_DIR"

if [ -n "$SOURCE_URIS" ]; then
    NEW_URIS=""
    IFS=',' read -ra URIS <<< "$SOURCE_URIS"
    for uri in "${URIS[@]}"; do
        uri=$(echo "$uri" | xargs)  # trim whitespace
        if [[ "$uri" == file://* ]]; then
            filepath="${uri#file://}"
            filename=$(basename "$filepath")
            processed="$PROCESSED_DIR/$filename"
            if [ ! -f "$processed" ] || [ "$filepath" -nt "$processed" ]; then
                echo "Stripping audio from $filepath → $processed"
                ffmpeg -y -i "$filepath" -an -c:v copy "$processed" 2>/dev/null
            else
                echo "Using cached $processed"
            fi
            NEW_URIS="${NEW_URIS:+$NEW_URIS,}file://$processed"
        else
            NEW_URIS="${NEW_URIS:+$NEW_URIS,}$uri"
        fi
    done
    export SOURCE_URIS="$NEW_URIS"
    echo "Processed SOURCE_URIS: $SOURCE_URIS"
fi

exec python3 ds_fish_pipeline.py
