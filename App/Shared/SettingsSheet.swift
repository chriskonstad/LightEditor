import EditorCore
import SwiftUI

/// Where the project lives, for the About links.
enum AppInfo {
    static let repository = URL(string: "https://github.com/chriskonstad/LightEditor")!
    static let issues = URL(string: "https://github.com/chriskonstad/LightEditor/issues")!
    static let privacyPolicy = URL(string: "https://github.com/chriskonstad/LightEditor/blob/main/docs/app-store/privacy-policy.md")!

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// A license bundled in `App/Resources/Licenses`, shown under Settings › Licenses.
struct Acknowledgement: Identifiable {
    let title: String
    let detail: String
    let resource: String

    var id: String { resource }

    var text: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "The license text is missing from this build." }
        return text
    }

    static let lightEditor = Acknowledgement(title: "LightEditor", detail: "MIT License", resource: "LightEditor-MIT")
    static let lama = Acknowledgement(
        title: "LaMa",
        detail: "Apache License 2.0 · Samsung Research. Used for AI removal, converted to Core ML.",
        resource: "LaMa-Apache-2.0"
    )
    static let stableDiffusion = Acknowledgement(
        title: "Stable Diffusion 1.5 inpainting",
        detail: "CreativeML Open RAIL-M · Runway and Stability AI. Used for “LaMa + diffusion”, converted to Core ML.",
        resource: "StableDiffusion-OpenRAIL-M"
    )

    /// The app's own license, plus each model this build bundles.
    static var all: [Acknowledgement] {
        var list = [lightEditor]
        if Inpainter.shared.isAvailable { list.append(lama) }
        if DiffusionInpainter.shared.isAvailable { list.append(stableDiffusion) }
        return list
    }
}

/// About, privacy and licenses.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LightEditor").font(.title2.bold())
                        Text("Version \(AppInfo.version)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Text("Free and open source, and it will always be subscription-free. Everything runs on this device: no account, no ads, no analytics, no tracking.")
                        .font(.subheadline)
                    Link(destination: AppInfo.repository) {
                        Label("Source Code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("settings.github")
                    Link(destination: AppInfo.issues) {
                        Label("Report a Problem", systemImage: "exclamationmark.bubble")
                    }
                }
                Section {
                    Link(destination: AppInfo.privacyPolicy) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("LightEditor collects no data. Your photos never leave your devices, except over the direct, encrypted link when you edit them from another device of yours.")
                }
                Section {
                    ForEach(Acknowledgement.all) { acknowledgement in
                        NavigationLink {
                            LicenseTextView(acknowledgement: acknowledgement)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(acknowledgement.title)
                                Text(acknowledgement.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("settings.license.\(acknowledgement.resource)")
                    }
                } header: {
                    Text("Licenses")
                } footer: {
                    Text("Fujifilm film simulation names are trademarks of FUJIFILM Corporation, used only to say which look a preset aims for. LightEditor isn't affiliated with Fujifilm, Adobe or Apple.")
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// The full text of one license.
struct LicenseTextView: View {
    let acknowledgement: Acknowledgement

    var body: some View {
        ScrollView {
            Text(acknowledgement.text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(acknowledgement.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Stable Diffusion's license binds everyone who runs the model to its use
/// restrictions (Open RAIL-M, paragraph 5), so "LaMa + diffusion" asks once first.
enum DiffusionTerms {
    static let defaultsKey = "diffusionTermsAccepted"
    static var accepted: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

/// Asks the user to accept the Stable Diffusion use restrictions before the first
/// diffusion removal.
struct DiffusionTermsSheet: View {
    let onAgree: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("“LaMa + diffusion” uses the Stable Diffusion 1.5 inpainting model, which is licensed under the CreativeML Open RAIL-M license. To use it, you agree to that license, including not to use the model:")
                        .font(.subheadline)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.restrictions, id: \.self) { restriction in
                            Label(restriction, systemImage: "xmark.circle").font(.subheadline)
                        }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("This is a summary. The full license, including Attachment A, is the agreement.")
                }
                Section {
                    NavigationLink("Read the Full License") {
                        LicenseTextView(acknowledgement: .stableDiffusion)
                    }
                }
            }
            .navigationTitle("Diffusion License")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Agree") {
                        UserDefaults.standard.set(true, forKey: DiffusionTerms.defaultsKey)
                        onAgree()
                        dismiss()
                    }
                    .accessibilityIdentifier("diffusionTerms.agree")
                }
            }
        }
        .presentationDetents([.large])
    }

    private static let restrictions = [
        "to break any law",
        "to exploit or harm minors",
        "to create false information meant to harm others",
        "to create personal information that can harm someone",
        "to defame, disparage or harass others",
        "for automated decisions affecting someone’s legal rights",
        "to discriminate against people or groups",
        "to exploit people’s vulnerabilities",
        "for medical advice",
        "for justice, law enforcement, immigration or asylum decisions",
    ]
}
