import SwiftUI

public struct SettingsDashboardView: View {
    @State private var viewModel: SettingsViewModel
    public init(viewModel: SettingsViewModel) { _viewModel = State(initialValue: viewModel) }
    public var body: some View { Form {
        Section("Privacy") {
            Toggle("Anonymous diagnostics", isOn: Binding(get: { viewModel.preferences.analyticsEnabled }, set: { viewModel.preferences.analyticsEnabled = $0; Task { await viewModel.save() } }))
            Text("Whoopsy is local-first; this preference never enables cloud biometric uploads.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Apple Health") {
            Toggle("HealthKit sync", isOn: Binding(get: { viewModel.preferences.healthKitSyncEnabled }, set: { _ in Task { await viewModel.authorizeHealthKit() } })).disabled(!viewModel.healthKitAvailable)
            Text(viewModel.healthKitAvailable ? "Reads HRV and resting heart rate from Apple Health into this app. Nothing is uploaded." : viewModel.healthKitUnavailableReason).font(.caption).foregroundStyle(.secondary)
            if viewModel.isImporting { HStack(spacing: 8) { ProgressView(); Text("Importing…").font(.caption) } }
        }
        Section("Local backup") {
            Button(viewModel.preferences.hasImportedWhoopExport ? "Re-import WHOOP history" : "Import WHOOP history") { Task { await viewModel.importWhoopExport() } }
            Text("Loads the WHOOP export bundled with this app, so a new install shows your history instead of starting empty. Days already recorded on this device are left untouched — re-importing is safe.").font(.caption).foregroundStyle(.secondary)
            if viewModel.isImporting { HStack(spacing: 8) { ProgressView(); Text("Importing…").font(.caption) } }
            Button("Prepare JSON + CSV export") { Task { await viewModel.exportData() } }
            if let export = viewModel.export { ShareLink(item: export.jsonString, preview: SharePreview("Whoopsy local export")) { Label("Share JSON export", systemImage: "square.and.arrow.up") } }
        }
        if !viewModel.status.isEmpty { Section { Text(viewModel.status).font(.footnote) } }
    }.scrollContentBackground(.hidden).background(Theme.backgroundDark).task { await viewModel.load() }.preferredColorScheme(.dark) }
}
