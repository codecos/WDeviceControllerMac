import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let viewModel = MainViewModel()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(viewModel: viewModel)
        viewModel.start()

        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["WDC_SHOW_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.statusItemController?.show()
            }
        }
        if environment["WDC_OPEN_MENU"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.viewModel.openMenu()
            }
        }
        if environment["WDC_SELFTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.viewModel.userSetVolume(30)
                self?.viewModel.togglePlayPause()
            }
        }
        if let delay = Double(environment["WDC_DROP_AFTER"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.viewModel.debugDropConnectionForTesting()
            }
        }
        if let action = environment["WDC_MENU_TEST"], !action.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.viewModel.debugCycleMenuValue(action: action)
            }
        }
        if let source = environment["WDC_SOURCE"], !source.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
                self?.viewModel.setSource(source)
            }
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct WDeviceControllerApp {
    private static var appDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
