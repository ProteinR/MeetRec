import SwiftUI

/// A settings card whose whole header row toggles it: icon, title, a one-line summary of the current
/// values, and a rotating chevron. Replaces `DisclosureGroup`, where only the tiny arrow was clickable.
struct CollapsibleSection<Content: View>: View {
    let title: String
    let icon: String
    var summary: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // No animated height change: the panel window resizes to the new content size in one
                // step, and an animated SwiftUI transition inside it made the content jump.
                isExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.gradient))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.callout.weight(.medium))
                        if let summary, !isExpanded {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if isExpanded {
                Divider().padding(.horizontal, 10)
                content()
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(hovering && !isExpanded ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
