//
//  ContentView.swift
//  iResignX
//
//  Created by Praveen on 01/03/25.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Resign Stage

/// Tracks each step of the pipeline for granular progress display.
enum ResignStage: String, CaseIterable {
    case idle         = "Awaiting input"
    case unpacking    = "Unpacking IPA"
    case entitlements = "Extracting entitlements"
    case preparing    = "Preparing bundle"
    case signing      = "Signing"
    case repacking    = "Repacking IPA"
    case done         = "Done"
    case failed       = "Failed"
}

// MARK: - ContentView

struct ContentView: View {

    // File selections
    @State private var ipaURL: URL?
    @State private var profileURL: URL?

    // Signing identity selection
    @State private var availableIdentities: [String] = []
    @State private var selectedIdentity: String = ""

    // Progress & result
    @State private var stage: ResignStage = .idle
    @State private var statusMessage: String = ""
    @State private var isProcessing = false

    // Drag-over highlight states
    @State private var ipaDropTargeted = false
    @State private var profileDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    fileDropRow(
                        label: "IPA File",
                        icon: "cube.box.fill",
                        url: ipaURL,
                        dropTargeted: $ipaDropTargeted,
                        acceptedExtension: "ipa",
                        onClear: { ipaURL = nil },
                        onBrowse: { ipaURL = selectFile(ofTypes: ["ipa"]) },
                        onDrop: { ipaURL = $0 }
                    )

                    fileDropRow(
                        label: "Provisioning Profile",
                        icon: "person.badge.key.fill",
                        url: profileURL,
                        dropTargeted: $profileDropTargeted,
                        acceptedExtension: "mobileprovision",
                        onClear: { profileURL = nil },
                        onBrowse: { profileURL = selectFile(ofTypes: ["mobileprovision"]) },
                        onDrop: { profileURL = $0 }
                    )

                    identityPickerView

                    resignButton

                    if isProcessing {
                        progressView
                    }

                    if !statusMessage.isEmpty && !isProcessing {
                        statusView
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 540)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { loadIdentities() }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.and.scribble")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("iResignX")
                .font(.title2.bold())
            Spacer()
            Button {
                loadIdentities()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Refresh signing identities")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - File Drop Row

    private func fileDropRow(
        label: String,
        icon: String,
        url: URL?,
        dropTargeted: Binding<Bool>,
        acceptedExtension: String,
        onClear: @escaping () -> Void,
        onBrowse: @escaping () -> Void,
        onDrop: @escaping (URL) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(url != nil ? .accentColor : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(url?.lastPathComponent ?? "Drag & drop or click Browse")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(url != nil ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if url != nil {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }

            Button("Browse") { onBrowse() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isProcessing)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    dropTargeted.wrappedValue
                        ? Color.accentColor
                        : (url != nil ? Color.accentColor.opacity(0.5) : Color(NSColor.separatorColor)),
                    style: StrokeStyle(
                        lineWidth: dropTargeted.wrappedValue ? 2 : 1,
                        dash: url == nil && !dropTargeted.wrappedValue ? [6, 3] : []
                    )
                )
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(dropTargeted.wrappedValue
                              ? Color.accentColor.opacity(0.06)
                              : Color(NSColor.controlBackgroundColor))
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { if !isProcessing { onBrowse() } }
        .onDrop(of: [.fileURL], isTargeted: dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension == acceptedExtension else { return }
                DispatchQueue.main.async { onDrop(url) }
            }
            return true
        }
        .animation(.easeInOut(duration: 0.15), value: dropTargeted.wrappedValue)
    }

    // MARK: - Identity Picker

    private var identityPickerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.title3)
                .foregroundColor(selectedIdentity.isEmpty ? .secondary : .accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Signing Identity")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if availableIdentities.isEmpty {
                    Text("No valid signing identities found — check Keychain")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.red)
                } else {
                    Picker("", selection: $selectedIdentity) {
                        ForEach(availableIdentities, id: \.self) { identity in
                            Text(identity).tag(identity)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                )
        )
    }

    // MARK: - Resign Button

    private var resignButton: some View {
        Button {
            startResign()
        } label: {
            HStack {
                Image(systemName: "signature")
                Text("Resign IPA")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isProcessing || ipaURL == nil || profileURL == nil || selectedIdentity.isEmpty)
    }

    // MARK: - Progress View

    private var progressView: some View {
        let steps: [(ResignStage, String)] = [
            (.unpacking,    "Unpacking IPA"),
            (.entitlements, "Extracting entitlements"),
            (.preparing,    "Preparing bundle"),
            (.signing,      "Signing"),
            (.repacking,    "Repacking IPA"),
        ]
        let stageOrder: [ResignStage] = steps.map { $0.0 }
        let currentIdx = stageOrder.firstIndex(of: stage) ?? -1

        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                HStack(spacing: 10) {
                    if idx < currentIdx {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else if idx == currentIdx {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "circle")
                            .foregroundColor(.secondary)
                    }
                    Text(step.1)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(
                            idx < currentIdx  ? .green    :
                            idx == currentIdx ? .primary  : .secondary
                        )
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                )
        )
    }

    // MARK: - Status Banner

    private var statusView: some View {
        let isSuccess = stage == .done
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSuccess ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(isSuccess ? .green : .red)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(isSuccess ? "Resigned successfully" : "Resign failed")
                    .font(.callout.bold())
                    .foregroundColor(isSuccess ? .green : .red)
                Text(statusMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(5)
            }

            Spacer()

            if isSuccess {
                // Extract the saved file path from the success message
                let savedPath = statusMessage
                    .components(separatedBy: "\n")
                    .last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(savedPath, inFileViewerRootedAtPath: "")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSuccess ? Color.green.opacity(0.07) : Color.red.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSuccess ? Color.green.opacity(0.3) : Color.red.opacity(0.3),
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Actions

    private func loadIdentities() {
        DispatchQueue.global(qos: .userInitiated).async {
            let identities = IPAResigner.fetchSigningIdentities()
            DispatchQueue.main.async {
                availableIdentities = identities
                if selectedIdentity.isEmpty || !identities.contains(selectedIdentity) {
                    selectedIdentity = identities.first ?? ""
                }
            }
        }
    }

    private func startResign() {
        guard let ipa = ipaURL, let profile = profileURL else { return }
        guard !selectedIdentity.isEmpty else { return }

        isProcessing  = true
        stage         = .unpacking
        statusMessage = ""

        let ipaPath     = ipa.path
        let profilePath = profile.path
        let identity    = selectedIdentity

        Task.detached(priority: .userInitiated) {
            let result = await IPAResigner.resign(
                ipaURL:     URL(fileURLWithPath: ipaPath),
                profileURL: URL(fileURLWithPath: profilePath),
                identity:   identity,
                onStage: { newStage in
                    await MainActor.run { stage = newStage }
                }
            )
            await MainActor.run {
                isProcessing  = false
                statusMessage = result.message
                stage         = result.success ? .done : .failed
            }
        }
    }

    // MARK: - File picker

    private func selectFile(ofTypes types: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes  = types.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles       = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
