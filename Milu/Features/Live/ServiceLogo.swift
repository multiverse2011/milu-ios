import SwiftUI

/// 局ロゴ (3.5)。`logo` が無い・取れないときは、面に局名の頭 1 字。
struct ServiceLogo: View {
    let service: Service
    let baseURL: URL?
    let token: String?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(String(service.name.prefix(1)))
                    .scaledFont(11, weight: .bold)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .tertiarySystemFill))
            }
        }
        .frame(width: 40, height: 23)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: service.logo) { await load() }
    }

    private func load() async {
        guard
            !DemoServer.isDemo(baseURL),
            let logo = service.logo,
            let baseURL,
            let url = URL(string: logo, relativeTo: baseURL)
        else {
            image = nil
            return
        }
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let loaded = UIImage(data: data)
        else { return }
        image = loaded
    }
}
