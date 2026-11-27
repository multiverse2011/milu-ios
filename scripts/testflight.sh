#!/usr/bin/env bash
# iOS 用の配布ビルドを作り、App Store Connect にアップロードする。
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  internal) internal_only=true ;;
  candidate) internal_only=false ;;
  *) echo "使い方: $0 internal|candidate [--dry-run]" >&2; exit 2 ;;
esac
if [[ $# -gt 2 || (${2-} != --dry-run && $# -eq 2) ]]; then
  echo "使い方: $0 internal|candidate [--dry-run]" >&2
  exit 2
fi

# git status 自体の失敗を、変更なしと取り違えない。
if ! tree_status="$(git status --porcelain)"; then
  echo "git status に失敗しました。" >&2
  exit 1
fi
if [[ -n "$tree_status" ]]; then
  echo "リリースに含める変更をコミットしてから実行してください。" >&2
  exit 1
fi

# mise を activate していないシェルでも動くよう、scripts/app-store-screenshots.sh と同じく mise に頼る。
xcodegen=(xcodegen)
command -v xcodegen >/dev/null 2>&1 || xcodegen=(mise exec -- xcodegen)

team="${DEVELOPMENT_TEAM:-}"
build="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ || ! "$build" =~ ^[1-9][0-9]*$ ]]; then
  echo "DEVELOPMENT_TEAM (10 桁の Team ID) を指定し、BUILD_NUMBER は正の整数にしてください。" >&2
  exit 2
fi

provisioning_args=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
  if [[ ${ASC_KEY_PATH:-} != /* || ! -r ${ASC_KEY_PATH:-} ||
        -z ${ASC_KEY_ID:-} || -z ${ASC_ISSUER_ID:-} ]]; then
    echo "API 認証には読み取り可能な絶対パス ASC_KEY_PATH、ASC_KEY_ID、ASC_ISSUER_ID が必要です。" >&2
    exit 2
  fi
  provisioning_args+=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
elif [[ ${2-} != --dry-run ]]; then
  # 検査した IPA をそのまま上げる altool は、Xcode のアカウントを使えない。
  echo "アップロードには ASC_KEY_PATH、ASC_KEY_ID、ASC_ISSUER_ID が必要です。" >&2
  exit 2
fi

mkdir -p artifacts/testflight
lock=artifacts/testflight/.lock
# カーネルのロックなので、異常終了してもプロセスと一緒に解放される。
# 子として呼ばれたと名乗るだけでは信じず、親の lockf を起動したのが値の PID か確かめる。
if [[ -z ${_MILU_TESTFLIGHT_LOCK_HELD:-} || ${_MILU_TESTFLIGHT_LOCK_HELD} != "$(ps -o ppid= -p "$PPID" | tr -d ' ')" ]]; then
  status=0
  _MILU_TESTFLIGHT_LOCK_HELD=$$ BUILD_NUMBER="$build" \
    lockf -k -t 0 "$lock" "$PWD/scripts/testflight.sh" "$@" || status=$?
  # lockf はロックを取れないとき 75（EX_TEMPFAIL）で終わる。それ以外の lockf 自身の失敗は lockf が理由を出す。
  [[ $status -eq 75 ]] && echo "別の配布処理が実行中です。" >&2
  exit "$status"
fi

out="$PWD/artifacts/testflight/$build"
if [[ -e $out ]]; then
  echo "ビルド $build の作業ディレクトリが既にあります。別の BUILD_NUMBER を使ってください。" >&2
  exit 1
fi
mkdir "$out"

{
  echo "commit: $(git rev-parse HEAD)"
  echo "channel: $1"
  echo "build: $build"
  xcodebuild -version
  "${xcodegen[@]}" --version
} > "$out/manifest.txt"

# 終了時にも消さず、失敗した段階のログを残す。
run_logged() {
  local stage="$1"
  shift
  echo "$stage ($out/$stage.log)"
  if ! "$@" > "$out/$stage.log" 2>&1; then
    tail -40 "$out/$stage.log" >&2
    return 1
  fi
}

export_options="$out/export.plist"
cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>export</string>
<key>teamID</key><string>$team</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
<key>testFlightInternalTestingOnly</key><$internal_only/>
</dict></plist>
PLIST

run_logged generate "${xcodegen[@]}" generate
run_logged test xcodebuild test -scheme Milu \
  -destination "${TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 18 Pro}" \
  -derivedDataPath "$out/DerivedData" -resultBundlePath "$out/tests.xcresult"

archive="$out/Milu.xcarchive"
run_logged archive xcodebuild archive -scheme Milu -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -derivedDataPath "$out/DerivedData" "${provisioning_args[@]}" \
  DEVELOPMENT_TEAM="$team" CURRENT_PROJECT_VERSION="$build"

run_logged export xcodebuild -exportArchive -archivePath "$archive" \
  -exportPath "$out/export" -exportOptionsPlist "$export_options" "${provisioning_args[@]}"
ipa="$out/export/Milu.ipa"
run_logged unpack ditto -x -k "$ipa" "$out/verify"
app="$out/verify/Payload/Milu.app"
plist="$app/Info.plist"
read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$plist"
}

if [[ "$(read_plist CFBundleIdentifier)" != com.ayushio.milu ||
      "$(read_plist CFBundleVersion)" != "$build" ||
      "$(read_plist CFBundleSupportedPlatforms:0)" != iPhoneOS ||
      "$(read_plist ITSAppUsesNonExemptEncryption)" != false ]] ||
   ! read_plist UIBackgroundModes | grep -q '^[[:space:]]*audio$' ||
   ! cmp -s Milu/Demo/demo.mp4 "$app/demo.mp4"; then
  echo "配布用 IPA の ID、ビルド番号、プラットフォーム、暗号化申告、背景音声設定、デモ動画を確認してください。" >&2
  exit 1
fi
run_logged signature codesign --verify --deep --strict "$app"
echo verified > "$out/status.txt"
if [[ ${2-} == --dry-run ]]; then
  echo "配布用 IPA の検証完了: $ipa"
  exit 0
fi

run_logged upload xcrun altool --upload-app -f "$ipa" -t ios \
  --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH"
echo uploaded > "$out/status.txt"
echo "アップロード完了。App Store Connect でビルド $build の処理結果を確認してください。"
