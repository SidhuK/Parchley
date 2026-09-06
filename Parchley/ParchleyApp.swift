//
//  ParchleyApp.swift
//  Parchley
//
//  Created by Karat Sidhu on 06/09/26.
//

import SwiftUI
import CoreData

@main
struct ParchleyApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
