import AppKit
import SafariServices

/// Handles `browser.runtime.sendNativeMessage` from the extension. Its only job is to launch the
/// Soft Subs app when the popup can't reach the helper server.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        var reply: [String: Any] = ["ok": true]
        if message?["action"] as? String == "launchApp" {
            reply["launched"] = NSWorkspace.shared.open(URL(string: "softsubs://open")!)
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response])
    }
}
