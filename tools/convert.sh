#!/bin/sh
# Converts original Warlords Battlecry III assets that LÖVE cannot read
# directly (Bink videos, optionally sounds) into game/converted/.
# Requires ffmpeg (with libtheora + libvorbis) on PATH or via --ffmpeg.
#
# Usage: tools/convert.sh [--data "<game dir>"] [--ffmpeg <ffmpeg>] [--audio] [--no-video]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec love "$ROOT/game" --convert "$@"
