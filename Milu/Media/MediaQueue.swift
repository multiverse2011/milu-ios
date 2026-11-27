import Foundation

/// `Media/` の型を動かす 1 本の直列の列 (D11)。`CMSampleBuffer` を隔離をまたがせない。
nonisolated enum MediaQueue {
    static let media = DispatchQueue(label: "media")
}
