import SwiftUI

struct SettingsView: View {
    let model: ParchleyAppModel

    @State private var modelState: ModelState = .notInstalled
    @State private var modelProgress: ModelProgress?
    @State private var isClearingHistory = false
    @State private var localVLMError: String?

    private var totalDownloadBytes: Int64 {
        model.ocrManifest.artifacts.reduce(0) { $0 + $1.byteCount }
    }

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalSettings(model: model)
            }

            Tab("Open Source", systemImage: "doc.text") {
                LicensesView()
                    .navigationTitle("Open Source Software")
            }
        }
        .frame(width: 560, height: 500)
        .navigationTitle("Settings")
    }

    private func generalSettings(model: ParchleyAppModel) -> some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsSection("Conversion", systemImage: "doc.text.magnifyingglass") {
                    Toggle(
                        "Use OCR when a page needs it",
                        isOn: $model.preferences.ocrEnabled
                    )
                    Text("Parchley keeps conversion local. OCR is used only for pages without selectable text.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                settingsSection("OCR model", systemImage: "cpu") {
                    OCRModelCard(
                        state: modelState,
                        progress: modelProgress,
                        revision: model.ocrManifest.revision,
                        totalBytes: totalDownloadBytes,
                        isAvailable: model.ocrManager != nil,
                        install: installModel,
                        cancel: cancelModelDownload,
                        remove: removeModel
                    )
                }

                Divider()

                settingsSection("Local vision assistance", systemImage: "viewfinder") {
                    Toggle(
                        "Add local VLM assistance to OCR",
                        isOn: $model.preferences.localVLMEnabled
                    )
                    .disabled(model.preferences.localVLMModelBookmark == nil)

                    HStack {
                        Label(
                            model.preferences.localVLMModelName ?? "No model folder selected",
                            systemImage: model.preferences.localVLMModelBookmark == nil
                                ? "folder.badge.questionmark"
                                : "folder"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                        Spacer()

                        Button("Choose Folder…", action: chooseLocalVLMModel)
                        if model.preferences.localVLMModelBookmark != nil {
                            Button("Remove", role: .destructive) {
                                model.preferences.clearLocalVLMModelDirectory()
                            }
                        }
                    }

                    Text("When enabled, a local vision model makes a supplemental pass over pages already sent to OCR. It runs on your Mac, may use substantial unified memory, and can slow conversion. Parchley does not download model weights.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 5) {
                        Link(
                            "SmolVLM2 500M · Apache 2.0 · about 1.0 GB",
                            destination: LocalVLMLinks.smolVLM2
                        )
                        Link(
                            "SmolVLM 4-bit · Apache 2.0 · about 1.5 GB",
                            destination: LocalVLMLinks.smolVLM4Bit
                        )
                    }
                    .font(.callout)

                    Text("The 500M option is a smaller starting point. The 4-bit option has a different size and quantization tradeoff; neither guarantees better OCR. Memory use, speed, and quality vary by document and Mac. Download an MLX-format model folder from a link above, then select that folder here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                settingsSection("History", systemImage: "clock.arrow.circlepath") {
                    LabeledContent("Keep completed results") {
                        Picker(
                            "Keep completed results",
                            selection: $model.preferences.retentionDays
                        ) {
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    Text("Older completed results are removed automatically. Saved drafts stay available when history is cleared.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Clear History", role: .destructive) {
                        isClearingHistory = true
                    }
                    .disabled(isClearingHistory)
                }

                Divider()

                settingsSection("Parchley", systemImage: "info.circle") {
                    Text("Free and open-source software for turning PDFs into Markdown on your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                        GridRow {
                            projectLink("View Repository", systemImage: "chevron.left.forwardslash.chevron.right", destination: ProjectLinks.repository)
                            projectLink("View Releases", systemImage: "shippingbox", destination: ProjectLinks.releases)
                        }
                        GridRow {
                            projectLink("Report an Issue", systemImage: "exclamationmark.bubble", destination: ProjectLinks.issues)
                            projectLink("Read Privacy Policy", systemImage: "hand.raised", destination: ProjectLinks.privacy)
                        }
                        GridRow {
                            projectLink("Follow on X", systemImage: "at", destination: ProjectLinks.xProfile)
                            projectLink("Join Discord", systemImage: "bubble.left.and.bubble.right", destination: ProjectLinks.discord)
                        }
                        GridRow {
                            projectLink("Report a Security Issue", systemImage: "lock.shield", destination: ProjectLinks.security)
                            Color.clear
                                .frame(height: 1)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .padding(24)
        }
        .task(id: isModelOperationActive) {
            if isModelOperationActive {
                await pollModelState()
            } else {
                await refreshModelState()
            }
        }
        .onChange(of: model.preferences.retentionDays) { _, days in
            guard days > 0 else { return }
            model.pruneHistory()
        }
        .confirmationDialog("Clear completed history?", isPresented: $isClearingHistory) {
            Button("Clear History", role: .destructive) { clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved drafts remain available for review.")
        }
        .alert("Local vision model", isPresented: Binding(
            get: { localVLMError != nil },
            set: { if !$0 { localVLMError = nil } }
        )) {
            Button("OK") { localVLMError = nil }
        } message: {
            Text(localVLMError ?? "")
        }
    }

    private func settingsSection<Content: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8, content: content)
        }
    }

    private func projectLink(
        _ title: LocalizedStringKey,
        systemImage: String,
        destination: URL
    ) -> some View {
        Link(destination: destination) {
            Label(title, systemImage: systemImage)
        }
    }

    private func refreshModelState() async {
        if let manager = model.ocrManager {
            _ = await manager.discover(model.ocrManifest)
            await updateModelState(from: manager)
        }
    }

    private func pollModelState() async {
        guard let manager = model.ocrManager else { return }
        while !Task.isCancelled {
            await updateModelState(from: manager)
            guard isModelOperationActive else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
        }
    }

    private var isModelOperationActive: Bool {
        switch modelState {
        case .downloading, .verifying, .removing: true
        default: false
        }
    }

    private func updateModelState(from manager: OCRModelManager) async {
        modelState = await manager.state
        modelProgress = await manager.progress
    }

    private func installModel() {
        guard model.ocrManager != nil else { return }
        modelState = .downloading
        modelProgress = ModelProgress(completedBytes: 0,
                                      totalBytes: totalDownloadBytes,
                                      artifact: model.ocrManifest.artifacts.first?.name ?? "")
        model.installOCRModel()
    }

    private func cancelModelDownload() {
        model.cancelOCRModelDownload()
    }

    private func removeModel() {
        model.removeOCRModel()
    }

    private func clearHistory() {
        model.clearHistory()
    }

    private func chooseLocalVLMModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose an MLX model folder"
        panel.prompt = "Use Model"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let directory = panel.url else { return }
            do {
                try model.preferences.setLocalVLMModelDirectory(directory)
            } catch {
                localVLMError = error.localizedDescription
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

private enum LocalVLMLinks {
    static let smolVLM2 = URL(string: "https://huggingface.co/HuggingFaceTB/SmolVLM2-500M-Video-Instruct-mlx")!
    static let smolVLM4Bit = URL(string: "https://huggingface.co/mlx-community/SmolVLM-Instruct-4bit")!
}

private enum ProjectLinks {
    static let repository = URL(string: "https://github.com/SidhuK/Parchley/")!
    static let releases = URL(string: "https://github.com/SidhuK/Parchley/releases")!
    static let issues = URL(string: "https://github.com/SidhuK/Parchley/issues")!
    static let privacy = URL(string: "https://github.com/SidhuK/Parchley/blob/main/PRIVACY.md")!
    static let security = URL(string: "https://github.com/SidhuK/Parchley/security/advisories/new")!
    static let xProfile = URL(string: "https://x.com/karat_sidhu")!
    static let discord = URL(string: "https://discord.com/invite/cNqrBfFx7D")!
}

private struct OCRModelCard: View {
    let state: ModelState
    let progress: ModelProgress?
    let revision: String
    let totalBytes: Int64
    let isAvailable: Bool
    let install: () -> Void
    let cancel: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state.systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("PaddleOCR v6 small")
                        .foregroundStyle(.primary)
                    Text(state.statusLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("\(revision) · \(byteString(totalBytes)) · runs locally")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
                action
            }

            if case .downloading = state {
                VStack(alignment: .leading, spacing: 7) {
                    if let progress, progress.totalBytes > 0 {
                        ProgressView(value: Double(progress.completedBytes), total: Double(progress.totalBytes)) {
                            Text("Downloading \(progress.artifact)")
                        } currentValueLabel: {
                            Text(progressPercent)
                                .monospacedDigit()
                        }
                        .progressViewStyle(.linear)
                        .accessibilityLabel("OCR model download progress")
                        .accessibilityValue(progressDescription)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .accessibilityLabel("Downloading OCR model")
                    }

                    if let progress {
                        Text("\(byteString(progress.completedBytes)) of \(byteString(progress.totalBytes))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else if case .verifying = state {
                ProgressView("Checking downloaded files…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !isAvailable {
                Label("Model storage is unavailable.", systemImage: "externaldrive.badge.xmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .notInstalled, .failed:
            Button("Download model", action: install)
                .disabled(!isAvailable)
        case .downloading:
            Button("Cancel", action: cancel)
        case .verifying, .removing:
            ProgressView(state == .verifying ? "Verifying" : "Removing")
                .controlSize(.small)
                .accessibilityLabel(state == .verifying ? "Verifying" : "Removing")
        case .bundled:
            Label("Included", systemImage: "shippingbox.fill")
                .foregroundStyle(.secondary)
        case .ready:
            Button("Remove", role: .destructive, action: remove)
                .disabled(!isAvailable)
        }
    }

    private var progressPercent: String {
        guard let fraction = progress?.fraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private var progressDescription: String {
        guard progress?.fraction != nil else { return "Starting" }
        return "\(progressPercent), \(byteString(progress?.completedBytes ?? 0)) of \(byteString(progress?.totalBytes ?? totalBytes))"
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension ModelState {
    var statusLabel: LocalizedStringResource {
        switch self {
        case .notInstalled: "Not downloaded"
        case .downloading: "Downloading…"
        case .verifying: "Verifying…"
        case .ready: "Installed"
        case .bundled: "Included with Parchley"
        case .failed: "Needs attention"
        case .removing: "Removing…"
        }
    }

    var systemImage: String {
        switch self {
        case .notInstalled: "arrow.down.circle"
        case .downloading: "arrow.down.circle.fill"
        case .verifying: "checkmark.shield"
        case .ready: "checkmark.circle.fill"
        case .bundled: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .removing: "trash"
        }
    }
}
