import UIKit
import UniformTypeIdentifiers
import WebKit

// FORK-ONLY (shearmds/DuoBrowser, branch personal/save-to-caddy). Never include in upstream PRs.
//
// "Save to Caddy" hands the page to Caddy's iPhone Share extension the way Safari does. Safari runs
// the extension's preprocessing script (Caddy's SharePage.js) in the live, logged-in page and passes
// the result as a property list under NSExtensionJavaScriptPreprocessingResultsKey; Caddy's
// ShareViewController reads that before anything else. Any other app shares only the link, so
// Caddy downloads the page logged out and a paywalled article comes back as a stub.
//
// CaddySharePage.js is a verbatim copy of Caddy's iOS/Share/SharePage.js (Readability + DOMPurify +
// `caddyShareExtract`). Refresh it whenever Caddy's scripts/make-share-page-js.sh regenerates it.
// It runs in its own content world, like Reader: the page's scripts can't see or alter it.
@MainActor
enum CaddyShare {
    private static let world = WKContentWorld.world(name: "DuoBrowser.CaddyShare")
    private static var inFlight: Set<UUID> = []
    private static let script: String? = Bundle.main.url(forResource: "CaddySharePage", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    static func save(_ browser: BrowserModel) {
        guard let view = browser.loadedWebView, let url = browser.restorationURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        guard let script else {
            browser.errorMessage = "Save to Caddy is unavailable: its page script is missing from this build."
            return
        }
        let id = browser.id
        guard inFlight.insert(id).inserted else { return }
        let generation = browser.documentGeneration
        Task { @MainActor [weak browser, weak view] in
            defer { inFlight.remove(id) }
            guard let view else { return }
            let results = await extract(in: view, script: script)
            guard let browser, browser.documentGeneration == generation, browser.loadedWebView === view else { return }
            present(url: url, results: results, from: browser)
        }
    }

    /// Safari's payload shape: `{url, title, article}`. Nil when no article was found, so Caddy
    /// gets the plain link and falls back to its own download rather than an empty article.
    private static func extract(in view: WKWebView, script: String) async -> [String: Any]? {
        do {
            let loaded = try await view.callAsyncJavaScript(
                "return typeof caddyShareExtract === 'function';",
                arguments: [:], in: nil, contentWorld: world) as? Bool ?? false
            if !loaded { _ = try await view.evaluateJavaScript(script + "\n;true", in: nil, contentWorld: world) }
            let value = try await view.callAsyncJavaScript(
                """
                return { url: document.URL, title: document.title || "",
                         article: caddyShareExtract(document.cloneNode(true), document.title) };
                """,
                arguments: [:], in: nil, contentWorld: world)
            guard let results = value as? [String: Any],
                  let article = results["article"] as? [String: Any],
                  article["ok"] as? Bool == true else { return nil }
            return results
        } catch {
            return nil
        }
    }

    private static func present(url: URL, results: [String: Any]?, from browser: BrowserModel) {
        guard let presenter = browser.presentation.presenter, !(presenter is UIAlertController) else { return }
        // Two activity items: the link, and Safari's result under its preprocessing key, handed over
        // as an object-backed property-list provider. Found by trying each packaging against Caddy's
        // Share extension in the Duo simulator (2026-11-17); the others either hid Caddy (one
        // NSExtensionItem, a plain property-list item, a second NSItemProvider beside the link) or
        // offered only Save to Files (an NSExtensionItem alone). With this one Caddy is offered and
        // keeps the article as its offline copy.
        var items: [Any] = [url]
        if let results {
            items.append(CaddyPayloadSource(payload: [NSExtensionJavaScriptPreprocessingResultsKey: results]))
        }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = browser.loadedWebView
        activity.popoverPresentationController?.sourceRect = CGRect(x: 20, y: 20, width: 1, height: 1)
        presenter.present(activity, animated: true)
    }
}

/// The page result as its own share item. `itemForActivityType` must return an `NSItemProvider`
/// built with `init(item:typeIdentifier:)`: iOS 27 deprecates it, but it is the form whose
/// `loadItem` hands Caddy's extension an `NSDictionary`, as Safari's does.
private final class CaddyPayloadSource: NSObject, UIActivityItemSource {
    private let payload: NSDictionary
    init(payload: NSDictionary) { self.payload = payload }
    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { payload }
    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        NSItemProvider(item: payload, typeIdentifier: UTType.propertyList.identifier)
    }
    func activityViewController(_ controller: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        UTType.propertyList.identifier
    }
}
