// Minimal native-messaging handler; the extension never messages native code,
// but Safari requires the appex to have a principal class.
import SafariServices

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
