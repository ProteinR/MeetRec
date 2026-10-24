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
    /// The browser itself posts the picture to the service's upload form (from a local page MeetRec
    /// writes), for services whose results belong to the uploading session (its cookies): a page
    /// uploaded by MeetRec opens empty in the browser.
    case uploadInBrowser(URL, field: String)
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
    /// The setting lists the enabled ones; until it is changed, only Google Lens is on.
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
    static let enabledByDefault = "google"
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
        switch provider.method {
        case .pasteOnPage(let page, let hint):
            ScreenshotFiles.copy(picture, scale: scale)
            NSWorkspace.shared.open(page)
            Log.info("Image search in \(provider.name): \(name) copied, upload page opened", "screenshots")
            RecorderModel.shared.showToast(Toast(kind: .screenshot, title: "Снимок в буфере обмена",
                                                 detail: hint))
        case .upload(let resultsPage):
            guard let png = uploadPNG(picture) else { return }
            uploadAndOpen(png, name: name, provider: provider, resultsPage: resultsPage)
        case .uploadInBrowser(let form, let field):
            guard let png = uploadPNG(picture) else { return }
            uploadInBrowser(png, to: form, field: field, name: name, provider: provider)
        }
    }

    private static func uploadPNG(_ picture: CGImage) -> Data? {
        ScreenshotFiles.png(ScreenshotFiles.downscaled(picture, maxPixels: 2048) ?? picture, scale: 1)
    }

    private static func uploadAndOpen(_ png: Data, name: String, provider: any ImageSearchProvider,
                                      resultsPage: @escaping (Data) async throws -> URL) {
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

    /// Writes a page that puts the picture into a form for `form` and submits it at once, and opens it
    /// in the default browser (not the default app for .html files).
    private static func uploadInBrowser(_ png: Data, to form: URL, field: String, name: String,
                                        provider: any ImageSearchProvider) {
        do {
            let page = try writeUploadPage(png, to: form, field: field)
            let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            if let browser {
                NSWorkspace.shared.open([page], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(page)
            }
            Log.info("Image search in \(provider.name): \(name), \(png.count / 1024) KB, upload page opened in "
                     + (browser?.deletingPathExtension().lastPathComponent ?? "the default app"), "screenshots")
        } catch {
            Log.warning("Image search in \(provider.name) failed for \(name): \(Log.describe(error))", "screenshots")
            RecorderModel.shared.showToast(Toast(kind: .screenshot, title: "Не удалось найти в \(provider.name)",
                                                 detail: error.localizedDescription))
        }
    }

    /// Pages older than a minute are removed: the browser has read them by then.
    static func writeUploadPage(_ png: Data, to form: URL, field: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetRec Image Search", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in old where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            < Date().addingTimeInterval(-60) {
            try? FileManager.default.removeItem(at: file)
        }
        let html = """
            <!doctype html><meta charset="utf-8"><title>Поиск по картинке</title>
            <body style="font: 14px -apple-system, sans-serif; color: gray">Отправляю снимок…
            <form method="post" enctype="multipart/form-data" action="\(form.absoluteString.replacingOccurrences(of: "&", with: "&amp;"))"><input type="file" name="\(field)"></form>
            <script>
            const bytes = Uint8Array.from(atob("\(png.base64EncodedString())"), c => c.charCodeAt(0));
            const files = new DataTransfer();
            files.items.add(new File([bytes], "screenshot.png", {type: "image/png"}));
            const form = document.forms[0];
            form.elements[0].files = files.files;
            form.submit();
            </script>
            """
        let page = folder.appendingPathComponent("\(UUID().uuidString).html")
        try Data(html.utf8).write(to: page)
        return page
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
    static func upload(_ png: Data, to url: URL, field: String) async throws -> (Data, HTTPURLResponse) {
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
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw ImageSearchError.unexpectedResponse("не HTTP") }
        return (data, http)
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}

/// Google Lens: the upload answers 303 with the results page, but that page shows the picture only
/// to the session that uploaded it (an upload from MeetRec opened empty in the browser), so the
/// browser posts it itself.
struct GoogleLensSearch: ImageSearchProvider {
    let id = "google"
    let name = "Google"
    var icon: NSImage { NSImage(named: "GoogleLogo") ?? NSImage() }
    var method: ImageSearchMethod {
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        return .uploadInBrowser(URL(string: "https://lens.google.com/v3/upload?hl=ru&re=df&ep=gsbubb&st=\(millis)")!,
                                field: "encoded_image")
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
        let (data, response) = try await ImageSearch.upload(png, to: upload.url!, field: "upfile")
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
        let (data, response) = try await ImageSearch.upload(png, to: url, field: "image")
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
