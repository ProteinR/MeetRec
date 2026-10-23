import AppKit

/// A search by picture: the app only hands over the image and opens a page in the browser.
/// Each provider knows its own service; adding one is a new type in `ImageSearch.all`.
protocol ImageSearchProvider {
    /// Stored in the `imageSearchProviders` setting.
    var id: String { get }
    /// "Google": shown in tooltips and settings.
    var name: String { get }
    /// The service's mark, about 16 pt.
    var icon: NSImage { get }
    var method: ImageSearchMethod { get }
}

/// How the picture gets to the service.
enum ImageSearchMethod {
    /// MeetRec uploads the picture (PNG) and opens the results page the service returns.
    case upload((Data) async throws -> URL)
    /// The service takes the picture only by hand (bot protection, its rules): the picture goes to
    /// the clipboard and this page opens, to paste it there with ⌘V; `hint` says how, in the toast.
    case pasteOnPage(URL, hint: String)
}

enum ImageSearchError: LocalizedError {
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse(let detail): return "Сервис ответил не так, как ожидалось (\(detail))"
        }
    }
}

@MainActor
enum ImageSearch {
    /// The setting lists the enabled ones; until it is changed, all are on.
    static let all: [any ImageSearchProvider] = [
        GoogleLensSearch(), YandexImageSearch(), TinEyeSearch(),
        // Bing's upload needs a token signed for its own page.
        PasteOnPageSearch(id: "bing", name: "Bing", iconName: "BingLogo", page: "https://www.bing.com/images?FORM=SBIIDP",
                          hint: "Нажмите на камеру в поиске Bing и вставьте его: ⌘V или перетащите"),
        PasteOnPageSearch(id: "pimeyes", name: "PimEyes", iconName: "PimEyesLogo", page: "https://pimeyes.com/en"),
        PasteOnPageSearch(id: "facecheck", name: "FaceCheck.ID", iconName: "FaceCheckLogo", page: "https://facecheck.id/"),
        PasteOnPageSearch(id: "search4faces", name: "Search4faces", iconName: "Search4facesLogo",
                          page: "https://search4faces.com/search.html"),
    ]

    /// Comma-separated ids of the providers shown in the screenshot toast.
    static let enabledKey = "imageSearchProviders"
    static let enabledByDefault = all.map(\.id).joined(separator: ",")
    static var enabledRaw: String {
        get { UserDefaults.standard.string(forKey: enabledKey) ?? enabledByDefault }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func setEnabled(_ provider: any ImageSearchProvider, _ on: Bool) {
        let ids = enabledRaw.split(separator: ",").map(String.init).filter { $0 != provider.id } + (on ? [provider.id] : [])
        enabledRaw = all.map(\.id).filter(ids.contains).joined(separator: ",")
    }

    /// Searches only on a click: the picture leaves the Mac.
    static func search(_ file: URL, with provider: any ImageSearchProvider) {
        guard let loaded = ScreenshotFiles.load(file) else { return }
        search(loaded.image, scale: loaded.scale, name: file.lastPathComponent, with: provider)
    }

    /// The editor passes its result (marks, blur and crop applied). Large shots are scaled down
    /// before an upload (the services do not need more, and it is quicker).
    static func search(_ picture: CGImage, scale: CGFloat, name: String, with provider: any ImageSearchProvider) {
        let resultsPage: (Data) async throws -> URL
        switch provider.method {
        case .pasteOnPage(let page, let hint):
            ScreenshotFiles.copy(picture, scale: scale)
            NSWorkspace.shared.open(page)
            Log.info("Image search in \(provider.name): \(name) copied, upload page opened", "screenshots")
            RecorderModel.shared.showToast(Toast(kind: .screenshot, title: "Снимок в буфере обмена",
                                                 detail: hint))
            return
        case .upload(let upload):
            resultsPage = upload
        }
        let image = ScreenshotFiles.downscaled(picture, maxPixels: 2048) ?? picture
        guard let png = ScreenshotFiles.png(image, scale: 1) else { return }
        RecorderModel.shared.showToast(Toast(kind: .screenshot, title: "Ищу в \(provider.name)…"))
        Task {
            let started = Date()
            do {
                let page = try await resultsPage(png)
                Log.info("Image search in \(provider.name): \(name), \(png.count / 1024) KB, "
                         + String(format: "%.1f s", Date().timeIntervalSince(started)), "screenshots")
                RecorderModel.shared.dismissToast()
                NSWorkspace.shared.open(page)
            } catch {
                Log.warning("Image search in \(provider.name) failed for \(name): \(Log.describe(error))", "screenshots")
                RecorderModel.shared.showToast(Toast(kind: .screenshot, title: "Не удалось найти в \(provider.name)",
                                                     detail: error.localizedDescription))
            }
        }
    }

    /// The provider's mark at `size` points (menus take an image's own size).
    static func icon(_ provider: any ImageSearchProvider, size: CGFloat) -> NSImage {
        let source = provider.icon
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
    }

    /// One multipart/form-data POST with the picture as `field`.
    static func upload(_ png: Data, to url: URL, field: String, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        let boundary = "MeetRec-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"screenshot.png\"\r\n"
                    + "Content-Type: image/png\r\n\r\n")
        body.append(png)
        body.append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // The services answer a plain client differently (or not at all); this is what a browser sends.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        let session = followRedirects ? URLSession.shared : URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { if !followRedirects { session.finishTasksAndInvalidate() } }
        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw ImageSearchError.unexpectedResponse("не HTTP") }
        return (data, http)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}

