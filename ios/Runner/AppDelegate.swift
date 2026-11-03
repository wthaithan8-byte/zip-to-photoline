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

// Shares photos as typed image data (like the Photos app) instead of file URLs,
// so chat apps such as LINE treat them as a photo batch rather than files.
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

    let items = paths.map { ImageItemSource(url: URL(fileURLWithPath: $0)) }
    let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
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

final class ImageItemSource: NSObject, UIActivityItemSource {
  private let url: URL
  private let typeIdentifier: String

  init(url: URL) {
    self.url = url
    self.typeIdentifier = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.jpeg.identifier
  }

  func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
    UIImage(contentsOfFile: url.path) ?? UIImage()
  }

  func activityViewController(_ activityViewController: UIActivityViewController,
                              itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
    try? Data(contentsOf: url)
  }

  func activityViewController(_ activityViewController: UIActivityViewController,
                              dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
    typeIdentifier
  }
}
