//
//  PersonalStylistApp.swift
//  PersonalStylist
//
//  Created by Niral Shah on 10/25/26.
//

import SwiftUI

@main
struct PersonalStylistApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
        }
    }
}
