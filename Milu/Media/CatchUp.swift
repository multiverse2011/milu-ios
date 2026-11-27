import Foundation

/// ライブの遅れの追いつき (3.2)。溜まりと速さから、次にすることだけを決める。
nonisolated enum CatchUpAction: Equatable, Sendable {
    /// 溜まりが 10 秒を超えた。捨てて次のキーフレームから映し直す
    case flushToKeyframe
    /// 速さを変える
    case setRate(Double)
    /// そのまま
    case keep
}

nonisolated enum CatchUp {
    /// 4 秒を超えたら 1.05 倍、10 秒を超えたら捨てる、4/3 秒を下回ったら 1 倍に戻す。
    nonisolated static func action(ahead: Double, rate: Float) -> CatchUpAction {
        if ahead > 10 { return .flushToKeyframe }
        if ahead > 4 { return rate == 1.05 ? .keep : .setRate(1.05) }
        if ahead < 4.0 / 3.0 { return rate == 1 ? .keep : .setRate(1) }
        return .keep
    }
}
