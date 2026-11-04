import UIKit
import receive_sharing_intent

// The plugin's RSIShareViewController redirects as soon as the last attachment
// finishes loading, so when several photos are shared at once any that are still
// copying get dropped. This waits for every attachment, then hands them to the app
// in the same format the plugin reads.
class ShareViewController: UIViewController {
    private let inboxFolder = "ShareInbox"

    // No UI: keep the system sheet transparent while we hand off, as the plugin does.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        var current: UIView? = view
        while let v = current {
            v.backgroundColor = .clear
            v.isOpaque = false
            current = v.superview
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let inbox = prepareInbox(), !attachments.isEmpty else {
            cancel()
            return
        }

        var media = [SharedMediaFile?](repeating: nil, count: attachments.count)
        let group = DispatchGroup()
        for (index, attachment) in attachments.enumerated() {
            guard let type = [SharedMediaType.image, .file].first(where: {
                attachment.hasItemConformingToTypeIdentifier($0.toUTTypeIdentifier)
            }) else { continue }
            group.enter()
            attachment.loadItem(forTypeIdentifier: type.toUTTypeIdentifier) { data, _ in
                // Index prefix keeps same-named items (e.g. edited photos are all
                // "FullSizeRender.jpg") from overwriting each other.
                let file = Self.save(data, type: type, to: inbox, prefix: "\(index)_")
                DispatchQueue.main.async {
                    media[index] = file
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            let files = media.compactMap { $0 }
            guard let self = self, !files.isEmpty else {
                self?.cancel()
                return
            }
            self.saveAndRedirect(files)
        }
    }

    // A fresh inbox per share so old ZIPs and photos don't pile up in the app group.
    private func prepareInbox() -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        let inbox = container.appendingPathComponent(inboxFolder, isDirectory: true)
        try? FileManager.default.removeItem(at: inbox)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return inbox
    }

    private static func save(_ data: NSSecureCoding?, type: SharedMediaType, to inbox: URL, prefix: String) -> SharedMediaFile? {
        let destination: URL
        if let url = data as? URL {
            destination = inbox.appendingPathComponent(prefix + url.lastPathComponent)
            guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { return nil }
        } else if let image = data as? UIImage, let png = image.pngData() {
            destination = inbox.appendingPathComponent(prefix + "image.png")
            guard (try? png.write(to: destination)) != nil else { return nil }
        } else {
            return nil
        }
        // The plugin expects decoded paths, not percent-encoded ones.
        let path = destination.absoluteString.removingPercentEncoding ?? destination.absoluteString
        return SharedMediaFile(path: path, mimeType: destination.mimeType(), type: type)
    }

    private func saveAndRedirect(_ files: [SharedMediaFile]) {
        let userDefaults = UserDefaults(suiteName: appGroupId)
        userDefaults?.set(try? JSONEncoder().encode(files), forKey: kUserDefaultsKey)
        userDefaults?.removeObject(forKey: kUserDefaultsMessageKey)
        userDefaults?.synchronize()

        let url = URL(string: "\(kSchemePrefix)-\(hostAppBundleIdentifier):share")!
        var responder: UIResponder? = self
        if #available(iOS 18.0, *) {
            while let current = responder {
                (current as? UIApplication)?.open(url, options: [:], completionHandler: nil)
                responder = current.next
            }
        } else {
            let selectorOpenURL = sel_registerName("openURL:")
            while let current = responder {
                if current.responds(to: selectorOpenURL) {
                    _ = current.perform(selectorOpenURL, with: url)
                }
                responder = current.next
            }
        }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "ShareViewController", code: 0))
    }

    // "<host bundle id>.Share-Extension" -> "<host bundle id>", as the plugin derives it.
    private var hostAppBundleIdentifier: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        guard let dot = id.lastIndex(of: ".") else { return id }
        return String(id[..<dot])
    }

    private var appGroupId: String {
        Bundle.main.object(forInfoDictionaryKey: kAppGroupIdKey) as? String ?? "group.\(hostAppBundleIdentifier)"
    }
}
