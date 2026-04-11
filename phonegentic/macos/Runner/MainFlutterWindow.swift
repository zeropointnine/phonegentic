import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var audioDeviceChannel: AudioDeviceChannel?
  private var audioTapChannel: AudioTapChannel?
  private var kokoroTtsChannel: KokoroTtsChannel?
  private var whisperKitChannel: WhisperKitChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 854, height: 480)
    self.setFrame(NSRect(x: self.frame.origin.x, y: self.frame.origin.y,
                         width: 1024, height: 576), display: true)

    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    audioDeviceChannel = AudioDeviceChannel(messenger: messenger)
    audioTapChannel = AudioTapChannel(messenger: messenger)
    kokoroTtsChannel = KokoroTtsChannel(messenger: messenger)
    whisperKitChannel = WhisperKitChannel(messenger: messenger)

    super.awakeFromNib()
  }

  override func close() {
    audioTapChannel?.cleanup()
    whisperKitChannel?.cleanup()
    super.close()
  }
}
