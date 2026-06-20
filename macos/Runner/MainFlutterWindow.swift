import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Single, integrated title bar (VSCode-style): hide the native title
    // bar and extend the Flutter content to the top edge. The traffic-light
    // buttons float over the studio's own titlebar, which insets its left
    // edge on macOS to clear them.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = true

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "vibe_studio/native_picker",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "pickFileOrPackage":
        let args = call.arguments as? [String: Any] ?? [:]
        let exts = (args["extensions"] as? [String]) ?? []
        let title = (args["title"] as? String) ?? "Select"
        let initialDir = args["initialDirectory"] as? String
        let panel = NSOpenPanel()
        panel.message = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if !exts.isEmpty {
          panel.allowedFileTypes = exts
        }
        if let dir = initialDir, FileManager.default.fileExists(atPath: dir) {
          // `isDirectory: true` + symlink resolve + standardized path so
          // NSOpenPanel doesn't fall back to its persisted
          // NSNavLastRootDirectory state. Without this the chooser
          // sticks to the last directory the user clicked, ignoring
          // the dart-side workspaceDir we send through.
          let resolved = URL(fileURLWithPath: dir, isDirectory: true)
              .resolvingSymlinksInPath()
              .standardizedFileURL
          panel.directoryURL = resolved
          NSLog("vibe_studio picker: directoryURL=\(resolved.path)")
        }
        panel.begin { response in
          if response == .OK, let url = panel.url {
            let path = url.path
            let ext = (path as NSString).pathExtension.lowercased()
            if exts.isEmpty || exts.contains(ext) {
              result(path)
            } else {
              result(nil)
            }
          } else {
            result(nil)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
