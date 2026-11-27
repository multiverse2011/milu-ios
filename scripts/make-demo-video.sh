#!/usr/bin/env bash
# デモモード用の fMP4 動画 (Milu/Demo/demo.mp4) を、自分で撮った動画から生成する。
# 使い方: ./scripts/make-demo-video.sh <元動画> [開始秒]
# 元動画は権利が自分にあるもの (iPhone で撮った映像と音) に限る。位置情報などのメタデータは落とす。
set -euo pipefail

SRC="${1:?元動画のパスを渡してください}"
START="${2:-40}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Milu/Demo/demo.mp4"
# 審査員や利用者が放送と取り違えないよう、左上に「サンプル映像」と焼き込む
FONT="$ROOT/Milu/Resources/Fonts/denpa-font.ttf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# iPhone の HDR (HLG) を SDR (bt709) にする。手元の ffmpeg には zscale がないため、
# H.264 プリセットで SDR にトーンマップする macOS 標準の avconvert に任せる
avconvert --source "$SRC" --preset Preset960x540 --output "$TMP/sdr.mp4" \
  --start "$START" --duration 31 --replace >/dev/null

# 896 フレーム (= 32 × 28 GOP、約 29.9 秒)・30fps・48kHz AAC。
# DemoStream は 32 フレームと 50 音声パケット (32/30 秒 = 50×1024/48000 秒) を 1 組でループする。
# ループの継ぎ目で音がぶつ切れにならないよう、頭と尻を 0.3 秒ずつフェードする。
# FMP4Demuxer が読む形式 (frag_keyframe + empty_moov + default_base_moof) に合わせる。
mise exec ffmpeg@latest -- ffmpeg -hide_banner -loglevel error \
  -i "$TMP/sdr.mp4" -map 0:v:0 -map 0:a:0 -map_metadata -1 \
  -vf "fps=30,drawtext=fontfile='$FONT':text='サンプル映像  SAMPLE':fontcolor=white:fontsize=26:x=24:y=24:box=1:boxcolor=black@0.55:boxborderw=12" \
  -af "aresample=48000,afade=t=in:d=0.3,afade=t=out:st=29.55:d=0.3" \
  -frames:v 896 -frames:a 1400 \
  -c:v libx264 -profile:v main -level 3.1 -pix_fmt yuv420p \
  -bf 0 -g 32 -keyint_min 32 -sc_threshold 0 -crf 27 -maxrate 1200k -bufsize 2400k \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
  -c:a aac -b:a 96k -ar 48000 -ac 2 \
  -movflags +frag_keyframe+empty_moov+default_base_moof \
  "$TMP/demo.mp4"

# 同梱ファイルを差し替える前に、ループの周期どおりの長さと、音が入っていること (無音でリジェクトされた) を確かめる
FF=(mise exec ffmpeg@latest --)
# 映像はデコードできたフレーム数、音声はパケット数 (DemoStream が数える単位) で確かめる
VIDEO="$("${FF[@]}" ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$TMP/demo.mp4")"
AUDIO="$("${FF[@]}" ffprobe -v error -count_packets -select_streams a:0 \
  -show_entries stream=nb_read_packets -of default=nw=1:nk=1 "$TMP/demo.mp4")"
MAX_DB="$("${FF[@]}" ffmpeg -hide_banner -nostats -i "$TMP/demo.mp4" -vn -af volumedetect -f null - 2>&1 \
  | sed -n 's/.*max_volume: \(.*\) dB$/\1/p')"
echo "video=$VIDEO frames, audio=$AUDIO packets, max_volume=$MAX_DB dB"
fail() {
  echo "$1ので、$OUT は差し替えない" >&2
  exit 1
}
# 形の分からない出力 (N/A・複数行など) は数として比べる前に止める
[[ "$VIDEO" =~ ^[0-9]+$ && "$AUDIO" =~ ^[0-9]+$ ]] || fail "フレーム数・パケット数が整数で取れない"
[[ "$MAX_DB" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || fail "max_volume が数で取れない"
[ "$VIDEO" -eq 896 ] && [ "$AUDIO" -ge 1400 ] && awk -v v="$MAX_DB" 'BEGIN { exit !(v + 0 > -40) }' \
  || fail "生成物が条件 (映像 896 フレーム・音声 1400 パケット以上・max_volume > -40 dB) を満たさない"

mv "$TMP/demo.mp4" "$OUT"
ls -lh "$OUT"
