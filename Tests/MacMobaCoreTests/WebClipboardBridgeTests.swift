import WebKit
import XCTest

@testable import MacMobaCore

/// The bridge is a JavaScript string, so a typo in it would compile fine and
/// break copying on every internal site again. These run it in a real WebKit
/// engine against a stub message handler.
@MainActor
final class WebClipboardBridgeTests: XCTestCase {
    /// A page that records what the bridge posts instead of reaching AppKit.
    private func webViewWithStubHandler() -> WKWebView {
        let stub = """
        window.webkit = window.webkit || {};
        window.webkit.messageHandlers = window.webkit.messageHandlers || {};
        window.__posted = [];
        window.webkit.messageHandlers.\(WebClipboardBridge.handlerName) = {
          postMessage: function (m) { window.__posted.push(m); }
        };
        """
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: stub, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: WebClipboardBridge.script,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func evaluate(_ javaScript: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(javaScript) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    /// For anything that has to await a promise: evaluateJavaScript cannot
    /// return one to Swift.
    private func callAsync(_ body: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(body, in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadedWebView() async throws -> WKWebView {
        let webView = webViewWithStubHandler()
        // A data: URL is not a secure context, which is the situation the
        // bridge exists for.
        webView.loadHTMLString("<html><body>hi</body></html>",
                               baseURL: URL(string: "http://10.99.99.99/"))
        for _ in 0..<100 {
            if webView.isLoading == false,
               let ready = try? await evaluate("document.readyState", in: webView) as? String,
               ready == "complete" { return webView }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("web view never finished loading")
    }

    /// The script parses and installs itself.
    func testTheScriptRunsAndDefinesClipboard() async throws {
        let webView = try await loadedWebView()
        let type = try await evaluate("typeof navigator.clipboard.writeText", in: webView)
        XCTAssertEqual(type as? String, "function")
    }

    /// What a copy button actually calls.
    func testWriteTextPostsTheTextNatively() async throws {
        let webView = try await loadedWebView()
        _ = try await evaluate("navigator.clipboard.writeText('sk-lf-secret-4242'); null",
                               in: webView)
        let posted = try await evaluate("JSON.stringify(window.__posted)", in: webView)
        XCTAssertEqual(posted as? String, "[\"sk-lf-secret-4242\"]")
    }

    /// The promise has to resolve, or the site's own "copied!" feedback — and
    /// anything it chains afterwards — never runs.
    func testWriteTextResolves() async throws {
        let webView = try await loadedWebView()
        let result = try await callAsync("""
            await navigator.clipboard.writeText('x');
            return 'resolved';
            """, in: webView)
        XCTAssertEqual(result as? String, "resolved")
    }

    /// Non-strings must not arrive as "[object Object]" or crash the page.
    func testNumbersAreCoerced() async throws {
        let webView = try await loadedWebView()
        _ = try await evaluate("navigator.clipboard.writeText(4242); null", in: webView)
        let posted = try await evaluate("JSON.stringify(window.__posted)", in: webView)
        XCTAssertEqual(posted as? String, "[\"4242\"]")
    }

    /// The richer API, used by sites that copy images or html alongside text.
    func testWriteTakesTextPlainFromAClipboardItem() async throws {
        let webView = try await loadedWebView()
        _ = try await evaluate("""
            navigator.clipboard.write([{
              getType: function () {
                return Promise.resolve({ text: function () {
                  return Promise.resolve('from-clipboard-item');
                }});
              }
            }]); null
            """, in: webView)
        // The write() path is two promises deep.
        try await Task.sleep(nanoseconds: 300_000_000)
        let posted = try await evaluate("JSON.stringify(window.__posted)", in: webView)
        XCTAssertEqual(posted as? String, "[\"from-clipboard-item\"]")
    }

    /// On https the browser's own implementation must be left alone — the
    /// bridge is a fallback, not a replacement.
    func testAnExistingClipboardIsNotReplaced() async throws {
        let webView = webViewWithStubHandler()
        let preinstalled = """
        Object.defineProperty(navigator, 'clipboard', {
          value: { writeText: function () { window.__native = true; return Promise.resolve(); } },
          configurable: true
        });
        """
        webView.configuration.userContentController.removeAllUserScripts()
        for source in [preinstalled, WebClipboardBridge.script] {
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart,
                             forMainFrameOnly: true))
        }
        webView.loadHTMLString("<html><body>hi</body></html>",
                               baseURL: URL(string: "http://10.99.99.99/"))
        for _ in 0..<100 {
            if !webView.isLoading { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = try await evaluate("navigator.clipboard.writeText('x'); null", in: webView)
        let usedNative = try await evaluate("window.__native === true", in: webView)
        XCTAssertEqual(usedNative as? Bool, true)
    }
}
