import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ImageSharePlugin") {
      ImageSharePlugin.register(with: registrar)
    }
  }
}

// Shares photos the way the Photos app does: one item provider per photo that
// registers only its image type (public.jpeg etc.) and yields a file URL.
// Any extra public.file-url type makes LINE post each photo as its own message
// instead of grouping them into an album.
final class ImageSharePlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "zipphoto/share", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ImageSharePlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "shareImages",
          let args = call.arguments as? [String: Any],
          let paths = args["paths"] as? [String] else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let presenter = Self.topViewController() else {
      result(FlutterError(code: "no_view", message: "No view controller to present from", details: nil))
      return
    }

    let providers = paths.map { Self.imageProvider(for: URL(fileURLWithPath: $0)) }
    let configuration = UIActivityItemsConfiguration(itemProviders: providers)
    configuration.previewProvider = { index, _, _ in
      guard index < paths.count, let image = UIImage(contentsOfFile: paths[index]) else { return nil }
      return NSItemProvider(object: image)
    }
    let sheet = UIActivityViewController(activityItemsConfiguration: configuration)
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = presenter.view
      if let x = args["x"] as? Double, let y = args["y"] as? Double,
         let w = args["w"] as? Double, let h = args["h"] as? Double {
        popover.sourceRect = CGRect(x: x, y: y, width: w, height: h)
      } else {
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
      }
    }
    sheet.completionWithItemsHandler = { _, completed, _, error in
      if let error = error {
        result(FlutterError(code: "share_failed", message: error.localizedDescription, details: nil))
      } else {
        result(completed)
      }
    }
    presenter.present(sheet, animated: true)
  }

  private static func imageProvider(for url: URL) -> NSItemProvider {
    let type = UTType(filenameExtension: url.pathExtension) ?? .jpeg
    let provider = NSItemProvider()
    provider.suggestedName = url.deletingPathExtension().lastPathComponent
    // registerItem (not registerFileRepresentation): the receiver gets this readable
    // URL, whereas a file representation hands extensions a temp copy they can't open.
    provider.registerItem(forTypeIdentifier: type.identifier) { completion, _, _ in
      completion?(url as NSURL, nil)
    }
    return provider
  }

  private static func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}
