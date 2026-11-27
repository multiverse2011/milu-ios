import Foundation

/// デモモードで返す架空の放送局・番組表・録画データ。
/// 実在の放送局名・番組名は使わない。
nonisolated enum DemoData {
    struct StationSpec: Sendable {
        let id: Int64
        let key: Int
        let name: String
    }

    struct SlotSpec: Sendable {
        let durationMinutes: Int
        let title: String
        let summary: String
        let detail: String
        let cast: String
        let lv1: Int
        let lv2: Int
    }

    struct ProgramRecord: Sendable {
        let id: Int64
        let station: StationSpec
        let title: String
        let summary: String
        let detail: String
        let cast: String
        let lv1: Int
        let lv2: Int
        let startAt: Int64
        let endAt: Int64
        let reserved: Bool
    }

    struct RecordingSpec: Sendable {
        let id: Int64
        let stationID: Int64
        let title: String
        /// 基準時刻から何分前に始まったか
        let minutesAgo: Int
        let durationMinutes: Int
        /// 途中まで観た分 (`nil` なら未視聴または視聴済み)
        let resumeMinutes: Int?
        /// 視聴済みか
        let watched: Bool
        let summary: String
        let detail: String
        let cast: String
    }

    static let stations: [StationSpec] = [
        StationSpec(id: 101, key: 1, name: "ほしぞら放送"),
        StationSpec(id: 102, key: 3, name: "あおばTV"),
        StationSpec(id: 103, key: 5, name: "こもれび放送"),
        StationSpec(id: 104, key: 7, name: "うみかぜテレビ"),
    ]

    static let recordingSpecs: [RecordingSpec] = [
        RecordingSpec(
            id: 9001,
            stationID: 101,
            title: "ドラマ「ひだまり荘の人々」 #8「屋上の約束」",
            minutesAgo: 150,
            durationMinutes: 30,
            resumeMinutes: nil,
            watched: false,
            summary: "古い木造アパートに暮らす住人たちの、穏やかな日常を描く群像ドラマ。",
            detail: "屋上の物干し台を修理することになった住人たち。管理人の古い工具箱から見つかった手紙をきっかけに、30年前の約束が動き出す。",
            cast: "水野はるか、橘けんじ、佐伯みどり ほか"
        ),
        RecordingSpec(
            id: 9002,
            stationID: 102,
            title: "アニメ「星屑ステーション」 #9「はじまりの駅」",
            minutesAgo: 270,
            durationMinutes: 30,
            resumeMinutes: 19,
            watched: false,
            summary: "銀河の片隅にある小さな無人駅を舞台にしたファンタジーアニメ。",
            detail: "年に一度だけ停車する夜行列車を待つ駅員見習いのソラ。霧の向こうから現れた乗客は、行き先の書かれていない切符を手にしていた。",
            cast: "声: 青葉りん、白石かなた、森川たくみ"
        ),
        RecordingSpec(
            id: 9003,
            stationID: 103,
            title: "ドキュメント 灯りの仕事「港の夜明け」",
            minutesAgo: 420,
            durationMinutes: 60,
            resumeMinutes: nil,
            watched: false,
            summary: "眠らない港町を支える人々の、夜から朝までの仕事を見つめる。",
            detail: "午前3時、まだ暗い岸壁に灯りがともる。市場の競り人、連絡船の機関士、港の食堂の店主まで、夜明け前の6時間を追った。",
            cast: "語り: 篠原あおい"
        ),
        RecordingSpec(
            id: 9004,
            stationID: 104,
            title: "港町レシピ帖 #12「季節のスープと焼き立てパン」",
            minutesAgo: 1380,
            durationMinutes: 30,
            resumeMinutes: nil,
            watched: true,
            summary: "海辺の小さな台所から届ける、旬の食材を使った家庭料理の番組。",
            detail: "朝採れの根菜をじっくり煮込んだポタージュと、フライパンで手軽に焼ける丸パンを紹介。余ったスープのアレンジも実演する。",
            cast: "料理: 風間なおこ"
        ),
        RecordingSpec(
            id: 9005,
            stationID: 102,
            title: "クイズ！ことばの迷宮スペシャル",
            minutesAgo: 1560,
            durationMinutes: 60,
            resumeMinutes: 24,
            watched: false,
            summary: "身近な言葉の由来や言い回しをパズルで解き明かす知識バラエティ。",
            detail: "日常で何気なく使っている言葉の意外な語源や、地域によって意味が変わる表現を早押しと並べ替えクイズで競う1時間スペシャル。",
            cast: "司会: 楠木まこと、川瀬ゆい"
        ),
        RecordingSpec(
            id: 9006,
            stationID: 101,
            title: "ミュージック・アトリエ「弦楽の夕べ」",
            minutesAgo: 1740,
            durationMinutes: 30,
            resumeMinutes: nil,
            watched: false,
            summary: "スタジオでの生演奏とトークで綴る音楽番組。",
            detail: "木のぬくもりを感じる小ホールから、弦楽四重奏によるオリジナル組曲を収録。楽器づくりの工房を訪ねるミニコーナーも。",
            cast: "演奏: こもれびカルテット"
        ),
        RecordingSpec(
            id: 9007,
            stationID: 104,
            title: "サッカー みなとカップ 決勝ハイライト",
            minutesAgo: 2940,
            durationMinutes: 60,
            resumeMinutes: nil,
            watched: true,
            summary: "白熱したみなとカップ決勝戦の全ゴールと舞台裏を振り返る。",
            detail: "延長戦までもつれ込んだ決勝の名場面を戦術解説とともにたっぷりと紹介。試合後の選手インタビューも収録。",
            cast: "解説: 矢島たつや / 実況: 瀬戸こうへい"
        ),
        RecordingSpec(
            id: 9008,
            stationID: 103,
            title: "サイエンス窓「深海の小さな光」",
            minutesAgo: 3180,
            durationMinutes: 30,
            resumeMinutes: nil,
            watched: false,
            summary: "自然や科学の不思議を実験と映像でわかりやすく紐解く教養番組。",
            detail: "太陽の光が届かない深海で、自ら光を放つ生きものたち。発光する仕組みと、光を使った驚きのコミュニケーションに迫る。",
            cast: "案内: 桐谷しおり（海洋生物研究者）"
        ),
    ]

    // 各局の 24 時間 (04:00〜翌 04:00 = 1440 分) を隙間なく埋める編成テンプレート
    private static let stationTemplates: [Int64: [SlotSpec]] = [
        101: [
            SlotSpec(durationMinutes: 120, title: "あさ一番ニュース", summary: "けさのニュースと各地の天気をまとめてお伝えします。", detail: "国内外の最新ニュース、暮らしに関わる経済の動き、全国の詳しい気象情報をわかりやすく届けます。", cast: "キャスター: 藤井まさと、朝倉みお", lv1: 0, lv2: 0),
            SlotSpec(durationMinutes: 120, title: "モーニング・テラス", summary: "暮らしに役立つ特集と季節の話題を届ける朝の情報番組。", detail: "旬の食材の選び方から街の新しい取り組みまで、生活にすぐ使えるヒントをスタジオ実演を交えて紹介。", cast: "司会: 萩原けん、小春あや", lv1: 2, lv2: 2),
            SlotSpec(durationMinutes: 60, title: "まちかど散歩道", summary: "気ままに歩いて、町の小さな名店や風景を訪ねる紀行番組。", detail: "坂道の多い港町をぶらり歩き。路地裏の古書店や、地元で愛される豆腐店を訪ねて人々の暮らしに触れる。", cast: "旅人: 柳田そうた", lv1: 10, lv2: 0),
            SlotSpec(durationMinutes: 120, title: "ひるどきワイド", summary: "お昼のニュースと地域からの生中継。", detail: "正午のニュースに続き、各地の旬の話題を中継で結ぶ2時間枠。視聴者から届いた季節の写真も紹介。", cast: "進行: 氷室あかね", lv1: 2, lv2: 0),
            SlotSpec(durationMinutes: 60, title: "昼ドラ「風見鶏の丘」", summary: "丘の上の小さな時計店を舞台にしたヒューマンドラマ。", detail: "壊れた懐中時計を持ち込んだ客との対話から、持ち主の思い出を辿っていく一話完結の物語。", cast: "出演: 椎名れん、若葉ことね", lv1: 3, lv2: 0),
            SlotSpec(durationMinutes: 120, title: "午後のシネマ館「月夜の灯台」", summary: "岬の灯台守と旅の青年が過ごすひと夏を描いた名作映画。", detail: "静かな入り江の灯台を訪れた青年が、灯台守の仕事を手伝いながら自分自身の歩みを見つめ直していく。", cast: "監督: 高瀬みのる / 出演: 鳴海しんじ ほか", lv1: 6, lv2: 1),
            SlotSpec(durationMinutes: 120, title: "ゆうがたニュースプラス", summary: "きょう一日の出来事と明日の天気を詳しく解説。", detail: "夕方の主要ニュースを深掘り解説。地域の話題やスポーツ結果、あすの傘予報まで丁寧にお伝えします。", cast: "キャスター: 穂積りょう、相沢なな", lv1: 0, lv2: 0),
            SlotSpec(durationMinutes: 60, title: "ドラマ「ひだまり荘の人々」", summary: "古いアパートに暮らす人々の温かな日常を描く連続ドラマ。", detail: "仕事も年齢もさまざまな住人たちが、中庭のベンチで言葉を交わしながら少しずつ距離を縮めていく。", cast: "出演: 水野はるか、橘けんじ、佐伯みどり", lv1: 3, lv2: 0),
            SlotSpec(durationMinutes: 60, title: "ミュージック・アトリエ", summary: "スタジオ生演奏と音楽談義を楽しむ1時間。", detail: "ゲスト音楽家を迎え、楽曲が生まれた背景を語りながら特別編成のアコースティック演奏を届ける。", cast: "案内: 響野かなで", lv1: 4, lv2: 5),
            SlotSpec(durationMinutes: 120, title: "よるの報道デスク", summary: "その日のニュースの背景を専門家の視点で読み解く報道番組。", detail: "政治・経済から科学技術まで、きょう動いたニュースの論点を図解とインタビューで掘り下げる。", cast: "キャスター: 久我たかし", lv1: 0, lv2: 6),
            SlotSpec(durationMinutes: 120, title: "ミッドナイト・トーク「夜の図書室」", summary: "本好きのゲストが心に残る一冊を語り合う深夜番組。", detail: "静かな図書室セットで、小説・随筆・科学書などテーマに沿ったおすすめの本を持ち寄って語り合う。", cast: "出演: 杉本はる、遠藤まりな", lv1: 5, lv2: 2),
            SlotSpec(durationMinutes: 360, title: "星空サウンドスケープ", summary: "美しい自然映像と穏やかな音楽をお送りする深夜枠。", detail: "高原の星空、波音、森の朝靄など、季節の風景とインストゥルメンタル音楽をゆったりと届ける。", cast: "音楽: ほしぞらアンサンブル", lv1: 4, lv2: 2),
        ],
        102: [
            SlotSpec(durationMinutes: 90, title: "おひさまキッズパーク", summary: "歌と工作で楽しく学ぶ朝の子ども向け番組。", detail: "身近な紙コップや折り紙で作る動くおもちゃ工作と、元気いっぱいの体操コーナー。", cast: "出演: たいようお兄さん、みくお姉さん", lv1: 10, lv2: 8),
            SlotSpec(durationMinutes: 150, title: "あおば暮らしナビ", summary: "住まい・健康・料理のコツを届ける生活情報番組。", detail: "季節の変わり目の体調管理と、忙しい平日に助かる作り置きおかずの工夫を専門家が解説。", cast: "司会: 牧野さとみ", lv1: 2, lv2: 3),
            SlotSpec(durationMinutes: 60, title: "アニメ「ロボと博士の100日」", summary: "発明家の博士と小さなロボットの心温まる日常アニメ。", detail: "博士の研究所で目覚めたロボットのピコが、初めての買い物や雨の日の散歩を経験していく。", cast: "声: 花村あおい、黒田げん", lv1: 7, lv2: 0),
            SlotSpec(durationMinutes: 120, title: "ランチタイム・バラエティ 笑福亭", summary: "スタジオゲームと街角インタビューで送るお昼のバラエティ。", detail: "商店街で見つけたユニークな看板クイズや、ゲストの思い出の品をめぐるトーク企画。", cast: "司会: 三枝こうた、椿まい", lv1: 5, lv2: 3),
            SlotSpec(durationMinutes: 120, title: "時代劇「風の街道」", summary: "街道を行く若き飛脚が宿場町の騒動を解決する痛快時代劇。", detail: "預かった大切な書状を届ける道中、峠の茶屋で出会った旅人たちの事情を知り一肌脱ぐ。", cast: "出演: 桐生かずま、菊池あやの", lv1: 3, lv2: 2),
            SlotSpec(durationMinutes: 120, title: "アニメアワー「星屑ステーション」ほか", summary: "夕方アニメの2本立て放送枠。", detail: "前半は『星屑ステーション』、後半は冒険アニメ『雲の上の郵便船』をお届けします。", cast: "声: 青葉りん、白石かなた ほか", lv1: 7, lv2: 0),
            SlotSpec(durationMinutes: 120, title: "クイズ！ことばの迷宮", summary: "言葉のひらめきと知識を競うクイズバラエティ。", detail: "漢字の成り立ちパズルや、アナグラム早押しなど、家族で一緒に考えられる問題が満載。", cast: "司会: 楠木まこと、川瀬ゆい", lv1: 5, lv2: 0),
            SlotSpec(durationMinutes: 120, title: "金曜ドラマ「海辺のベーカリー」", summary: "潮風の吹く町でパン屋を開いた姉妹の物語。", detail: "地元の小麦と塩を使った新作パンづくりに挑む姉と、店の経理を支える妹の奮闘を描く。", cast: "出演: 朝比奈ゆり、広瀬かのん", lv1: 3, lv2: 0),
            SlotSpec(durationMinutes: 120, title: "深夜アニメ「月面キャンプ部」", summary: "未来の月面基地でアウトドアを楽しむ高校生たちのSF日常アニメ。", detail: "低重力ならではの料理や天体観測に挑むキャンプ部のメンバーたち。", cast: "声: 星野めぐみ、結城れお", lv1: 7, lv2: 0),
            SlotSpec(durationMinutes: 420, title: "あおばナイトミュージック", summary: "注目のインディーズ楽曲を中心に紹介する深夜音楽枠。", detail: "全国各地で活動する若手バンドやシンガーソングライターのスタジオライブ映像を特集。", cast: "ナビゲーター: DJ KOTA", lv1: 4, lv2: 0),
        ],
        103: [
            SlotSpec(durationMinutes: 120, title: "けさの経済アイ", summary: "国内外の市場の動きと産業ニュースを伝える朝の経済番組。", detail: "ものづくりの現場取材や、新しい技術に取り組む中小企業の挑戦をレポートします。", cast: "キャスター: 榊原しんいち", lv1: 0, lv2: 4),
            SlotSpec(durationMinutes: 120, title: "しぜん図鑑「森の四季」", summary: "豊かな森に息づく動植物の1年を追う自然番組。", detail: "ブナの森に暮らす野鳥やリスたちの季節ごとの営みを高精細カメラで記録。", cast: "語り: 氷川まり", lv1: 8, lv2: 2),
            SlotSpec(durationMinutes: 120, title: "こもれびカルチャー講座", summary: "歴史・美術・文学をやさしくひもとく教養番組。", detail: "江戸時代の旅日記を読み解きながら、当時の人々の旅支度や街道の楽しみ方を探る。", cast: "講師: 望月けいこ", lv1: 10, lv2: 11),
            SlotSpec(durationMinutes: 120, title: "鉄道でめぐる列島紀行", summary: "ローカル線に揺られて各地の風景と人に出会う旅番組。", detail: "渓谷沿いを走る単線列車に乗り、無人駅と温泉街をめぐる1泊2日の旅。", cast: "旅と語り: 津田ひろき", lv1: 8, lv2: 1),
            SlotSpec(durationMinutes: 120, title: "サイエンス窓スペシャル", summary: "身近な科学から宇宙の謎まで実験で探る科学番組。", detail: "雲ができる仕組みや虹の色の秘密を大型実験装置で再現し、自然現象の法則に迫る。", cast: "案内: 桐谷しおり", lv1: 8, lv2: 3),
            SlotSpec(durationMinutes: 120, title: "ドキュメント 灯りの仕事", summary: "街の暮らしを支える仕事現場に密着するドキュメンタリー。", detail: "普段は見ることのできない夜間の保守点検や、伝統工芸の工房の1か月を丁寧に追う。", cast: "語り: 篠原あおい", lv1: 8, lv2: 7),
            SlotSpec(durationMinutes: 120, title: "将棋・囲碁サロン", summary: "注目の対局解説と次の一手講座。", detail: "こもれび杯の熱戦を大盤解説で振り返り、中盤の攻防のポイントをわかりやすく解説。", cast: "解説: 桂木八段", lv1: 10, lv2: 3),
            SlotSpec(durationMinutes: 120, title: "クラシックの小径", summary: "室内楽とオーケストラの名演を届ける音楽番組。", detail: "市民ホールで行われた定期演奏会から、交響曲とピアノ協奏曲をノーカットで放送。", cast: "指揮: 村瀬けんたろう", lv1: 4, lv2: 2),
            SlotSpec(durationMinutes: 480, title: "こもれびアーカイブス", summary: "過去の自然・紀行番組から選りすぐりの回を再構成。", detail: "日本の原風景を記録した映像ライブラリーから、山里と海辺の四季を静かに綴る。", cast: "語り: 篠原あおい", lv1: 8, lv2: 1),
        ],
        104: [
            SlotSpec(durationMinutes: 120, title: "うみかぜモーニングスポーツ", summary: "昨日の試合結果と注目の選手特集を届けるスポーツ情報番組。", detail: "サッカー、野球、陸上など国内外の大会ハイライトと、週末の見どころを解説。", cast: "キャスター: 瀬戸こうへい、速水りさ", lv1: 1, lv2: 0),
            SlotSpec(durationMinutes: 120, title: "港町レシピ帖セレクション", summary: "季節の魚と野菜を使った家庭料理をまとめて紹介。", detail: "週末に作りたい煮込み料理から、10分でできる朝ごはんのスープまで人気の回をアンコール放送。", cast: "料理: 風間なおこ", lv1: 10, lv2: 1),
            SlotSpec(durationMinutes: 120, title: "週末アウトドア日和", summary: "釣り・キャンプ・登山の基本と楽しみ方を紹介する趣味番組。", detail: "初心者でも安心な日帰りハイキングの装備選びと、山の上で淹れるコーヒーの楽しみ方。", cast: "出演: 岬だいすけ", lv1: 10, lv2: 0),
            SlotSpec(durationMinutes: 180, title: "サッカー中継 みなとカップ", summary: "みなとスタジアムから白熱の一戦をお届けします。", detail: "今シーズンの王者を懸けた一戦。ピッチサイドからのリポートを交えてたっぷり伝える。", cast: "解説: 矢島たつや / 実況: 瀬戸こうへい", lv1: 1, lv2: 2),
            SlotSpec(durationMinutes: 120, title: "うみかぜイブニング", summary: "海辺の街のニュースと週末イベント情報。", detail: "地域のニュース、港の気象・潮位情報、週末に開かれるマルシェの話題を生放送で届ける。", cast: "進行: 浜田あかり", lv1: 0, lv2: 9),
            SlotSpec(durationMinutes: 120, title: "旅バラエティ「しまなみ自転車旅」", summary: "島々を結ぶ道を自転車で巡る爽快旅バラエティ。", detail: "展望台からの絶景や、島で出会った柑橘農家さんとの触れ合いを楽しみながらゴールを目指す。", cast: "出演: 湊ゆうた、花園えみ", lv1: 5, lv2: 5),
            SlotSpec(durationMinutes: 120, title: "うみかぜ劇場「潮騒のメロディ」", summary: "海辺の音楽祭をめぐる青春ドラマ。", detail: "廃校になる学び舎で最後の音楽祭を開こうと集まった卒業生たちのひと夏を描く。", cast: "出演: 渚れん、真木ことり", lv1: 3, lv2: 0),
            SlotSpec(durationMinutes: 180, title: "スポーツドキュメント「挑戦者たち」", summary: "記録に挑み続けるアスリートの1年を追う大型企画。", detail: "怪我からの復帰を目指すランナーと、それを支えるコーチや家族の日々に密着。", cast: "語り: 城戸まさき", lv1: 1, lv2: 7),
            SlotSpec(durationMinutes: 360, title: "うみかぜヒーリングナイト", summary: "海岸線の風景と潮騒の音をお届けする深夜枠。", detail: "夕暮れから夜明けまでの海辺の移ろいを定点カメラで収めたフィラー番組。", cast: "", lv1: 15, lv2: 15),
        ],
    ]

    /// 指定時刻の前後 (昨日・今日・明日) の全番組を生成する。
    static func allPrograms(now: Date) -> (programs: [ProgramRecord], until: Int64) {
        let calendar = GuideLayout.calendar
        let today = GuideLayout.broadcastDay(for: now, calendar: calendar)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var result: [ProgramRecord] = []

        for dayOffset in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let range = GuideLayout.broadcastRange(for: day, calendar: calendar)
            for station in stations {
                guard let slots = stationTemplates[station.id] else { continue }
                var cursor = range.from
                for (index, slot) in slots.enumerated() {
                    let end = min(range.to, cursor + Int64(slot.durationMinutes) * 60_000)
                    let id = Int64(dayOffset + 10) * 100_000 + station.id * 100 + Int64(index)
                    let suffix = dayOffset == 1 ? "（翌日の放送）" : ""
                    // これから始まる番組のうち一部を「予約済み」にして表示を確かめられるようにする
                    let reserved = cursor > nowMs && (
                        (station.id == 101 && index == 7) || (station.id == 102 && index == 6)
                    )
                    result.append(ProgramRecord(
                        id: id,
                        station: station,
                        title: slot.title,
                        summary: slot.summary + suffix,
                        detail: slot.detail,
                        cast: slot.cast,
                        lv1: slot.lv1,
                        lv2: slot.lv2,
                        startAt: cursor,
                        endAt: end,
                        reserved: reserved
                    ))
                    cursor = end
                }
            }
        }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let until = GuideLayout.broadcastRange(for: tomorrow, calendar: calendar).to
        return (result, until)
    }

    static func servicesJSON(now: Date) -> Data {
        let (programs, _) = allPrograms(now: now)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let items: [[String: Any]] = stations.map { station in
            let current = programs.first {
                $0.station.id == station.id && $0.startAt <= nowMs && nowMs < $0.endAt
            }
            var dict: [String: Any] = [
                "id": station.id,
                "type": "GR",
                "name": station.name,
                "remoteControlKey": station.key,
                "logo": NSNull(),
                "live": "api/services/\(station.id)/live",
                "airing": true,
                "video": true,
            ]
            if let current {
                dict["now"] = [
                    "id": current.id,
                    "title": current.title,
                    "startAt": current.startAt,
                    "endAt": current.endAt,
                    "reserved": current.reserved,
                    "recording": false,
                    "audios": [
                        [
                            "id": "0:both",
                            "stream": 0,
                            "side": "both",
                            "label": "主音声",
                            "main": true,
                        ]
                    ],
                ]
            } else {
                dict["now"] = NSNull()
            }
            return dict
        }
        return jsonData(items)
    }

    static func guideJSON(type: String, from: Int64, to: Int64, now: Date) -> Data {
        guard type == "GR" else {
            return jsonData([
                "type": type,
                "from": from,
                "to": to,
                "until": NSNull(),
                "services": [],
            ])
        }
        let (programs, until) = allPrograms(now: now)
        let services: [[String: Any]] = stations.map { station in
            let list: [[String: Any]] = programs
                .filter { $0.station.id == station.id && $0.endAt > from && $0.startAt < to }
                .map { program in
                    var item: [String: Any] = [
                        "id": program.id,
                        "name": program.title,
                        "startAt": program.startAt,
                        "endAt": program.endAt,
                        "description": program.summary,
                        "genre": program.lv1,
                        "copyNever": false,
                        "recordingId": NSNull(),
                    ]
                    if program.reserved {
                        item["reservation"] = ["state": "scheduled"]
                    } else {
                        item["reservation"] = NSNull()
                    }
                    return item
                }
            return [
                "id": station.id,
                "name": station.name,
                "mainId": NSNull(),
                "remoteControlKey": station.key,
                "logo": NSNull(),
                "programs": list,
            ]
        }
        return jsonData([
            "type": "GR",
            "from": from,
            "to": to,
            "until": until,
            "services": services,
        ])
    }

    static func programDetailJSON(id: Int64, now: Date) -> Data? {
        let (programs, _) = allPrograms(now: now)
        guard let program = programs.first(where: { $0.id == id }) else { return nil }
        var extended: [String: String] = ["番組内容": program.detail]
        if !program.cast.isEmpty {
            extended["出演者"] = program.cast
        }
        return jsonData([
            "name": program.title,
            "service_name": program.station.name,
            "start_at": program.startAt,
            "end_at": program.endAt,
            "description": program.summary,
            "extended": extended,
            "genre_detail": [["lv1": program.lv1, "lv2": program.lv2]],
            "audios": [
                [
                    "componentType": 3,
                    "langs": ["jpn"],
                    "samplingRate": 48000,
                    "text": "主音声ステレオ",
                    "main": true,
                ]
            ],
            "video_type": "mpeg2",
            "video_resolution": "1080i",
            "is_free": true,
            "copy_never": false,
        ])
    }

    /// 録画の開始時刻の基準。30 分刻みに丸めることで、分単位の再読み込みで時刻が揺れないようにする
    static func recordingAnchor(now: Date) -> Int64 {
        Int64(floor(now.timeIntervalSince1970 / 1800) * 1800 * 1000)
    }

    static func recordingsJSON(limit: Int, offset: Int, now: Date) -> Data {
        let anchorMs = recordingAnchor(now: now)
        let slice = recordingSpecs.dropFirst(max(0, offset)).prefix(max(0, limit))
        let items: [[String: Any]] = slice.map { spec in
            let name = stationName(of: spec.stationID)
            let startAt = anchorMs - Int64(spec.minutesAgo) * 60_000
            let durationMs = Int64(spec.durationMinutes) * 60_000
            let endAt = startAt + durationMs
            let resumeMs: Any = spec.resumeMinutes.map { Int64($0) * 60_000 } ?? NSNull()
            let watchedAt: Any = spec.watched ? (endAt + 3_600_000) : NSNull()
            return [
                "id": spec.id,
                "title": spec.title,
                "name": spec.title,
                "serviceId": spec.stationID,
                "serviceName": name,
                "startAt": startAt,
                "endAt": endAt,
                "durationMs": durationMs,
                "resumeMs": resumeMs,
                "watchedAt": watchedAt,
                "recording": false,
                "chase": NSNull(),
                "cmReliable": false,
                "poster": NSNull(),
                "files": [
                    [
                        "source": "encoded",
                        "codec": "h264",
                        "url": "api/recordings/\(spec.id)/file/encoded",
                    ]
                ],
                "audio": "api/recordings/\(spec.id)/audio",
                "audios": [
                    [
                        "id": "0:both",
                        "stream": 0,
                        "side": "both",
                        "label": "主音声",
                        "main": true,
                    ]
                ],
            ]
        }
        return jsonData(items)
    }

    /// タイトル・説明・局名のどれかに言葉を含むか (denpa の照合の近似)
    static func matches(_ word: String, _ fields: String...) -> Bool {
        !word.isEmpty && fields.contains { $0.localizedCaseInsensitiveContains(word) }
    }

    static func searchJSON(query: String, limit: Int, now: Date) -> Data {
        let word = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let (programs, _) = allPrograms(now: now)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // これからの放送 (放送中のものも含む)。早く始まる順に並べる
        let matchedPrograms = programs
            .filter { $0.endAt > nowMs && matches(word, $0.title, $0.summary, $0.station.name) }
            .sorted { $0.startAt < $1.startAt }
        let programRows: [[String: Any]] = matchedPrograms.prefix(max(0, limit)).map { program in
            var row: [String: Any] = [
                "id": program.id,
                "name": program.title,
                "service_name": program.station.name,
                "start_at": program.startAt,
                "end_at": program.endAt,
            ]
            if program.reserved {
                row["reservation_state"] = "scheduled"
            } else {
                row["reservation_state"] = NSNull()
            }
            return row
        }

        // 録画は新しい順 (recordingSpecs の並び)
        let anchorMs = recordingAnchor(now: now)
        let matchedRecordings = recordingSpecs.filter { spec in
            matches(word, spec.title, spec.summary, stationName(of: spec.stationID))
        }
        let recordingRows: [[String: Any]] = matchedRecordings.prefix(max(0, limit)).map { spec in
            [
                "id": spec.id,
                "name": spec.title,
                "service_name": stationName(of: spec.stationID),
                "start_at": anchorMs - Int64(spec.minutesAgo) * 60_000,
                "state": "available",
                // shortcut: 値は読まれず null かどうかだけ見られる。観る画面は一覧から引き直す (実 API の形が分かったら差し替え)
                "watch": "api/recordings/\(spec.id)/watch",
            ]
        }

        return jsonData([
            "q": query,
            "programs": ["more": matchedPrograms.count > programRows.count, "rows": programRows],
            "recordings": ["more": matchedRecordings.count > recordingRows.count, "rows": recordingRows],
        ])
    }

    private static func stationName(of id: Int64) -> String {
        stations.first { $0.id == id }?.name ?? "ほしぞら放送"
    }

    static func recordingDetailJSON(id: Int64) -> Data? {
        guard let spec = recordingSpecs.first(where: { $0.id == id }) else { return nil }
        var extended: [String: String] = ["番組内容": spec.detail]
        if !spec.cast.isEmpty {
            extended["出演者"] = spec.cast
        }
        return jsonData([
            "id": spec.id,
            "title": spec.title,
            "name": spec.title,
            "description": spec.summary,
            "extended": extended,
        ])
    }

    static func recordingStatusJSON(id: Int64) -> Data? {
        guard let spec = recordingSpecs.first(where: { $0.id == id }) else { return nil }
        return jsonData([
            "id": spec.id,
            "encoded": true,
            "state": "available",
            "durationMs": Int64(spec.durationMinutes) * 60_000,
        ])
    }

    static func recordingPlaybackJSON(id: Int64) -> Data? {
        guard let spec = recordingSpecs.first(where: { $0.id == id }) else { return nil }
        let duration = Double(spec.durationMinutes * 60)
        return jsonData([
            "duration": duration,
            "axis": "encoded",
            "audios": [
                ["id": "0:both", "label": "主音声"]
            ],
            "offers": [
                ["codec": "h264", "way": "file", "source": "encoded", "codecs": "avc1.4D401F,mp4a.40.2"],
                ["codec": "h264", "way": "stream"],
            ],
            "ruler": ["kept": NSNull(), "skip": 0],
        ])
    }

    static func recordingChaptersJSON(id: Int64) -> Data? {
        guard let spec = recordingSpecs.first(where: { $0.id == id }) else { return nil }
        let total = Double(spec.durationMinutes * 60)
        return jsonData([
            "chapters": [
                ["start": 0, "end": min(90, total), "title": "オープニング"],
                ["start": min(90, total), "end": max(90, total - 90), "title": "本編"],
                ["start": max(90, total - 90), "end": total, "title": "エンディング"],
            ]
        ])
    }

    static func playbackOptionsJSON() -> Data {
        jsonData([
            "indoor": true,
            "liveCodecs": ["h264"],
            "hidden": [],
            "hevc": false,
        ])
    }

    /// ストリーム URL (`api/recordings/<id>/stream`) から録画の尺 (秒) を引く。
    static func recordingDuration(for url: URL) -> Double {
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "recordings"),
           index + 1 < parts.count,
           let id = Int64(parts[index + 1]),
           let spec = recordingSpecs.first(where: { $0.id == id }) {
            return Double(spec.durationMinutes * 60)
        }
        return 1800
    }

    static func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
