import EditorCore
import SwiftUI

/// Share this library with a nearby device, or edit a nearby device's library.
struct DevicesSheet: View {
    @Bindable var remote: RemoteModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let pending = remote.pending {
                ConnectionApprovalView(remote: remote, pending: pending)
            } else {
                devices
            }
        }
        .onAppear {
            remote.message = nil
            remote.devicesVisible = true
            if remote.connectedHost == nil { remote.startBrowsing() }
        }
        .onDisappear {
            remote.devicesVisible = false
            remote.stopBrowsing()
        }
    }

    private var devices: some View {
        NavigationStack {
            Form {
                if let host = remote.connectedHost {
                    Section {
                        if remote.reconnecting {
                            Label("Reconnecting to \(host)…", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("Editing the photos on \(host)", systemImage: "ipad.and.iphone")
                        }
                        Button("Disconnect", role: .destructive) { remote.disconnect() }
                            .accessibilityIdentifier("devices.disconnect")
                    } footer: {
                        Text(remote.reconnecting
                             ? "Keep editing: changes are kept on this device and saved to \(host) when it's back. Open LightEditor on \(host) to reconnect."
                             : "\(host) decodes, runs AI, and saves. This device edits, with sliders running here.")
                    }
                } else if let client = remote.editingClient {
                    Section {
                        Label(remote.clientConnected ? "\(client) is editing this library" : "\(client) is away and will reconnect",
                              systemImage: "ipad.and.iphone")
                        Button("Disconnect", role: .destructive) { remote.disconnect() }
                            .accessibilityIdentifier("devices.disconnect")
                    } footer: {
                        Text("You can lock this device or use other apps. \(client) keeps editing and catches up when you open LightEditor again.")
                    }
                } else {
                    Section {
                        Toggle("Let nearby devices edit this library", isOn: $remote.sharing)
                            .accessibilityIdentifier("devices.share")
                    } footer: {
                        Text("Turn this on on the device with the photos, usually your iPhone. It does the heavy work: RAW decodes, AI and saving to Photos. Devices connect directly over Wi-Fi, without a network or cellular.")
                    }
                    Section("Nearby") {
                        if remote.discovered.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Looking for devices sharing their library…").foregroundStyle(Theme.textSecondary)
                            }
                        }
                        ForEach(remote.discovered) { peer in
                            Button {
                                remote.connect(to: peer)
                            } label: {
                                HStack {
                                    Label(peer.name, systemImage: peer.name.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone")
                                    Spacer()
                                    if remote.connecting == peer.name { ProgressView().controlSize(.small) } else { Text("Edit").foregroundStyle(Theme.accent) }
                                }
                            }
                            .disabled(remote.connecting != nil)
                            .accessibilityIdentifier("devices.peer.\(peer.name)")
                        }
                    }
                }
                if !remote.trustedDevices.isEmpty {
                    Section {
                        ForEach(remote.trustedDevices) { device in
                            HStack {
                                Text(device.name)
                                Spacer()
                                Button("Forget", role: .destructive) { remote.forget(device) }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("devices.forget.\(device.name)")
                            }
                        }
                    } header: {
                        Text("Allowed devices")
                    } footer: {
                        Text("These reconnect without asking. Forget one to require the code again.")
                    }
                }
                if let message = remote.message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Devices")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Asks to allow a connection, showing the code both devices must match.
struct ConnectionApprovalView: View {
    let remote: RemoteModel
    let pending: RemoteModel.Pending

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "ipad.and.iphone")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text(pending.isHost ? "Let \(pending.peerName) edit your photos?" : "Edit the photos on \(pending.peerName)?")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(pending.code)
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .accessibilityLabel("Code \(pending.code)")
                .accessibilityIdentifier("approval.code")
            Text("Check that \(pending.peerName) shows the same code, then allow on both devices.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if pending.allowed {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(pending.peerName)…").foregroundStyle(Theme.textSecondary)
                }
                Button("Cancel", role: .cancel) { remote.respond(allow: false) }
                    .accessibilityIdentifier("approval.cancel")
            } else {
                HStack(spacing: 12) {
                    Button("Don't Allow", role: .cancel) { remote.respond(allow: false) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("approval.decline")
                    Button("Allow") { remote.respond(allow: true) }
                        .buttonStyle(AccentButtonStyle())
                        .accessibilityIdentifier("approval.allow")
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .interactiveDismissDisabled()
        .presentationDetents([.medium])
    }
}

/// Shown above the library while editing remotely, or while another device edits this one.
struct RemoteBanner: View {
    let remote: RemoteModel

    private var bannerText: String? {
        if let host = remote.connectedHost {
            return remote.reconnecting ? "Reconnecting to \(host)… edits are kept here" : "Photos on \(host)"
        }
        if let client = remote.editingClient {
            return remote.clientConnected ? "\(client) is editing this library" : "\(client) will reconnect"
        }
        return nil
    }

    var body: some View {
        if let text = bannerText {
            HStack(spacing: 8) {
                if remote.reconnecting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "ipad.and.iphone")
                }
                Text(text).font(.footnote.weight(.medium))
                Spacer()
                Button("Disconnect") { remote.disconnect() }
                    .font(.footnote)
                    .accessibilityIdentifier("banner.disconnect")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal)
            .padding(.top, 6)
            .accessibilityIdentifier("remoteBanner")
        }
    }
}
