//
//  MidiControllerApp.swift
//  MidiController
//
//  Created by Manfred on 20/02/2026.
//

import SwiftUI

@main
struct MidiControllerApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        .commands {
            CommandMenu("Koppeling") {
                Button("Verwijder koppeling") {
                    viewModel.removeLinkForSelectedCell()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!viewModel.isLearnEnabled || !viewModel.canRemoveLinkForSelectedCell)
            }
        }
    }
}
