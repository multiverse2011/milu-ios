#!/usr/bin/env bash
# iOS と tvOS の配布ビルドを作り、App Store Connect にアップロードする。
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

# iOS と tvOS は同じ App ID・同じビルド番号で、別々の IPA として上げる。
# 両方を作って検査し終えてから上げる (片方だけ上がった状態を作らない)
platforms=(ios tvos)
# macOS の /bin/bash (3.2) でも動くよう、連想配列ではなく case で引く
platform_value() {
  case "$1:$2" in
    ios:sdk) echo ios ;;
    ios:test) echo "${TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 18 Pro}" ;;
    ios:archive) echo iOS ;;
    ios:supported) echo iPhoneOS ;;
    tvos:sdk) echo appletvos ;;
    tvos:test) echo "${TVOS_TEST_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (4th generation)}" ;;
    tvos:archive) echo tvOS ;;
    tvos:supported) echo AppleTVOS ;;
  esac
}

read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$plist"
}

for platform in "${platforms[@]}"; do
  dir="$out/$platform"
  mkdir "$dir"
  run_logged "$platform-test" xcodebuild test -scheme Milu \
    -destination "$(platform_value "$platform" test)" \
    -derivedDataPath "$dir/DerivedData" -resultBundlePath "$dir/tests.xcresult"

  archive="$dir/Milu.xcarchive"
  run_logged "$platform-archive" xcodebuild archive -scheme Milu -configuration Release \
    -destination "generic/platform=$(platform_value "$platform" archive)" -archivePath "$archive" \
    -derivedDataPath "$dir/DerivedData" "${provisioning_args[@]}" \
    DEVELOPMENT_TEAM="$team" CURRENT_PROJECT_VERSION="$build"

  run_logged "$platform-export" xcodebuild -exportArchive -archivePath "$archive" \
    -exportPath "$dir/export" -exportOptionsPlist "$export_options" "${provisioning_args[@]}"
  ipa="$dir/export/Milu.ipa"
  run_logged "$platform-unpack" ditto -x -k "$ipa" "$dir/verify"
  app="$dir/verify/Payload/Milu.app"
  plist="$app/Info.plist"

  if [[ "$(read_plist CFBundleIdentifier)" != com.ayushio.milu ||
        "$(read_plist CFBundleVersion)" != "$build" ||
        "$(read_plist CFBundleSupportedPlatforms:0)" != "$(platform_value "$platform" supported)" ||
        "$(read_plist ITSAppUsesNonExemptEncryption)" != false ]] ||
     ! cmp -s Milu/Demo/demo.mp4 "$app/demo.mp4"; then
    echo "$platform の配布用 IPA の ID、ビルド番号、プラットフォーム、暗号化申告、デモ動画を確認してください。" >&2
    exit 1
  fi
  # 背景音声は iOS だけ (tvOS の Info.plist は UIBackgroundModes を持たない)
  if [[ $platform == ios ]] && ! read_plist UIBackgroundModes | grep -q '^[[:space:]]*audio$'; then
    echo "ios の配布用 IPA の背景音声設定を確認してください。" >&2
    exit 1
  fi
  run_logged "$platform-signature" codesign --verify --deep --strict "$app"
done
echo verified > "$out/status.txt"
if [[ ${2-} == --dry-run ]]; then
  echo "配布用 IPA の検証完了: $out/ios/export/Milu.ipa $out/tvos/export/Milu.ipa"
  exit 0
fi

for platform in "${platforms[@]}"; do
  run_logged "$platform-upload" xcrun altool --upload-app -f "$out/$platform/export/Milu.ipa" \
    -t "$(platform_value "$platform" sdk)" \
    --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH"
  # 片方だけ上がって止まったときに、どこまで上がったかを残す
  echo "uploaded $platform" >> "$out/status.txt"
done
echo "アップロード完了。App Store Connect で iOS と tvOS のビルド $build の処理結果を確認してください。"
