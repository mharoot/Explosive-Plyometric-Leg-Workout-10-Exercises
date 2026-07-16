#!/usr/bin/env bash
#
# gif-split.sh — Split a video into fixed-length GIFs (portrait + widescreen).
#
# For each N-second chunk of the input video it produces two GIFs:
#   <outdir>/portrait/0001.gif    (9:16)
#   <outdir>/widescreen/0001.gif  (16:9)
# ...numbered sequentially (0001, 0002, ...) until the video ends.
# The same sequence number lines up across both folders.
#
# Usage:
#   ./gif-split.sh <input-video> [output-dir]
#
# Examples:
#   ./gif-split.sh clip.mp4
#   ./gif-split.sh clip.mp4 my_gifs
#   SEGMENT=5 FPS=12 ./gif-split.sh clip.mp4        # override defaults via env vars

set -euo pipefail

# ------------------------------------------------------------------ config ----
# Any of these can be overridden on the command line, e.g. FPS=10 ./gif-split.sh
SEGMENT="${SEGMENT:-3}"          # seconds per GIF
FPS="${FPS:-15}"                 # GIF frame rate (lower = smaller files)
MODE="${MODE:-crop}"             # "crop" = fill frame (center-crop, no bars)
                                 # "pad"  = fit whole frame (adds black bars)

PORTRAIT_W="${PORTRAIT_W:-480}"  # portrait output size (9:16)
PORTRAIT_H="${PORTRAIT_H:-854}"
WIDE_W="${WIDE_W:-640}"          # widescreen output size (16:9)
WIDE_H="${WIDE_H:-360}"

# -------------------------------------------------------------------- args ----
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <input-video> [output-dir]" >&2
  exit 1
fi

INPUT="$1"
OUTDIR="${2:-gifs}"

if [ ! -f "$INPUT" ]; then
  echo "Error: input file '$INPUT' not found." >&2
  exit 1
fi

command -v ffmpeg >/dev/null 2>&1 || { echo "Error: ffmpeg not found in PATH." >&2; exit 1; }
# ffprobe is optional — if it's missing we read the duration from ffmpeg instead.

mkdir -p "$OUTDIR/portrait" "$OUTDIR/widescreen"

# -------------------------------------------------- duration & chunk count ----
# Read the video length in seconds. Prefer ffprobe; fall back to parsing the
# "Duration: HH:MM:SS.ms" line from ffmpeg's own output when ffprobe is absent.
get_duration () {
  if command -v ffprobe >/dev/null 2>&1; then
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT"
  else
    echo "Note: ffprobe not found; reading duration via ffmpeg." >&2
    local info
    info="$(ffmpeg -i "$INPUT" 2>&1 || true)"
    printf '%s\n' "$info" | awk -F'[:,]' '/Duration:/ {print $2*3600 + $3*60 + $4; exit}'
  fi
}

DURATION="$(get_duration)"
if [ -z "$DURATION" ] || [ "$DURATION" = "N/A" ] || [ "$DURATION" = "0" ]; then
  echo "Error: could not read duration of '$INPUT'." >&2
  exit 1
fi

# number of chunks = ceil(duration / SEGMENT)
SEGMENTS="$(awk "BEGIN{d=$DURATION; s=$SEGMENT; n=int(d/s); if (d > n*s) n++; print n}")"

echo "Input:     $INPUT"
echo "Duration:  ${DURATION}s"
echo "Chunk len: ${SEGMENT}s   FPS: ${FPS}   Mode: ${MODE}"
echo "Chunks:    ${SEGMENTS}  ->  $((SEGMENTS * 2)) GIFs total"
echo

# ------------------------------------------------------------ filter graph ----
# Build the scaling/cropping part of the filter chain for a target W x H.
build_vf () {
  local w="$1" h="$2"
  if [ "$MODE" = "pad" ]; then
    # Fit the whole frame inside W x H, pad the rest with black bars.
    echo "fps=${FPS},scale=${w}:${h}:force_original_aspect_ratio=decrease,pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2,setsar=1"
  else
    # Center-crop to the target aspect ratio, then scale to exactly W x H.
    echo "fps=${FPS},crop='min(iw,ih*${w}/${h})':'min(ih,iw*${h}/${w})',scale=${w}:${h}:flags=lanczos"
  fi
}

PORTRAIT_VF="$(build_vf "$PORTRAIT_W" "$PORTRAIT_H")"
WIDE_VF="$(build_vf "$WIDE_W" "$WIDE_H")"

# Temp palette file (two-pass palette gives much better GIF quality).
PALETTE="$(mktemp -u).png"
trap 'rm -f "$PALETTE"' EXIT

# Make one GIF: start-time, output-path, filter-chain.
make_gif () {
  local start="$1" out="$2" vf="$3"
  # Pass 1 — generate an optimal color palette for this chunk.
  ffmpeg -hide_banner -loglevel error -y -ss "$start" -t "$SEGMENT" -i "$INPUT" \
    -vf "${vf},palettegen=stats_mode=diff" "$PALETTE"
  # Pass 2 — render the GIF using that palette.
  ffmpeg -hide_banner -loglevel error -y -ss "$start" -t "$SEGMENT" -i "$INPUT" -i "$PALETTE" \
    -lavfi "${vf}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" "$out"
}

# ------------------------------------------------------------------- loop ------
for (( i = 0; i < SEGMENTS; i++ )); do
  start="$(( i * SEGMENT ))"
  seq="$(printf '%04d' "$(( i + 1 ))")"
  printf '[%s] start=%ss\n' "$seq" "$start"
  make_gif "$start" "$OUTDIR/portrait/${seq}.gif"   "$PORTRAIT_VF"
  make_gif "$start" "$OUTDIR/widescreen/${seq}.gif" "$WIDE_VF"
done

echo
echo "Done."
echo "  Portrait   -> $OUTDIR/portrait/"
echo "  Widescreen -> $OUTDIR/widescreen/"
