import Foundation
import WebKit

/// Converts an SVG file to a one-page vector PDF, for watermark logos.
///
/// Neither ImageIO nor UIKit decodes SVG (checked on iOS and macOS 27), and only
/// AppKit does, so a logo is converted once, on import, with WebKit's PDF output,
/// which keeps the paths as vectors and the background transparent. After that it's
/// an ordinary PDF: drawn sharp at any size, and readable by every device and the
/// remote host without WebKit. See "Watermark logos" in docs/DESIGN.md.
@MainActor
public enum SVGToPDF {
    public enum ConversionError: LocalizedError {
        case unreadable, empty
        public var errorDescription: String? {
            switch self {
            case .unreadable: "The SVG couldn't be read."
            case .empty: "The SVG has no visible size."
            }
        }
    }

    /// The largest page size, in points, an SVG without its own size is laid out at.
    static let layoutSize = CGSize(width: 1000, height: 1000)

    public static func convert(_ svg: Data) async throws -> Data {
        guard let markup = String(data: svg, encoding: .utf8), markup.contains("<svg") else { throw ConversionError.unreadable }
        // Only the SVG element, without an XML prolog or doctype, inside a page with
        // no margins or background. Scripts are off, and nothing is fetched.
        let body = markup.range(of: "<svg").map { String(markup[$0.lowerBound...]) } ?? markup
        let html = """
        <!doctype html><html><head><meta charset="utf-8">\
        <style>html,body{margin:0;padding:0;background:transparent}svg{display:block;max-width:100%}</style>\
        </head><body>\(body)</body></html>
        """
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: CGRect(origin: .zero, size: layoutSize), configuration: configuration)
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        #endif
        let loader = Loader()
        web.navigationDelegate = loader
        web.loadHTMLString(html, baseURL: nil)
        try await loader.finished()

        // Page JavaScript is off, but the app's own evaluation still runs.
        let measured = try await web.evaluateJavaScript(
            "(() => { const r = document.querySelector('svg')?.getBoundingClientRect(); return r ? [r.width, r.height] : [0, 0] })()"
        ) as? [Double] ?? [0, 0]
        guard measured.count == 2, measured[0] >= 1, measured[1] >= 1 else { throw ConversionError.empty }
        let pdfConfiguration = WKPDFConfiguration()
        pdfConfiguration.rect = CGRect(x: 0, y: 0, width: measured[0], height: measured[1])
        return try await web.pdf(configuration: pdfConfiguration)
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, any Error>?
        private var result: Result<Void, any Error>?

        func finished() async throws {
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        private func finish(_ result: Result<Void, any Error>) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(with: result)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            finish(.failure(error))
        }
    }
}
