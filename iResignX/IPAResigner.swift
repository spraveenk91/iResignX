//
//  IPAResigner.swift
//  iResignX
//
//  Created by Praveenkumar S on 04/06/25.
//

import Foundation
import UniformTypeIdentifiers
import AppKit

enum IPAResignerError: Error, LocalizedError {
    case appBundleNotFound
    case infoPlistUnreadable
    case provisioningProfileUnreadable
    case entitlementsNotFound
    case identityNotFound
    case saveCancelled
    case commandFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .appBundleNotFound:
            return "No .app bundle found inside Payload directory."
        case .infoPlistUnreadable:
            return "Could not read Info.plist from the app bundle."
        case .provisioningProfileUnreadable:
            return "Could not decode the provisioning profile. Make sure it is a valid .mobileprovision file."
        case .entitlementsNotFound:
            return "No Entitlements key found in the provisioning profile."
        case .identityNotFound:
            return "No valid iPhone / Apple Distribution signing identity found in your Keychain."
        case .saveCancelled:
            return "Save cancelled by user."
        case .commandFailed(let output, let code):
            return "Command exited with code \(code):\n\(output)"
        }
    }
}

enum IPAResigner {

    static func resign(ipaURL: URL, profileURL: URL) -> String {
        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iResignX_\(UUID().uuidString)")
        let payloadPath = tempDir.appendingPathComponent("Payload")

        do {
            // ── Step 1: Unzip IPA into temp dir ──────────────────────────────────
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try runOrThrow("unzip -q \(q(ipaURL.path)) -d \(q(tempDir.path))")

            // ── Step 2: Locate .app bundle ────────────────────────────────────────
            guard let appPath = try fileManager
                .contentsOfDirectory(at: payloadPath, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
            else { throw IPAResignerError.appBundleNotFound }

            // ── Step 3: Read version & build natively (no PlistBuddy) ────────────
            // The sandbox blocks spawning /usr/libexec/PlistBuddy.
            // Use PropertyListSerialization instead — no subprocess needed.
            let (version, build) = try readVersionAndBuild(from: appPath)

            // ── Step 4: Extract entitlements natively (no PlistBuddy / security) ─
            // provisioning profiles are CMS-enveloped plists. Strip the CMS wrapper
            // by scanning for the embedded XML plist payload directly in the raw bytes.
            let entitlementsURL = try extractEntitlements(from: profileURL, into: tempDir)

            // ── Step 5: Prepare bundle for re-signing ─────────────────────────────
            let codeSigDir = appPath.appendingPathComponent("_CodeSignature")
            if fileManager.fileExists(atPath: codeSigDir.path) {
                try fileManager.removeItem(at: codeSigDir)
            }

            // Remove existing embedded.mobileprovision before copying —
            // copyItem(at:to:) throws if the destination already exists.
            let embeddedProfileDest = appPath.appendingPathComponent("embedded.mobileprovision")
            if fileManager.fileExists(atPath: embeddedProfileDest.path) {
                try fileManager.removeItem(at: embeddedProfileDest)
            }
            try fileManager.copyItem(at: profileURL, to: embeddedProfileDest)

            // ── Step 6: Resolve signing identity ─────────────────────────────────
            // `security find-identity` is allowed in sandbox (reads Keychain only).
            let identity = try resolveSigningIdentity()

            // ── Step 7: Re-sign frameworks, plugins, then the .app itself ─────────
            for subDir in ["Frameworks", "PlugIns"] {
                let container = appPath.appendingPathComponent(subDir)
                guard fileManager.fileExists(atPath: container.path) else { continue }
                let items = try fileManager.contentsOfDirectory(at: container,
                                                                includingPropertiesForKeys: nil)
                for item in items {
                    try runOrThrow(
                        "/usr/bin/codesign -f -s \(q(identity)) --entitlements \(q(entitlementsURL.path)) \(q(item.path))"
                    )
                }
            }
            try runOrThrow(
                "/usr/bin/codesign -f -s \(q(identity)) --entitlements \(q(entitlementsURL.path)) \(q(appPath.path))"
            )

            // ── Step 8: Ask user where to save ───────────────────────────────────
            let appName    = ipaURL.deletingPathExtension().lastPathComponent
            let outputName = "\(appName)_\(version)_\(build)_Resigned.ipa"
            guard let saveURL = promptSaveLocation(defaultName: outputName) else {
                throw IPAResignerError.saveCancelled
            }

            // Zip entirely within NSTemporaryDirectory (always writable by the app).
            // The zip subprocess does NOT inherit the NSSavePanel sandbox permission,
            // so zipping directly to the user-chosen path fails with exit code 10.
            // Instead: zip to temp, then move via FileManager (which honours the grant).
            let packedURL = tempDir.appendingPathComponent(outputName)
            try runOrThrow("zip -qr \(q(packedURL.path)) Payload", workingDirectory: tempDir)

            // Move finished IPA to user-chosen location (FileManager is sandbox-safe)
            if fileManager.fileExists(atPath: saveURL.path) {
                try fileManager.removeItem(at: saveURL)
            }
            try fileManager.moveItem(at: packedURL, to: saveURL)

            // ── Step 10: Cleanup ─────────────────────────────────────────────────
            try? fileManager.removeItem(at: tempDir)

            return "✅ Success! Resigned IPA saved to:\n\(saveURL.path)"

        } catch {
            try? fileManager.removeItem(at: tempDir)
            return "❌ Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Native plist reading (replaces PlistBuddy)
    /// Reads CFBundleShortVersionString and CFBundleVersion from Info.plist
    /// using PropertyListSerialization — no subprocess, sandbox-safe.
    private static func readVersionAndBuild(from appPath: URL) throws -> (version: String, build: String) {
        let plistURL = appPath.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)

        guard
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw IPAResignerError.infoPlistUnreadable }

        let version = (plist["CFBundleShortVersionString"] as? String) ?? "0.0"
        let build   = (plist["CFBundleVersion"]            as? String) ?? "0"
        return (version, build)
    }

    // MARK: - Native entitlements extraction (replaces security cms + PlistBuddy)
    /// Provisioning profiles are CMS (PKCS#7) signed blobs that contain an
    /// embedded XML plist.  We don't need to verify the signature here — we just
    /// need the plist payload, so we scan the raw bytes for the XML header and
    /// trailer and slice it out.  This is sandbox-safe and requires no subprocess.
    private static func extractEntitlements(from profileURL: URL, into tempDir: URL) throws -> URL {
        let raw = try Data(contentsOf: profileURL)

        // The embedded plist always starts with "<?xml" and ends with "</plist>"
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

        // Serialise entitlements back to an XML plist file for codesign --entitlements
        let entData = try PropertyListSerialization.data(
            fromPropertyList: entitlementsDict,
            format: .xml,
            options: 0
        )
        let entURL = tempDir.appendingPathComponent("entitlements.plist")
        try entData.write(to: entURL)
        return entURL
    }

    // MARK: - Signing identity resolution
    private static func resolveSigningIdentity() throws -> String {
        // `security find-identity` only reads the Keychain — allowed in sandbox.
        let output = try runOrThrow("security find-identity -v -p codesigning")
        let identity = output
            .components(separatedBy: "\n")
            .first(where: { $0.contains("iPhone") || $0.contains("Apple Distribution") })?
            .components(separatedBy: "\"")
            .dropFirst()
            .first ?? ""

        guard !identity.isEmpty else { throw IPAResignerError.identityNotFound }
        return identity
    }

    // MARK: - Shell helper
    /// Wraps a path in single-quotes, escaping any embedded single-quotes.
    private static func q(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Runs a shell command via zsh, throws a typed error if the exit code ≠ 0.
    @discardableResult
    private static func runOrThrow(_ command: String, workingDirectory: URL? = nil) throws -> String {
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

    // MARK: - Save panel
    private static func promptSaveLocation(defaultName: String) -> URL? {
        var selectedURL: URL?
        let block = {
            let panel = NSSavePanel()
            panel.title                = "Save Resigned IPA"
            panel.nameFieldStringValue = defaultName
            if #available(macOS 11.0, *) {
                panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
            } else {
                panel.allowedFileTypes = ["ipa"]
            }
            if panel.runModal() == .OK { selectedURL = panel.url }
        }

        Thread.isMainThread ? block() : DispatchQueue.main.sync { block() }
        return selectedURL
    }
}