/// Google Lens: the upload answers 303 with the results page, which opens in the browser as is.
struct GoogleLensSearch: ImageSearchProvider {
    let id = "google"
    let name = "Google"
    var icon: NSImage { NSImage(named: "GoogleLogo") ?? NSImage() }
    var method: ImageSearchMethod { .upload(resultsPage) }

    func resultsPage(for png: Data) async throws -> URL {
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(string: "https://lens.google.com/v3/upload?hl=ru&re=df&ep=gsbubb&st=\(millis)")!
        let (_, response) = try await ImageSearch.upload(png, to: url, field: "encoded_image", followRedirects: false)
        guard (300..<400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
              let page = URL(string: location) else {
            throw ImageSearchError.unexpectedResponse("HTTP \(response.statusCode)")
        }
        return page
    }
}

/// Yandex Images: the upload returns the picture's id (`cbirId`) for the "search by image" page.
struct YandexImageSearch: ImageSearchProvider {
    let id = "yandex"
    let name = "Яндекс"
    var icon: NSImage { Self.mark }
    var method: ImageSearchMethod { .upload(resultsPage) }

    func resultsPage(for png: Data) async throws -> URL {
        var upload = URLComponents(string: "https://yandex.ru/images/search")!
        upload.queryItems = [
            URLQueryItem(name: "rpt", value: "imageview"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "request", value: #"{"blocks":[{"block":"b-page_type_search-by-image__link"}]}"#),
        ]
        let (data, response) = try await ImageSearch.upload(png, to: upload.url!, field: "upfile", followRedirects: true)
        struct Reply: Decodable {
            struct Block: Decodable { let params: Params? }
            struct Params: Decodable { let cbirId: String?; let originalImageUrl: String? }
            let blocks: [Block]
        }
        guard response.statusCode == 200,
              let params = (try? JSONDecoder().decode(Reply.self, from: data))?.blocks.first?.params,
              let cbirID = params.cbirId else {
            throw ImageSearchError.unexpectedResponse("HTTP \(response.statusCode)")
        }
        var page = URLComponents(string: "https://yandex.ru/images/search")!
        page.queryItems = [URLQueryItem(name: "rpt", value: "imageview"), URLQueryItem(name: "cbir_id", value: cbirID)]
            + (params.originalImageUrl.map { [URLQueryItem(name: "url", value: $0)] } ?? [])
        // `/` and `:` inside the values must be escaped too, as the site itself does.
        page.percentEncodedQuery = page.percentEncodedQuery?
            .replacingOccurrences(of: "/", with: "%2F").replacingOccurrences(of: ":", with: "%3A")
        return page.url!
    }

    /// Yandex's mark: a white «Я» on a red circle.
    private static let mark: NSImage = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
        NSColor(red: 0.99, green: 0.24, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let text = NSAttributedString(string: "Я", attributes: [
            .font: NSFont.systemFont(ofSize: 21, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 0.5))
        return true
    }
}

/// TinEye: finds copies of the picture and where it appeared first. The upload answers JSON with the
/// search's key, which is also the results page's address.
struct TinEyeSearch: ImageSearchProvider {
    let id = "tineye"
    let name = "TinEye"
    var icon: NSImage { NSImage(named: "TinEyeLogo") ?? NSImage() }
    var method: ImageSearchMethod { .upload(resultsPage) }

    func resultsPage(for png: Data) async throws -> URL {
        let url = URL(string: "https://tineye.com/api/v1/result_json/?sort=score&order=desc")!
        let (data, response) = try await ImageSearch.upload(png, to: url, field: "image", followRedirects: true)
        struct Reply: Decodable {
            struct Query: Decodable { let key: String }
            let query: Query
        }
        guard response.statusCode == 200, let key = (try? JSONDecoder().decode(Reply.self, from: data))?.query.key,
              key.allSatisfy(\.isHexDigit) else {
            throw ImageSearchError.unexpectedResponse("HTTP \(response.statusCode)")
        }
        return URL(string: "https://tineye.com/search/\(key)?sort=score&order=desc&page=1")!
    }
}

/// A service that takes the picture only on its own page (Bing, PimEyes, FaceCheck.ID, Search4faces).
struct PasteOnPageSearch: ImageSearchProvider {
    let id: String
    let name: String
    let iconName: String
    let page: String
    var hint: String?

    var icon: NSImage { NSImage(named: iconName) ?? NSImage() }
    var method: ImageSearchMethod {
        .pasteOnPage(URL(string: page)!, hint: hint ?? "Вставьте его на странице \(name): ⌘V или перетащите")
    }
}
