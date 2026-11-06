import SwiftUI
import TVPairCore

@main
struct TVPairApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).preferredColorScheme(.dark)
                .task { await model.loadRecords() }
        }
    }
}
