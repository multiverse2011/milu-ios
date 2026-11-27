#!/usr/bin/env bash
# デモモードの UI テスト (MiluScreenshots スキーム / MiluUITests) を回し、
# App Store Connect 用のスクリーンショット PNG を取り出す。
# -MiluUITestDemo で隔離するのは接続先とトークンだけで、画面のモデルは .standard を使う。
# 使い方:
#   ./scripts/app-store-screenshots.sh [--device iphone|ipad] [--language ja|en] [出力先ディレクトリ]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/DerivedData"
SCHEME="MiluScreenshots"
DEVICES="${DEVICES:-}"
MILU_SCREENSHOT_LANGUAGE="${MILU_SCREENSHOT_LANGUAGE:-ja}"
OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      DEVICES="${DEVICES:+$DEVICES }$2"
      shift 2
      ;;
    --language)
      MILU_SCREENSHOT_LANGUAGE="$2"
      shift 2
      ;;
    *)
      OUT_DIR="$1"
      shift
      ;;
  esac
done

case "$MILU_SCREENSHOT_LANGUAGE" in
  ja|en) ;;
  *)
    echo "Unknown language: $MILU_SCREENSHOT_LANGUAGE (expected: ja, en)" >&2
    exit 1
    ;;
esac

DEVICES="${DEVICES:-iphone ipad}"
if [[ -z "$OUT_DIR" ]]; then
  if [[ "$MILU_SCREENSHOT_LANGUAGE" != "ja" ]]; then
    OUT_DIR="$ROOT/screenshots/$MILU_SCREENSHOT_LANGUAGE"
  else
    OUT_DIR="$ROOT/screenshots"
  fi
fi
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/milu-screenshots.XXXXXX")"

DEFAULT_IPHONE_UDID="20C1993B-E9A1-41A3-B514-BDE95B8122D7" # iPhone 18 Pro Max (6.9 インチ)
DEFAULT_IPAD_UDID="3FAD10AF-A3EB-41C4-AD5A-3F3124C1686D"   # iPad Pro 13-inch (M5)

OVERRIDDEN_UDIDS=()
BOOTED_BY_SCRIPT=()

cleanup() {
  for udid in "${OVERRIDDEN_UDIDS[@]:-}"; do
    [[ -n "$udid" ]] && xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true
  done
  for udid in "${BOOTED_BY_SCRIPT[@]:-}"; do
    [[ -n "$udid" ]] && xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

resolve_udid() {
  local preferred="$1"
  local fallback_name="$2"
  /usr/bin/python3 - "$preferred" "$fallback_name" <<'PY'
import json, subprocess, sys

preferred, fallback_name = sys.argv[1], sys.argv[2]
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
data = json.loads(raw).get("devices", {})
all_devices = [d for group in data.values() for d in group if d.get("isAvailable", True)]

for d in all_devices:
    if d.get("udid") == preferred:
        print(d["udid"])
        sys.exit(0)

for d in all_devices:
    if fallback_name in d.get("name", ""):
        print(d["udid"])
        sys.exit(0)

sys.exit(1)
PY
}

device_state() {
  local target_udid="$1"
  /usr/bin/python3 - "$target_udid" <<'PY'
import json, subprocess, sys

target = sys.argv[1]
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
for group in json.loads(raw).get("devices", {}).values():
    for d in group:
        if d.get("udid") == target:
            print(d.get("state", "Shutdown"))
            sys.exit(0)
print("Unknown")
PY
}

echo "==> Generating Xcode project..."
if command -v xcodegen >/dev/null 2>&1; then
  (cd "$ROOT" && xcodegen generate)
else
  (cd "$ROOT" && mise exec -- xcodegen generate)
fi

TARGETS=()
BUILD_UDID=""
for dev in $DEVICES; do
  case "$dev" in
    iphone)
      IPHONE_UDID="${IPHONE_UDID:-$(resolve_udid "$DEFAULT_IPHONE_UDID" "iPhone 18 Pro Max")}"
      TARGETS+=("iphone-6.9:$IPHONE_UDID")
      [[ -z "$BUILD_UDID" ]] && BUILD_UDID="$IPHONE_UDID"
      ;;
    ipad)
      IPAD_UDID="${IPAD_UDID:-$(resolve_udid "$DEFAULT_IPAD_UDID" "iPad Pro 13-inch")}"
      TARGETS+=("ipad-13:$IPAD_UDID")
      [[ -z "$BUILD_UDID" ]] && BUILD_UDID="$IPAD_UDID"
      ;;
    *)
      echo "Unknown target in DEVICES: $dev (expected: iphone, ipad)" >&2
      exit 1
      ;;
  esac
