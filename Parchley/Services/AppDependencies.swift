import Foundation
import AppKit
import Observation
import ParchleyEngine

/// The application-wide services used by the SwiftUI feature model.
///
/// Keeping construction here gives the app one composition root and makes the
/// feature model usable with temporary stores and deterministic services in
/// tests.
@MainActor
struct ParchleyDependencies {
    let store: WorkspaceStore?
    let fileAccess: FileAccessService
    let exportService: ExportService
    let coordinator: ConversionCoordinator?
    let ocrManager: OCRModelManager?
    let ocrManifest: ModelManifest
    let preferences: AppPreferences
    let pasteboard: NSPasteboard
    let dateProvider: DateProvider
    let now: @Sendable () -> Date
    let fileExists: @Sendable (URL) -> Bool
    let initializationMessage: String?

    init(
        store: WorkspaceStore?,
        fileAccess: FileAccessService = FileAccessService(),
        exportService: ExportService = ExportService(),
        coordinator: ConversionCoordinator?,
        ocrManager: OCRModelManager?,
        ocrManifest: ModelManifest,
        preferences: AppPreferences,
        pasteboard: NSPasteboard = .general,
        dateProvider: DateProvider? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        initializationMessage: String? = nil
    ) {
        let resolvedDateProvider = dateProvider ?? DateProvider(now: now)
        self.store = store
        self.fileAccess = fileAccess
        self.exportService = exportService
        self.coordinator = coordinator
        self.ocrManager = ocrManager
        self.ocrManifest = ocrManifest
        self.preferences = preferences
        self.pasteboard = pasteboard
        self.dateProvider = resolvedDateProvider
        self.now = resolvedDateProvider.now
        self.fileExists = fileExists
        self.initializationMessage = initializationMessage
    }

    /// Builds the production dependency graph and preserves actionable startup
    /// failures for the UI instead of terminating the app.
    static func live(
        defaults: UserDefaults = .standard,
        pasteboard: NSPasteboard = .general,
        dateProvider: DateProvider = DateProvider()
    ) -> Self {
        let preferences = AppPreferences(defaults: defaults)

        let manifest: ModelManifest
        do {
            manifest = try OCRModelCatalog.defaultManifest()
        } catch {
            return Self(
                store: nil,
                coordinator: nil,
                ocrManager: nil,
                ocrManifest: .unavailable,
                preferences: preferences,
                pasteboard: pasteboard,
                now: dateProvider.now,
                initializationMessage: "The OCR model configuration is invalid. " + error.localizedDescription
            )
        }

        let workspace: WorkspaceStore
        do {
            workspace = try WorkspaceStore(dateProvider: dateProvider)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return Self(
                store: nil,
                coordinator: nil,
                ocrManager: nil,
                ocrManifest: manifest,
                preferences: preferences,
                pasteboard: pasteboard,
                now: dateProvider.now,
                initializationMessage: "Parchley could not open its workspace. " + detail
            )
        }

        let manager: OCRModelManager?
        let managerMessage: String?
        do {
            manager = try OCRModelManager(
                root: workspace.root.appendingPathComponent("Models", isDirectory: true),
                bundledRoot: Bundle.main.resourceURL
            )
            managerMessage = nil
        } catch {
            manager = nil
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            managerMessage = "OCR model storage is unavailable. " + detail
        }
        do {
            let rust = try RustEngine()
            let coordinator = ConversionCoordinator(
                engine: RustConversionEngine(engine: rust),
                store: workspace,
                dateProvider: dateProvider
            )
            return Self(
                store: workspace,
                coordinator: coordinator,
                ocrManager: manager,
                ocrManifest: manifest,
                preferences: preferences,
                pasteboard: pasteboard,
                now: dateProvider.now,
                initializationMessage: managerMessage ?? (manager == nil ? "OCR model storage is unavailable. Conversion without OCR is still available." : nil)
            )
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSLog("Parchley engine initialization failed: %@", detail)
            return Self(
                store: workspace,
                coordinator: nil,
                ocrManager: manager,
                ocrManifest: manifest,
                preferences: preferences,
                pasteboard: pasteboard,
                now: dateProvider.now,
                initializationMessage: "The bundled conversion engine could not be loaded. " + detail
            )
        }
    }
}

/// User preferences used by conversion and history features.
@MainActor @Observable
final class AppPreferences {
    static let supportedRetentionDays: Set<Int> = [7, 30, 90]

    private let defaults: UserDefaults
    var ocrEnabled: Bool {
        didSet { defaults.set(ocrEnabled, forKey: "ocrEnabled") }
    }
    var retentionDays: Int {
        didSet {
            if !Self.supportedRetentionDays.contains(retentionDays) {
                retentionDays = 30
            }
            defaults.set(retentionDays, forKey: "retentionDays")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["ocrEnabled": true, "retentionDays": 30])
        self.ocrEnabled = defaults.bool(forKey: "ocrEnabled")
        let retentionDays = defaults.integer(forKey: "retentionDays")
        self.retentionDays = Self.supportedRetentionDays.contains(retentionDays)
            ? retentionDays
            : 30
    }
}
