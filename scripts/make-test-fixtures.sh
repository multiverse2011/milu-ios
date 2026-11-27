#!/usr/bin/env bash
# テスト用の fMP4 (MiluTests/Fixtures) を、ffmpeg の合成映像と正弦波から作る。
# 使い方: ./scripts/make-test-fixtures.sh [出力先]
set -euo pipefail
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/MiluTests/Fixtures}"
ff() { mise exec ffmpeg@9.0.2 -- ffmpeg -hide_banner -loglevel error -y "$@"; }
V=(-f lavfi -i testsrc2=size=1440x1080:rate=60000/1001)
A=(-f lavfi -i sine=frequency=440:sample_rate=48000)
# denpa の出力に合わせる: 1440x1080 (SAR 4:3)、bt709 の TV レンジ、timescale 60000、AAC 48kHz ステレオ、50ms ごとの fragment
COMMON=(-vf setsar=4/3,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv -pix_fmt yuv420p
  -video_track_timescale 60000 -c:a aac -ac 2 -b:a 96k
  -frag_duration 50000 -movflags +write_colr+empty_moov+default_base_moof -fflags +bitexact -map_metadata -1 -t 3)
X264=(-c:v libx264 -profile:v high -level 4.0 -crf 28 -g 30 -bf 0)
mkdir -p "$OUT"
ff "${V[@]}" "${A[@]}" "${X264[@]}" "${COMMON[@]}" "$OUT/live-h264.mp4"
# chase は tfdt が 0 から始まる (live と同じ形)
cp "$OUT/live-h264.mp4" "$OUT/chase-h264.mp4"
# 録画の stream は映像の tfdt が録画の時刻 (最初のキーフレーム) から始まる。ffmpeg は映像の始まりを
# ずらすと最初のフレームを伸ばして tfdt を 0 にするので、映像 (track 1) の tfdt に 0.6248 秒 (37488/60000) を足す
python3 -I -c '
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
def walk(start, end, track=None):
    at = start
    while at + 8 <= end:
        size, kind = struct.unpack(">I4s", data[at:at + 8])
        assert size >= 8, "64bit の box は想定していない"
        if kind in (b"moof", b"traf"):
            walk(at + 8, at + size)
        elif kind == b"tfhd":
            track = struct.unpack(">I", data[at + 12:at + 16])[0]
        elif kind == b"tfdt" and track == 1:
            assert data[at + 8] == 1, "tfdt は version 1 のはず"
            value = struct.unpack(">Q", data[at + 12:at + 20])[0]
            data[at + 12:at + 20] = struct.pack(">Q", value + 37488)
        at += size
walk(0, len(data))
open(sys.argv[2], "wb").write(data)
' "$OUT/live-h264.mp4" "$OUT/stream-h264.mp4"
ff "${V[@]}" "${A[@]}" -c:v libx265 -tag:v hvc1 -x265-params log-level=error:keyint=30:bframes=0 -crf 32 "${COMMON[@]}" "$OUT/live-hevc.mp4"
