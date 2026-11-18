import SwiftUI

@main
struct RoadTripAssistApp: App {
    var body: some Scene {
        WindowGroup {
            TripPlannerView()
        }
        .defaultSize(width: 1320, height: 820)
    }
}
