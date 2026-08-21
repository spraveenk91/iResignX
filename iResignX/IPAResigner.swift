//
//  IPAResigner.swift
//  iResignX
//
//  Created by Praveenkumar S on 04/06/25.
//

import Foundation
import UniformTypeIdentifiers
import AppKit

// MARK: - Result type

struct ResignResult {
    let success: Bool
    let message: String
}

// MARK: - Errors

enum IPAResignerError: Error, LocalizedError {
    case appBundleNotFound
    case infoPlistUnreadable
    case provisioningProfileUnreadable
    case entitlementsNotFound
    case noIdentityProvided
    case saveCancelled
    case commandFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .appBundleNotFound:
            return "No .app bundle found inside the Payload directory."
        case .infoPlistUnreadable:
            return "Could not read Info.plist from the app bundle."
        case .provisioningProfileUnreadable:
            return "Could not decode the provisioning profile. Make sure it is a valid .mobileprovision file."
        case .entitlementsNotFound:
            return "No Entitlements key found in the provisioning profile."
        case .noIdentityProvided:
            return "No signing identity was provided."
        case .saveCancelled:
            return "Save cancelled by user."
        case .commandFailed(let output, let code):
            return "Command exited with code \(code):\n\(output)"
        }
    }
}

// MARK: - IPAResigner

enum IPAResigner {

    // MARK: Public API

    /// Resigns an IPA with the given provisioning profile and signing identity.
    /// Reports stage progress via `onStage` callback (called from background thread).
    static func resign(
        ipaURL: URL,
        profileURL: URL,
        identity: String,
        onStage: @escaping (ResignStage) async -> Void
    ) async -> ResignResult {
        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iResignX_\(UUID().uuidString)")
        let payloadPath = tempDir.appendingPathComponent("Payload")

        do {
            guard !identity.isEmpty else { throw IPAResignerError.noIdentityProvided }

            // ── Step 1: Unzip ─────────────────────────────────────────────────────
            await onStage(.unpacking)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try runOrThrow("unzip -q \(q(ipaURL.path)) -d \(q(tempDir.path))")

            // ── Step 2: Locate .app bundle ────────────────────────────────────────
            guard let appPath = try fileManager
                .contentsOfDirectory(at: payloadPath, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
            else { throw IPAResignerError.appBundleNotFound }

            // ── Step 3: Read version & build natively ─────────────────────────────
            let (version, build) = try readVersionAndBuild(from: appPath)

            // ── Step 4: Extract entitlements natively ─────────────────────────────
            await onStage(.entitlements)
            let entitlementsURL = try extractEntitlements(from: profileURL, into: tempDir)

            // ── Step 5: Prepare bundle ────────────────────────────────────────────
            await onStage(.preparing)
            let codeSigDir = appPath.appendingPathComponent("_CodeSignature")
            if fileManager.fileExists(atPath: codeSigDir.path) {
                try fileManager.removeItem(at: codeSigDir)
            }

            let embeddedProfileDest = appPath.appendingPathComponent("embedded.mobileprovision")
            if fileManager.fileExists(atPath: embeddedProfileDest.path) {
                try fileManager.removeItem(at: embeddedProfileDest)
            }
            try fileManager.copyItem(at: profileURL, to: embeddedProfileDest)

            // ── Step 6: Re-sign frameworks, plugins, then the .app ────────────────
            await onStage(.signing)
            for subDir in ["Frameworks", "PlugIns"] {
                let container = appPath.appendingPathComponent(subDir)
                guard fileManager.fileExists(atPath: container.path) else { continue }
                let items = (try? fileManager.contentsOfDirectory(
                    at: container, includingPropertiesForKeys: nil)) ?? []
                for item in items {
                    try runOrThrow(
                        "/usr/bin/codesign -f -s \(q(identity)) --entitlements \(q(entitlementsURL.path)) \(q(item.path))"
                    )
                }
            }
            try runOrThrow(
                "/usr/bin/codesign -f -s \(q(identity)) --entitlements \(q(entitlementsURL.path)) \(q(appPath.path))"
            )

            // ── Step 7: Ask user where to save (main thread) ──────────────────────
            let appName    = ipaURL.deletingPathExtension().lastPathComponent
            let outputName = "\(appName)_\(version)_\(build)_Resigned.ipa"
            guard let saveURL = await promptSaveLocation(defaultName: outputName) else {
                throw IPAResignerError.saveCancelled
            }

            // ── Step 8: Repack into temp dir first, then move ─────────────────────
            await onStage(.repacking)
            let packedURL = tempDir.appendingPathComponent(outputName)
            try runOrThrow("zip -qr \(q(packedURL.path)) Payload", workingDirectory: tempDir)

            // FileManager.moveItem honours the NSSavePanel sandbox grant;
            // subprocess zip does not — so we always zip to temp then move.
            if fileManager.fileExists(atPath: saveURL.path) {
                try fileManager.removeItem(at: saveURL)
            }
            try fileManager.moveItem(at: packedURL, to: saveURL)

            // ── Cleanup ───────────────────────────────────────────────────────────
            try? fileManager.removeItem(at: tempDir)

            return ResignResult(
                success: true,
                message: "Resigned IPA saved to:\n\(saveURL.path)"
            )

        } catch {
            try? fileManager.removeItem(at: tempDir)
            return ResignResult(success: false, message: error.localizedDescription)
        }
    }

    // MARK: - Fetch signing identities (used by UI picker)

    /// Returns all valid iPhone / Apple Distribution identities from the Keychain.
    static func fetchSigningIdentities() -> [String] {
        guard
            let output = try? runOrThrow("security find-identity -v -p codesigning")
        else { return [] }

        return output
            .components(separatedBy: "\n")
            .filter {
                $0.contains("iPhone")
                || $0.contains("Apple Development")
                || $0.contains("Apple Distribution")
            }
            .compactMap { line -> String? in
                let parts = line.components(separatedBy: "\"")
                guard parts.count >= 2 else { return nil }
                let name = parts[1]
                return name.isEmpty ? nil : name
            }
            // Remove duplicates (e.g. same cert in multiple keychains)
            .reduce(into: [String]()) { result, identity in
                if !result.contains(identity) { result.append(identity) }
            }
    }

    // MARK: - Private helpers

    /// Reads CFBundleShortVersionString and CFBundleVersion from Info.plist natively.
    private static func readVersionAndBuild(from appPath: URL) throws -> (version: String, build: String) {
        let plistURL = appPath.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: Any]
        else { throw IPAResignerError.infoPlistUnreadable }

        let version = (plist["CFBundleShortVersionString"] as? String) ?? "0.0"
        let build   = (plist["CFBundleVersion"]            as? String) ?? "0"
        return (version, build)
    }

