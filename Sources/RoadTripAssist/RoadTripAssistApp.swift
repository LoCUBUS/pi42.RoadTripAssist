import AppKit
import SwiftUI

@main
struct RoadTripAssistApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: RoadTripAssistAppDelegate

    var body: some Scene {
        Window("RoadTripAssist", id: "planner") {
            TripPlannerView()
        }

        .defaultSize(width: 1320, height: 820)
    }
}

private final class RoadTripAssistAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard NSApp.activationPolicy() != .regular else { return }
        if !NSApp.setActivationPolicy(.regular) {
            NSLog("RoadTripAssist could not register as a foreground application.")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }
}
