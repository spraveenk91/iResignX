//
//  ContentView.swift
//  iResignX
//
//  Created by Praveen on 01/03/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var ipaURL: URL?
    @State private var profileURL: URL?
    @State private var status: String = "Awaiting input..."
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: 20) {
            Text("🔧 iResignX")
                .font(.largeTitle)
                .padding(.top, 20)

            Button("Select .ipa File") {
                ipaURL = selectFile(ofTypes: ["ipa"])
            }
            .disabled(isProcessing)

            Text(ipaURL?.lastPathComponent ?? "No .ipa file selected")
                .font(.caption)
                .foregroundColor(.gray)

            Button("Select Provisioning Profile") {
                profileURL = selectFile(ofTypes: ["mobileprovision"])
            }
            .disabled(isProcessing)

            Text(profileURL?.lastPathComponent ?? "No profile selected")
                .font(.caption)
                .foregroundColor(.gray)

            Button("Resign IPA") {
                guard let ipa = ipaURL, let profile = profileURL else {
                    status = "❗ Please select both files."
                    return
                }

                isProcessing = true
                status = "🔄 Resigning in progress..."

                // FIX: Pass security-scoped URLs' path before hopping to background.
                //      NSOpenPanel already grants access; capture the paths here on
                //      the main thread so the background thread can use them safely.
                let ipaPath     = ipa.path
                let profilePath = profile.path

                DispatchQueue.global(qos: .userInitiated).async {
                    let ipaURL_bg     = URL(fileURLWithPath: ipaPath)
                    let profileURL_bg = URL(fileURLWithPath: profilePath)
                    let result = IPAResigner.resign(ipaURL: ipaURL_bg, profileURL: profileURL_bg)
                    DispatchQueue.main.async {
                        isProcessing = false
                        status = result
                    }
                }
            }
            .disabled(isProcessing || ipaURL == nil || profileURL == nil)
            .padding(.top)

            if isProcessing {
                ProgressView("Processing...")
                    .progressViewStyle(CircularProgressViewStyle())
                    .padding(.top)
            }

            // FIX: Status colour logic was wrong — red was shown for success too
            //      if the message didn't contain ✅ (e.g. cancelled message).
            Text(status)
                .font(.caption)
                .foregroundColor(statusColor)
                .padding(.top, 10)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
        .frame(width: 420, height: 420)
    }

    // MARK: - Helpers
    private var statusColor: Color {
        if status.contains("✅") { return .green }
        if status.contains("❌") { return .red }
        return .secondary
    }

    func selectFile(ofTypes types: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // FIX: canChooseFiles defaults to true but being explicit avoids surprises.
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
