import SwiftUI

struct WarningInspector: View {
    let engineVersion: String
    let modelVersion: String?
    let pages: [EnginePageMetadata]
    let warnings: [String]
    @Binding var selectedPage: Int

    private var warningRows: [WarningRow] {
        var occurrences: [String: Int] = [:]
        return warnings.map { warning in
            let occurrence = occurrences[warning, default: 0]
            occurrences[warning] = occurrence + 1
            return WarningRow(id: "\(warning)-\(occurrence)", text: warning)
        }
    }

    var body: some View {
        Form {
            Section("Conversion") {
                LabeledContent("Engine", value: engineVersion)
                if let modelVersion {
                    LabeledContent("Model", value: modelVersion)
                } else {
                    LabeledContent("Model", value: String(localized: "Native text"))
                }
                if pages.isEmpty {
                    LabeledContent("Pages", value: String(localized: "Unavailable"))
                } else {
                    LabeledContent("Pages", value: "\(pages.count)")
                }
            }
            Section("Page methods") {
                if pages.isEmpty { Text("No page metadata was recorded.").foregroundStyle(.secondary) }
                ForEach(pages, id: \.pageNumber) { page in
                    Button {
                        selectedPage = page.pageNumber
                    } label: {
                        HStack {
                            Text("Page \(page.pageNumber)")
                            Spacer()
                            Text(page.method).foregroundStyle(.secondary)
                            if selectedPage == page.pageNumber { Image(systemName: "checkmark") }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Page \(page.pageNumber), \(page.method)")
                    .accessibilityValue(selectedPage == page.pageNumber ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selectedPage == page.pageNumber ? .isSelected : [])
                    if let warning = page.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                }
            }
            if !warnings.isEmpty {
                Section("Warnings") {
                    ForEach(warningRows) { warning in
                        Label(warning.text, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WarningRow: Identifiable {
    let id: String
    let text: String
}
