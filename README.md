# Milu

録画サーバー denpa の iPhone・iPad・Apple TV 向けクライアントです。番組表・ライブ・録画の視聴・予約・検索ができます。サーバーがなくても、接続画面の「デモで試す」から全画面を試せます。

## 必要なもの

- Xcode 27（iOS 27 / tvOS 27 SDK）
- [mise](https://mise.jdx.dev)（XcodeGen を入れるため）
- denpa v2.45.0 以上

## ビルド

```bash
mise install          # XcodeGen を入れる
xcodegen generate     # project.yml から Milu.xcodeproj を作る
open Milu.xcodeproj
```

実機で動かすときは、Xcode の Signing & Capabilities で自分の Team を選び、必要なら `project.yml` の `bundleIdPrefix` を変えてください。

## テスト

```bash
xcodebuild test -project Milu.xcodeproj -scheme Milu \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

`MiluTests/Fixtures` の動画は `scripts/make-test-fixtures.sh` で作った合成映像です。

## ライセンス

[MIT](LICENSE)。同梱の Denpa Font（`Milu/Resources/Fonts/denpa-font.ttf`）は [SIL Open Font License 1.1](Milu/Resources/Fonts/OFL.txt) です。
