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
            // All four tables now skip a day that already holds data, so an edit made on the activity
            // detail page survives a press of this button. **What is still not durable is a delete**,
            // and the caption says so: `Delete` removes the row and the day it was on becomes empty
            // again, so the export's row for it is re-imported. Making that durable needs a tombstone
            // and a schema version, which is a wider change than the caption.
            Text("Loads the WHOOP export bundled with this app, so a new install shows your history instead of starting empty. Days already recorded on this device are left untouched, so edits you make are kept — but an activity you deleted will come back.").font(.caption).foregroundStyle(.secondary)
            // **Its own button and its own caption**, because the export's caption does not describe
            // it: this file is a fasting tracker's history rather than WHOOP's, its rows carry no
            // measurement at all, and it is the one import here that does **not** skip a day already
            // recorded — a fast's own id is disjoint from every other producer's, so it can sit beside
            // an export workout on the same day. The delete sentence applies to it for the same reason
            // it applies above, and is restated rather than inherited.
            Button("Import Zero fasting history") { Task { await viewModel.importFastingHistory() } }
            Text("Loads the fasting history bundled with this app as activities on the days each fast started. A fast has no heart rate or strain behind it, so those figures stay blank. Re-importing is safe, but a fast you deleted will come back.").font(.caption).foregroundStyle(.secondary)
            if viewModel.isImporting { HStack(spacing: 8) { ProgressView(); Text("Importing…").font(.caption) } }
            Button("Prepare JSON + CSV export") { Task { await viewModel.exportData() } }
            if let export = viewModel.export { ShareLink(item: export.jsonString, preview: SharePreview("Whoopsy local export")) { Label("Share JSON export", systemImage: "square.and.arrow.up") } }
        }
        if !viewModel.status.isEmpty { Section { Text(viewModel.status).font(.footnote) } }
    }.scrollContentBackground(.hidden).background(Theme.backgroundDark).task { await viewModel.load() }.preferredColorScheme(.dark) }
}
