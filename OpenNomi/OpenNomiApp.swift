//
//  OpenNomiApp.swift
//  OpenNomi
//
//  Created by Kerwin Young on 2026/3/17.
//

import SwiftUI

@main
struct OpenNomiApp: App {
    var body: some Scene {
        WindowGroup {
            NomiExpressionView()
                .preferredColorScheme(.dark)
                .onAppear {
                    WatchSyncManager.shared.activate()
                    WatchSyncManager.shared.syncCurrentSettingsFromStorage()
                }
        }
    }
}
