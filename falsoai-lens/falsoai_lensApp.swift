//
//  falsoai_lensApp.swift
//  falsoai-lens
//
//  Created by Carlos Garcia on 24/04/26.
//

import AppKit
import SwiftUI
import SwiftData

@main
struct falsoai_lensApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .commands {
            CommandMenu("Falsoai Lens") {
                Button("Open Scanner") {
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}
