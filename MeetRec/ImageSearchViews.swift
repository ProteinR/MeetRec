import SwiftUI

/// The image search buttons, one per enabled provider, in a row. Every place that offers search
/// (screenshot toast, recent screenshots' menu, editor) uses this, so turning a provider on or off
/// in settings, or adding one to `ImageSearch.all`, changes all of them.
struct ImageSearchButtons: View {
    var iconSize: CGFloat = 14
    /// The provider under the pointer, for a label of its own: the toast never becomes key, and
    /// macOS shows `.help` tooltips only in the active window.
    var onHover: ((any ImageSearchProvider)?) -> Void = { _ in }
    let search: (any ImageSearchProvider) -> Void
    @AppStorage(ImageSearch.enabledKey) private var enabledRaw = ImageSearch.enabledByDefault

    var body: some View {
        let ids = enabledRaw.split(separator: ",")
        ForEach(ImageSearch.all.filter { ids.contains(Substring($0.id)) }, id: \.id) { provider in
            Button {
                search(provider)
            } label: {
                Image(nsImage: provider.icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
            }
            .help(Self.tooltip(provider))
            .onHover { onHover($0 ? provider : nil) }
        }
    }

    static func tooltip(_ provider: any ImageSearchProvider) -> String {
        switch provider.method {
        case .upload: return "Найти в \(provider.name): снимок отправится туда"
        case .pasteOnPage: return "Найти в \(provider.name): снимок в буфер обмена, откроется сайт — вставьте его там"
        }
    }
}

/// The same buttons as one row of icons in a right-click menu.
struct ImageSearchMenuRow: View {
    let search: (any ImageSearchProvider) -> Void
    @AppStorage(ImageSearch.enabledKey) private var enabledRaw = ImageSearch.enabledByDefault

    var body: some View {
        let ids = enabledRaw.split(separator: ",")
        let providers = ImageSearch.all.filter { ids.contains(Substring($0.id)) }
        if !providers.isEmpty {
            ControlGroup {
                ForEach(providers, id: \.id) { provider in
                    Button {
                        search(provider)
                    } label: {
                        Label { Text("Найти в \(provider.name)") } icon: { Image(nsImage: ImageSearch.icon(provider, size: 16)) }
                    }
                    .help(ImageSearchButtons.tooltip(provider))
                }
            } label: {
                Text("Найти похожее")
            }
            .controlGroupStyle(.palette)
        }
    }
}
