import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var audioDeviceChannel: AudioDeviceChannel?
  private var audioTapChannel: AudioTapChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    audioDeviceChannel = AudioDeviceChannel(messenger: messenger)
    audioTapChannel = AudioTapChannel(messenger: messenger)

    super.awakeFromNib()
  }

  override func close() {
    audioTapChannel?.cleanup()
    super.close()
  }
}
