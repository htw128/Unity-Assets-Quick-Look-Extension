//
//  UnityAssetsQuickLookApp.swift
//  UnityAssetsQuickLook
//
//  Created by Oliver Wong on 2026/4/23.
//

import SwiftUI

@main
struct UnityAssetsQuickLookApp: App {
    var body: some Scene {
        Window("Unity Assets Quick Look", id: "main") {
            ContentView()
                .frame(width: 270, height: 150)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
