//
//  DiscordTakeoverApp.swift
//  DiscordTakeover
//

import SwiftUI

@main
struct DiscordTakeoverApp: App {
    var body: some Scene {
        WindowGroup {
            HandoffView()
                .onOpenURL { url in
                    // Legacy mobile callback: discord-handoff://rpc?v=1&payload=...
                    if url.scheme == "discord-handoff" {
                        HandoffServer.shared.handleURLCallback(url)
                    }
                }
        }
    }
}
