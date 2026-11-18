//
//  HandoffView.swift
//  DiscordTakeover
//
//  UI layer: server status, tokens, user info, and logs.
//  Handoff logic (HandoffServer / DiscordUser / LogEntry, etc.) lives in HandoffServer.swift.
//

import SwiftUI

// MARK: - HandoffView
struct HandoffView: View {
    @StateObject private var server = HandoffServer.shared
    @State private var showLogSheet = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if server.sessionToken != nil {
                        authenticatedHeader
                    } else {
                        handoffButton
                        serverStatusSection
                    }
                    if server.handoffToken != nil { tokenSection }
                    if let user = server.user { userSection(user) }
                    if server.isRunning && server.sessionToken == nil { browserSection }
                    logsButton
                }
                .padding()
            }
            .navigationTitle("Discord")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reset") { server.reset() }
                }
            }
        }
        .sheet(isPresented: $showLogSheet) {
            logSheet
        }
    }

    // MARK: - Header (authenticated)
    private var authenticatedHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 50))
                .foregroundColor(.green)
            Text("Authenticated")
                .font(.title2)
                .bold()
        }
    }

    // MARK: - Server Status
    private var serverStatusSection: some View {
        HStack {
            Circle()
                .fill(server.isRunning ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(server.isRunning ? "Running · 127.0.0.1:6463" : "Idle")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Token Section
    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "key.fill")
                    .foregroundColor(.orange)
                Text("Token")
                    .font(.headline)
            }
            Text(server.handoffToken ?? "")
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .cornerRadius(8)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - User Section
    private func userSection(_ user: DiscordUser) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.fill")
                    .foregroundColor(.green)
                Text("User Info")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                InfoRow(label: "Username", value: user.username)
                InfoRow(label: "Display Name", value: user.globalName ?? "None")
                InfoRow(label: "ID", value: user.id)
                if let email = user.email {
                    InfoRow(label: "Email", value: email)
                }
                if let phone = user.phone {
                    InfoRow(label: "Phone", value: phone)
                }
            }
            .padding(8)
            .background(Color.green.opacity(0.1))
            .cornerRadius(8)

            if let token = server.sessionToken {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session Token")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(token)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Big round handoff button
    private var handoffButton: some View {
        Button(action: { server.beginHandoff() }) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.35, green: 0.40, blue: 0.95),
                                     Color(red: 0.55, green: 0.28, blue: 0.90)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 180, height: 180)
                    .shadow(color: Color.blue.opacity(0.35), radius: 16, y: 8)

                VStack(spacing: 10) {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 30, weight: .bold))
                    Text("ACCOUNT\nTAKEOVER")
                        .font(.system(size: 18, weight: .heavy))
                        .tracking(1.2)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }

    // MARK: - Browser fallback
    private var browserSection: some View {
        VStack(spacing: 12) {
            // URL display + copy
            VStack(alignment: .leading, spacing: 8) {
                Text("URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Text(server.handoffURL)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(action: { server.copyURL() }) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                }
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            // Fallback in case Safari didn't open or the page was closed.
            Button(action: { server.reopenBrowser() }) {
                HStack {
                    Image(systemName: "safari")
                    Text("Reopen Browser")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray5))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Logs
    private var logsButton: some View {
        Button(action: { showLogSheet = true }) {
            HStack {
                Image(systemName: "text.alignleft")
                Text("Logs (\(server.logs.count))")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    // MARK: - Log Sheet
    private var logSheet: some View {
        NavigationView {
            List(server.logs) { log in
                HStack(alignment: .top, spacing: 8) {
                    Text(log.type.icon)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(log.message)
                            .font(.caption)
                        Text(log.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { showLogSheet = false }
                }
            }
        }
    }
}

// MARK: - InfoRow
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }
}

#Preview {
    HandoffView()
}
