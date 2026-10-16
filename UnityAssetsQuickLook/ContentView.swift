//
//  ContentView.swift
//  UnityAssetsQuickLook
//
//  Created by Oliver Wong on 2026/4/23.
//

import SwiftUI
import AppKit
import os

struct ContentView: View {
    @State private var line1  = false
    @State private var line2  = false
    @State private var button = false
    
    var body: some View {
        VStack {
            Text("Hello, and welcome!")
                .opacity(line1 ? 1 : 0)
                .animation(.easeIn(duration: 0.5), value: line1)
            Text("You can close this app now.")
                .opacity(line2 ? 1 : 0)
                .animation(.easeIn(duration: 0.5), value: line2)
            Button("Quit App") { NSApp.terminate(nil) }
                .opacity(button ? 1 : 0)
                .animation(.easeIn(duration: 0.5), value: button)
        }
        .padding()
        .onAppear {
            line1 = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: { line2 = true })
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: { button = true })
        }
//        .frame(maxWidth: .infinity, maxHeight: .infinity)
//        .onGeometryChange(for: CGSize.self)
//        { proxy in proxy.size } action: { newValue in
//            print("[Content Area] \(newValue)")
//        }
    }
}

#Preview {
    ContentView()
}
