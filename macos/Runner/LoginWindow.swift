import Cocoa
import FlutterMacOS
import WebKit

/// The channel build's login window (see lib/channel/account/): the user's
/// channel's account site in a web view of its own, signed in to as in a
/// browser, its cookies and storage kept in memory only, gone once it
/// closes. Over `caocode/login_window`: `open`, `evaluate` (a script's
/// value, as the JSON string the script makes of it), `cookies` (the site's,
/// HttpOnly ones too) and `close`; `closed` back, however it closed.
final class LoginWindowChannel: NSObject, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
  private let channel: FlutterMethodChannel
  private var window: NSWindow?
  private var webView: WKWebView?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "caocode/login_window", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "open":
      guard let text = arguments?["url"] as? String, let url = URL(string: text),
        url.scheme == "https" || url.scheme == "http"
      else {
        result(FlutterError(code: "url", message: "Not a web address", details: nil))
        return
      }
      open(url, title: arguments?["title"] as? String ?? "")
      result(nil)
    case "evaluate":
      guard let webView, let script = arguments?["script"] as? String else {
        result(nil)
        return
      }
      webView.evaluateJavaScript(script) { value, _ in
        result(value as? String)
      }
    case "cookies":
      guard let webView, let text = arguments?["url"] as? String,
        let host = URL(string: text)?.host?.lowercased()
      else {
        result([String: String]())
        return
      }
      webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
        var found = [String: String]()
        for cookie in cookies where Self.domain(cookie.domain, covers: host) {
          found[cookie.name] = cookie.value
        }
        result(found)
      }
    case "close":
      window?.close()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Whether a cookie set for [domain] goes to [host]: its own, or one
  /// under it (`.example.com`).
  private static func domain(_ domain: String, covers host: String) -> Bool {
    let bare = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return host == bare || host.hasSuffix("." + bare)
  }

  private func open(_ url: URL, title: String) {
    // One at a time: a new one in place of the one before, which is not
    // said to have closed (this one is open).
    let before = window
    window = nil
    webView = nil
    before?.close()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    // As Safari's: some sites turn away a web view that does not say so.
    configuration.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15"
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.uiDelegate = self
    webView.navigationDelegate = self
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = title
    window.contentView = webView
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 360, height: 480)
    window.delegate = self
    // Over the app's window it was opened from.
    if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
      let frame = parent.frame
      window.setFrameOrigin(
        NSPoint(
          x: frame.midX - window.frame.width / 2,
          y: frame.midY - window.frame.height / 2))
    } else {
      window.center()
    }
    self.window = window
    self.webView = webView
    webView.load(URLRequest(url: url))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow, closing == window else { return }
    webView?.stopLoading()
    webView = nil
    window = nil
    channel.invokeMethod("closed", arguments: nil)
  }

  // MARK: WKUIDelegate

  /// A page's `window.open` (a sign-in with another site's account, say):
  /// in the same view, the window being the user's only one here.
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if navigationAction.targetFrame == nil {
      webView.load(navigationAction.request)
    }
    return nil
  }

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
  ) {
    guard let window else { return completionHandler() }
    let alert = NSAlert()
    alert.messageText = message
    alert.beginSheetModal(for: window) { _ in completionHandler() }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
  ) {
    guard let window else { return completionHandler(false) }
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { response in
      completionHandler(response == .alertFirstButtonReturn)
    }
  }

  // MARK: WKNavigationDelegate

  /// Links to elsewhere than the web (mailto:, an app's): the system's.
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
      !["http", "https", "about", "blob", "data"].contains(scheme)
    {
      NSWorkspace.shared.open(url)
      return decisionHandler(.cancel)
    }
    decisionHandler(.allow)
  }
}