done

echo "==> Building $SCHEME..."
xcodebuild build-for-testing \
  -project "$ROOT/Milu.xcodeproj" \
  -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "platform=iOS Simulator,id=$BUILD_UDID" \
  -quiet

capture_device() {
  local label="$1"
  local udid="$2"
  local xcresult="$WORK_DIR/$label.xcresult"
  local raw_export="$WORK_DIR/$label-raw"
  local dest_dir="$OUT_DIR/$label"

  echo "==> Preparing simulator $label ($udid)..."
  local initial_state
  initial_state="$(device_state "$udid")"
  if [[ "$initial_state" != "Booted" ]]; then
    xcrun simctl boot "$udid"
    BOOTED_BY_SCRIPT+=("$udid")
  fi
  xcrun simctl bootstatus "$udid" -b

  # デモデータは実時刻を基準に作られるため、時計は上書きせず電波・電池だけ整える
  xcrun simctl status_bar "$udid" override \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 \
    --batteryState discharging \
    --batteryLevel 100
  OVERRIDDEN_UDIDS+=("$udid")

  echo "==> Running screenshot UI test on $label ($udid, language=$MILU_SCREENSHOT_LANGUAGE)..."
  rm -rf "$xcresult" "$raw_export"
  TEST_RUNNER_MILU_SCREENSHOT_LANGUAGE="$MILU_SCREENSHOT_LANGUAGE" \
    xcodebuild test-without-building \
    -project "$ROOT/Milu.xcodeproj" \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=iOS Simulator,id=$udid" \
    -only-testing:MiluUITests/AppStoreScreenshotsTests/testCaptureAppStoreScreenshots \
    -resultBundlePath "$xcresult" \
    -quiet

  xcrun simctl status_bar "$udid" clear

  echo "==> Exporting PNG attachments for $label..."
  mkdir -p "$raw_export" "$dest_dir"
  xcrun xcresulttool export attachments \
    --path "$xcresult" \
    --output-path "$raw_export"

  /usr/bin/python3 - "$raw_export" "$dest_dir" <<'PY'
import json, pathlib, shutil, sys

raw_dir = pathlib.Path(sys.argv[1])
dest_dir = pathlib.Path(sys.argv[2])
manifest = json.loads((raw_dir / "manifest.json").read_text(encoding="utf-8"))

expected = [
    "01-recordings",
    "02-recording-player",
    "03-guide",
    "04-program-detail",
    "05-live",
    "06-settings",
]
saved = set()

entries = manifest if isinstance(manifest, list) else manifest.get("attachments", [])
for test_entry in entries:
    attachments = test_entry.get("attachments", [test_entry]) if isinstance(test_entry, dict) else []
    for att in attachments:
        suggested = att.get("suggestedHumanReadableName", "")
        exported = att.get("exportedFileName", "")
        if not exported:
            continue
        for key in expected:
            if suggested.startswith(key):
                src = raw_dir / exported
                dst = dest_dir / f"{key}.png"
                shutil.copy2(src, dst)
                saved.add(key)

missing = [k for k in expected if k not in saved]
if missing:
    raise SystemExit(f"Missing exported screenshots: {missing}")

for k in expected:
    p = dest_dir / f"{k}.png"
    print(f"  {p}")
PY
}

for entry in "${TARGETS[@]}"; do
  capture_device "${entry%%:*}" "${entry#*:}"
done

echo "==> Done. Screenshots saved under: $OUT_DIR"
