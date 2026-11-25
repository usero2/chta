import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    if let supportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first {
      setenv("CHTA_MAC_DATA_HOME", supportDirectory.path, 1)
    }
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
