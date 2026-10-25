import SwiftUI

@main
struct ScreenRecorderApp: App {
    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(systemName: "record.circle")
        }
    }
}