    /// Extracts the Entitlements dict from a .mobileprovision by scanning for
    /// the embedded XML plist — no subprocess needed, fully sandbox-safe.
    private static func extractEntitlements(from profileURL: URL, into tempDir: URL) throws -> URL {
        let raw = try Data(contentsOf: profileURL)

        guard
            let xmlStart = raw.range(of: Data("<?xml".utf8)),
            let xmlEnd   = raw.range(of: Data("</plist>".utf8))
        else { throw IPAResignerError.provisioningProfileUnreadable }

        let plistData = raw[xmlStart.lowerBound ... xmlEnd.upperBound - 1]

        guard
            let profile = try PropertyListSerialization
                .propertyList(from: plistData, format: nil) as? [String: Any],
            let entitlementsDict = profile["Entitlements"] as? [String: Any]
        else { throw IPAResignerError.entitlementsNotFound }

        let entData = try PropertyListSerialization.data(
            fromPropertyList: entitlementsDict,
            format: .xml,
            options: 0
        )
        let entURL = tempDir.appendingPathComponent("entitlements.plist")
        try entData.write(to: entURL)
        return entURL
    }

    /// Wraps a path in single-quotes, escaping embedded single-quotes.
    private static func q(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Runs a shell command; throws a typed error if exit code ≠ 0.
    @discardableResult
    static func runOrThrow(_ command: String, workingDirectory: URL? = nil) throws -> String {
        let task    = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        task.executableURL  = URL(fileURLWithPath: "/bin/zsh")
        task.arguments      = ["-c", command]
        task.standardOutput = outPipe
        task.standardError  = errPipe

        if let wd = workingDirectory {
            task.currentDirectoryURL = wd
        }

        try task.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let output = [outData, errData]
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined()

        guard task.terminationStatus == 0 else {
            throw IPAResignerError.commandFailed(output, task.terminationStatus)
        }
        return output
    }

    // MARK: - Save panel (async, main-thread safe)

    @MainActor
    private static func promptSaveLocation(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title                = "Save Resigned IPA"
        panel.nameFieldStringValue = defaultName
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        } else {
            panel.allowedFileTypes = ["ipa"]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
