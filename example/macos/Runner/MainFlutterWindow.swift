import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController

    // Desktop sized: wide enough for the two column layouts, and never so
    // narrow that the controls collapse into a single cramped stack.
    self.title = "fontations example"
    self.minSize = NSSize(width: 640, height: 720)
    self.setFrame(
      NSRect(
        x: windowFrame.origin.x,
        y: windowFrame.origin.y,
        width: max(windowFrame.width, 1180),
        height: max(windowFrame.height, 820)),
      display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
