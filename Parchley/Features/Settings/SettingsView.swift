import SwiftUI

struct SettingsView: View {
    let model: ParchleyAppModel

    @AppStorage("ocrEnabled") private var ocrEnabled = true
    @AppStorage("retentionDays") private var retentionDays = 30
    @State private var modelState: ModelState = .notInstalled
    @State private var modelProgress: ModelProgress?
    @State private var isClearingHistory = false

    private var totalDownloadBytes: Int64 {
        model.ocrManifest.artifacts.reduce(0) { $0 + $1.byteCount }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Use OCR when a page needs it", isOn: $ocrEnabled)
                Text("Parchley keeps conversion local. OCR is used only for pages without selectable text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("Conversion", systemImage: "doc.text.magnifyingglass")
            }

            Section {
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
            } header: {
                Label("OCR model", systemImage: "cpu")
            }

            Section {
                LabeledContent("Keep completed results") {
                    Picker("Keep completed results", selection: $retentionDays) {
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
            } header: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 12)
        .task {
            await refreshModelState()
            await pollModelState()
        }
        .onChange(of: retentionDays) { _, days in
            pruneHistory(days: days)
        }
        .confirmationDialog("Clear completed history?", isPresented: $isClearingHistory) {
            Button("Clear History", role: .destructive) { clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved drafts remain available for review.")
        }
    }

    private func refreshModelState() async {
        if let manager = model.ocrManager {
            _ = await manager.discover(model.ocrManifest)
            await updateModelState(from: manager)
        }
        pruneHistory(days: retentionDays)
    }

    private func pollModelState() async {
        guard let manager = model.ocrManager else { return }
        while !Task.isCancelled {
            await updateModelState(from: manager)
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    private func updateModelState(from manager: OCRModelManager) async {
        modelState = await manager.state
        modelProgress = await manager.progress
    }

    private func installModel() {
        guard let manager = model.ocrManager else { return }
        modelState = .downloading
        modelProgress = ModelProgress(completedBytes: 0,
                                      totalBytes: totalDownloadBytes,
                                      artifact: model.ocrManifest.artifacts.first?.name ?? "")
        Task {
            do {
                _ = try await manager.install(model.ocrManifest)
            } catch {
                model.alertMessage = error.localizedDescription
            }
            await updateModelState(from: manager)
        }
    }

    private func cancelModelDownload() {
        Task { await model.ocrManager?.cancelInstallation() }
    }

    private func removeModel() {
        guard let manager = model.ocrManager else { return }
        Task {
            do {
                try await manager.remove()
            } catch {
                model.alertMessage = error.localizedDescription
            }
            await updateModelState(from: manager)
        }
    }

    private func pruneHistory(days: Int) {
        guard let store = model.store else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        Task {
            try? await store.prune(completedBefore: cutoff, maximumCount: 20)
            await model.reload()
        }
    }

    private func clearHistory() {
        Task {
            do {
                try await model.store?.clearHistory()
                await model.reload()
            } catch {
                model.alertMessage = "Could not clear history: \(error.localizedDescription)"
            }
        }
    }
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
                    .foregroundStyle(state.tint)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text("PaddleOCR v6 small")
                        .foregroundStyle(.primary)
                    Text(state.statusLabel)
                        .font(.callout)
                        .foregroundStyle(state.tint)
                    Text("\(revision) · \(byteString(totalBytes)) · runs locally")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
                action
            }

            if case .downloading = state {
                VStack(alignment: .leading, spacing: 7) {
                    ProgressView(value: progress.map { Double($0.completedBytes) }, total: Double(totalBytes)) {
                        Text(progress.map { "Downloading \($0.artifact)" } ?? "Downloading OCR model")
                    } currentValueLabel: {
                        Text(progressPercent)
                            .monospacedDigit()
                    }
                        .progressViewStyle(.linear)
                        .accessibilityLabel("OCR model download progress")
                        .accessibilityValue(progressDescription)

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
                    .foregroundStyle(.orange)
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
                .buttonStyle(.borderedProminent)
                .disabled(!isAvailable)
        case .downloading:
            Button("Cancel", action: cancel)
        case .verifying, .removing:
            ProgressView(state == .verifying ? "Verifying" : "Removing")
                .controlSize(.small)
                .accessibilityLabel(state == .verifying ? "Verifying" : "Removing")
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
    var statusLabel: String {
        switch self {
        case .notInstalled: "Not downloaded"
        case .downloading: "Downloading…"
        case .verifying: "Verifying…"
        case .ready: "Installed"
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
        case .failed: "exclamationmark.triangle.fill"
        case .removing: "trash"
        }
    }

    var tint: Color {
        switch self {
        case .notInstalled, .downloading, .verifying, .removing: .accentColor
        case .ready: .green
        case .failed: .orange
        }
    }
}
