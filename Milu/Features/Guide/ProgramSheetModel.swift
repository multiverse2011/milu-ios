import Foundation

/// 番組の詳細のシート (`ProgramSheetView`・`TVProgramView`) が使う側。
/// 番組表 (`GuideModel`) と検索 (`SearchModel`) のどちらからも同じシートを開く (3.5・D31)。
@MainActor
protocol ProgramSheetModel: AnyObject {
    func detail(_ item: GuideProgramItem) async -> ProgramDetail?
    func reserve(_ item: GuideProgramItem) async -> String?
    func cancel(_ item: GuideProgramItem) async -> String?
    func watchLive(_ item: GuideProgramItem)
    /// 予約・取り消しのあとの最新。見つからなければ `nil`
    func program(id: Int64) -> GuideProgramItem?
}
