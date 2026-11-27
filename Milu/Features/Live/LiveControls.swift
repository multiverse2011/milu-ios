import SwiftUI

/// ライブの操作の層の部品 (3.5・iPhone-Live・iPhone-LivePlayer)。

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
            Text("ライブ")
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct GlassCircleLabel: View {
    let systemName: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .glassEffect(.regular, in: .circle)
    }
}

struct GlassCircleButton: View {
    let systemName: String
    var size: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassCircleLabel(systemName: systemName, size: size)
        }
        .buttonStyle(.plain)
    }
}

/// ピクチャ・イン・ピクチャのボタン (#48)。ライブと録画で同じ絵にする
struct PictureInPictureButton: View {
    let active: Bool
    var size: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassCircleLabel(systemName: active ? "pip.exit" : "pip.enter", size: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "ピクチャ・イン・ピクチャを終了" : "ピクチャ・イン・ピクチャ")
    }
}

struct LiveRecordButton: View {
    let recording: Bool
    var height: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                Text(recording ? String(localized: "録画中") : String(localized: "録画 (操作)", defaultValue: "録画"))
                    .scaledFont(15, weight: .semibold)
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(Color.red.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct LiveProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(uiColor: .quaternaryLabel))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

/// 画質のメニュー (3.5・iPhone-LiveQuality)。「自動」の値にいまの形式を出す。
struct LiveQualityMenu: View {
    let model: LiveModel
    let session: PlaybackSession
    var size: CGFloat = 36

    var body: some View {
        Menu {
            // メニューを開いている間は操作の層を隠さない。タップは Menu が取るので、
            // 中身が出たときに知らせる
            Group {
                Section("画質") {
                    ForEach(session.qualityItems, id: \.title) { item in
                        Button {
                            model.selectQuality(item.codec)
                        } label: {
                            HStack {
                                if item.codec == session.selectedQuality {
                                    Image(systemName: "checkmark")
                                }
                                Text(item.title)
                                if item.codec == nil, let codec = session.currentCodec {
                                    Spacer()
                                    Text(PlaybackRules.codecName(codec))
                                }
                            }
                        }
                    }
                }
                if !session.rungItems.isEmpty {
                    Section("解像度") {
                        ForEach(session.rungItems, id: \.rung) { item in
                            Button {
                                model.selectRung(item.rung)
                            } label: {
                                HStack {
                                    if item.rung == session.selectedRung {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(item.title)
                                }
                            }
                        }
                    }
                }
            }
            .onAppear { model.noteMenuInteraction() }
        } label: {
            GlassCircleLabel(systemName: "ellipsis", size: size)
        }
        .accessibilityLabel("画質")
    }
}

/// 字幕と音声のメニュー (3.5・iPhone-CaptionMenu)。どちらも無ければ出さない。
struct LiveCaptionsMenu: View {
    let model: LiveModel
    let session: PlaybackSession
    var size: CGFloat = 36

    var body: some View {
        Menu {
            Group {
                if session.hasCaptions {
                    Section("字幕") {
                        Button {
                            model.setCaptionsOn(true)
                        } label: {
                            HStack {
                                if session.captionsOn { Image(systemName: "checkmark") }
                                Text("オン")
                            }
                        }
                        Button {
                            model.setCaptionsOn(false)
                        } label: {
                            HStack {
                                if !session.captionsOn { Image(systemName: "checkmark") }
                                Text("オフ")
                            }
                        }
                    }
                }
                if session.audioTracks.count > 1 {
                    Section("音声") {
                        ForEach(session.audioTracks, id: \.id) { track in
                            Button {
                                model.selectAudio(track)
                            } label: {
                                HStack {
                                    if track.id == session.selectedAudio?.id {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(track.label)
                                }
                            }
                        }
                    }
                }
            }
            .onAppear { model.noteMenuInteraction() }
        } label: {
            GlassCircleLabel(systemName: "captions.bubble", size: size)
        }
        .accessibilityLabel("字幕と音声")
    }
}
