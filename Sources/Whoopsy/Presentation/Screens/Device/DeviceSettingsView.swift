import SwiftUI

public struct DeviceSettingsView: View {
    @State private var viewModel: DeviceViewModel
    public init(viewModel: DeviceViewModel) { _viewModel = State(initialValue: viewModel) }
    public var body: some View { Form {
        Section("WHOOP strap") {
            LabeledContent("Connection", value: viewModel.device?.connectionState.rawValue ?? "Disconnected")
            LabeledContent("Battery", value: "\(viewModel.device?.batteryPercentage ?? 0)%")
            LabeledContent("Firmware", value: viewModel.device?.firmwareVersion ?? "—")
            Button(viewModel.isScanning ? "Scanning…" : "Find strap") { Task { await viewModel.scan() } }
            Button("Sync history") { Task { await viewModel.syncNow() } }
        }
        Section("Live heart rate") {
            Toggle("Broadcast live HR", isOn: Binding(get: { viewModel.preferences.liveHeartRateBroadcastEnabled }, set: { value in Task { await viewModel.setBroadcast(value) } }))
            Text("Preference is stored locally. Broadcasting requires a supported strap transport.").font(.caption).foregroundStyle(.secondary)
        }
        if !viewModel.status.isEmpty { Section { Text(viewModel.status).font(.footnote) } }
    }.scrollContentBackground(.hidden).background(Theme.backgroundDark).task { await viewModel.load() }.preferredColorScheme(.dark) }
}
