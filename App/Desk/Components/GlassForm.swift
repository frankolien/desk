import DeskUI
import SwiftUI

/// A grouped section whose container is Liquid Glass on iOS 26 and material before it.
///
/// A system `Form` paints its sections as opaque grey and offers no way to swap that for
/// glass, so this lays the same native controls out itself: rows separated by hairlines
/// inside one glass shape, with the header and footer where Settings puts them.
struct GlassSection<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 14)
            }
            Group(subviews: content) { rows in
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        row
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                        if row.id != rows.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
            .font(.subheadline)
            .controlSize(.small)
            .deskGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
        }
    }
}

/// A label on the leading edge and a native control or value on the trailing edge.
struct GlassRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension GlassRow where Trailing == Text {
    init(_ title: String, value: String) {
        self.init(title) { Text(value).foregroundStyle(.secondary).monospacedDigit() }
    }
}

/// The scrolling page glass sections sit on. Glass needs something behind it to bend, so
/// the ground is the app's lit background rather than flat black.
struct GlassPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { DeskBackground() }
    }
}
