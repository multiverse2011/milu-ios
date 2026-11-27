import AVFoundation
import SwiftUI

/// `AVSampleBufferDisplayLayer` を置くだけの入れ物。字幕の画像は映像のレイヤのすぐ上に置く。
struct VideoSurface: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    /// 埋め込みと全画面の両方が生きているとき、映像を持つのを全画面だけにする (3.5.3)
    var isActive = true
    var overlay: UIImage? = nil
    var overlayOffset: CGFloat = 0
    /// 操作の層を出している間の上下の暗いグラデーション (画面案の `.shade`)
    var shade = false

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.backgroundColor = .black
        view.hosted = isActive ? layer : nil
        view.overlayImage = overlay
        view.overlayOffset = overlayOffset
        view.shadeVisible = shade
        return view
    }

    func updateUIView(_ view: LayerHostView, context: Context) {
        view.hosted = isActive ? layer : nil
        view.overlayImage = overlay
        view.overlayOffset = overlayOffset
        view.shadeVisible = shade
    }
}

final class LayerHostView: UIView {
    var hosted: CALayer? {
        didSet {
            guard hosted !== oldValue else { return }
            // 自分が持っていたものだけ外す。ほかの入れ物へ移ったものは触らない
            if let old = oldValue, old.superlayer === videoView.layer {
                old.removeFromSuperlayer()
            }
            attach(hosted)
        }
    }
    var overlayImage: UIImage? {
        didSet {
            overlayView.image = overlayImage
            overlayView.isHidden = overlayImage == nil
        }
    }
    var overlayOffset: CGFloat = 0 {
        didSet {
            guard overlayOffset != oldValue, bounds.width > 0 else { return }
            // 操作の層の 0.2 秒のフェードに合わせて、字幕を跳ばさずに動かす
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.overlayView.frame = self.bounds.offsetBy(dx: 0, dy: self.overlayOffset)
            }
        }
    }
    var shadeVisible = false {
        didSet {
            guard shadeVisible != oldValue else { return }
            // 操作の層の 0.2 秒のフェードに合わせる
            UIView.animate(withDuration: 0.2) {
                self.shadeView.alpha = self.shadeVisible ? 1 : 0
            }
        }
    }

    private let videoView = UIView()
    private let shadeView = UIView()
    private let shadeLayer = CAGradientLayer()
    private let overlayView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        videoView.isUserInteractionEnabled = false
        shadeView.isUserInteractionEnabled = false
        shadeView.alpha = 0
        shadeLayer.colors = [
            UIColor.black.withAlphaComponent(0.45).cgColor,
            UIColor.clear.cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.7).cgColor,
        ]
        shadeLayer.locations = [0, 0.3, 0.55, 1]
        shadeView.layer.addSublayer(shadeLayer)
        overlayView.contentMode = .scaleToFill
        overlayView.isUserInteractionEnabled = false
        overlayView.isHidden = true
        addSubview(videoView)
        addSubview(shadeView)
        addSubview(overlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 全画面と埋め込みを行き来しても、同じレイヤを付け替えるだけにする (3.5.3)
    func attach(_ layer: CALayer?) {
        guard let layer else { return }
        if layer.superlayer !== videoView.layer {
            layer.removeFromSuperlayer()
            videoView.layer.addSublayer(layer)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoView.frame = bounds
        hosted?.frame = videoView.bounds
        shadeView.frame = bounds
        shadeLayer.frame = shadeView.bounds
        CATransaction.commit()
        // 大きさが変わったときだけ置き直す。offset の変更は上のアニメーションに任せる
        if overlayView.bounds.size != bounds.size {
            overlayView.frame = bounds.offsetBy(dx: 0, dy: overlayOffset)
        }
    }
}
