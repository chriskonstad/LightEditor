import EditorCore
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What both platforms' extensions do: read what identifies the shared copy.
enum ShareHandoff {
    static func photo(from items: [Any]?) async -> SharedPhoto? {
        let providers = (items as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }),
              let photo = await sharedPhoto(from: provider), photo.searchRange != nil else { return nil }
        return photo
    }

    /// Reads the shared copy while the item provider keeps its temporary file.
    private static func sharedPhoto(from provider: NSItemProvider) async -> SharedPhoto? {
        let type = provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? .image
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type) { url, _, _ in
                continuation.resume(returning: url.flatMap { SharedPhoto(imageAt: $0, name: suggested) })
            }
        }
    }

    static let noDate = "This photo has no capture date, so LightEditor can't find it in your library. Open it from the LightEditor app instead."
    static let cantOpen = "LightEditor couldn't be opened from here. Open the app and choose the photo there."
}

#if os(iOS)
/// "Edit in LightEditor" in the share sheet of Apple Photos.
///
/// Photos hands share extensions a rendered copy of the photo, never the library
/// asset, so this only reads what identifies the photo (`SharedPhoto`) and opens the
/// app with a `lighteditor://edit` URL. The app finds the asset in its own library and
/// edits the original there, with its full memory budget and the usual PhotoKit save.
/// See docs/spikes/open-from-photos.md.
final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let closeButton = UIButton(configuration: .filled())

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous

        message.text = "Opening in LightEditor…"
        message.font = .preferredFont(forTextStyle: .body)
        message.numberOfLines = 0
        message.textAlignment = .center

        closeButton.configuration?.title = "Close"
        closeButton.isHidden = true
        closeButton.addAction(UIAction { [weak self] _ in self?.finish() }, for: .primaryActionTriggered)

        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [spinner, message, closeButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center

        card.addSubview(stack)
        view.addSubview(card)
        for subview in [card, stack] { subview.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 300),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handOff() }
    }

    private func handOff() async {
        guard let photo = await ShareHandoff.photo(from: extensionContext?.inputItems) else {
            show(ShareHandoff.noDate)
            return
        }
        if await openApp(PhotoHandoff(photo: photo).url) {
            finish()
        } else {
            show(ShareHandoff.cantOpen)
        }
    }

    /// Extensions have no `UIApplication.shared`, and `NSExtensionContext.open` only
    /// works for widgets, but the application object is in the responder chain and its
    /// public `open(_:)` is available to extensions.
    private func openApp(_ url: URL) async -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await application.open(url)
            }
            responder = current.next
        }
        return false
    }

    private func show(_ text: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        message.text = text
        closeButton.isHidden = false
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
#else
/// "Edit in LightEditor" in the Share menu of Photos for Mac: the same handoff as on
/// iOS, opening the app with `NSWorkspace`. See docs/spikes/open-from-photos.md.
final class ShareViewController: NSViewController {
    private let message = NSTextField(wrappingLabelWithString: "Opening in LightEditor…")
    private let spinner = NSProgressIndicator()
    private lazy var closeButton = NSButton(title: "Close", target: self, action: #selector(close))

    override func loadView() {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        message.alignment = .center
        closeButton.isHidden = true
        let stack = NSStackView(views: [spinner, message, closeButton])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 320),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await handOff() }
    }

    private func handOff() async {
        guard let photo = await ShareHandoff.photo(from: extensionContext?.inputItems) else {
            show(ShareHandoff.noDate)
            return
        }
        if NSWorkspace.shared.open(PhotoHandoff(photo: photo).url) {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            show(ShareHandoff.cantOpen)
        }
    }

    private func show(_ text: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        message.stringValue = text
        closeButton.isHidden = false
    }

    @objc private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
#endif
