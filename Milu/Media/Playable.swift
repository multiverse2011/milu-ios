import CoreMedia
import VideoToolbox

/// この端末が再生できる形式 `P` (3.3)。起動したときに 1 度だけ調べる。
nonisolated enum Playable {
    static let formats: [OfferCodec] = PlaybackRules.playable(
        hevcSupported: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
        av1Supported: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    )

    static var query: String { formats.map(\.rawValue).joined(separator: ",") }
}
