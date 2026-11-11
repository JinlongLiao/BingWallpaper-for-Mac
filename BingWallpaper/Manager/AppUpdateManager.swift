//
//  AppUpdateManager.swift
//  BingWallpaper
//
//  Created by Laurenz Lazarus on 11.12.22.
//

import Foundation
import AppKit
import CryptoKit
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.AppUpdate.rawValue
)

class AppUpdateManager {

    private enum UpdateError: LocalizedError {
        case invalidRepository
        case missingInstallerAssets(String)
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .invalidRepository:
                return "The configured GitHub release repository is invalid."
            case .missingInstallerAssets(let version):
                return "Release \(version) does not include a signed installer and its SHA-256 checksum."
            case .checksumMismatch(let assetName):
                return "The downloaded checksum for \(assetName) did not match."
            }
        }
    }

    /// 未配置有效仓库时，从原版项目的 GitHub Releases 检查更新。
    private static let defaultReleaseRepository = "2h4u/BingWallpaper-for-Mac"

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadUrl: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    static func currentAppVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func releaseRepository(bundle: Bundle = .main) -> String {
        guard let repository = bundle.object(forInfoDictionaryKey: "BingWallpaperReleaseRepository") as? String,
              isValidReleaseRepository(repository) else {
            return defaultReleaseRepository
        }
        return repository
    }

    static func latestReleaseAPIURL(repository: String) -> URL? {
        guard isValidReleaseRepository(repository) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repository)/releases/latest"
        return components.url
    }

    private static func isValidReleaseRepository(_ repository: String) -> Bool {
        let components = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return components.allSatisfy { component in
            component.isEmpty == false &&
                component.allSatisfy { character in
                    character.isASCII &&
                        (character.isLetter || character.isNumber || "_.-".contains(character))
                } &&
                component.contains(where: { $0 != "." })
        }
    }

    private static func fetchLatestReleaseFromGithub() async throws -> GitHubRelease {
        guard let latestReleaseURL = latestReleaseAPIURL(repository: releaseRepository()) else {
            throw UpdateError.invalidRepository
        }
        return try await DownloadManager.downloadJson(
            GitHubRelease.self,
            from: latestReleaseURL,
            headers: [
                "Accept": "application/vnd.github+json",
                "User-Agent": "BingWallpaper/\(currentAppVersion())",
                "X-GitHub-Api-Version": "2022-11-28"
            ]
        )
    }

    static func fetchLatestAppVersionFromGithub() async -> String? {
        try? await fetchLatestReleaseFromGithub().tagName
    }
    
    private static func newVersionAvailable(_ currentAppVersion: String, _ latestAppVersion: String) -> Bool {
        let currentAppVersion = currentAppVersion.replacingOccurrences(of: "v", with: "")
        let latestAppVersion = latestAppVersion.replacingOccurrences(of: "v", with: "")
        return currentAppVersion.versionCompare(latestAppVersion) == .orderedAscending
    }
    
    static func checkForUpdate(notifyUserAboutNoNewVersion:Bool = false) async {
        let latestRelease: GitHubRelease
        do {
            latestRelease = try await fetchLatestReleaseFromGithub()
        } catch {
            logger.error("Failed to fetch the latest GitHub release: \(error.localizedDescription, privacy: .public)")
            if notifyUserAboutNoNewVersion {
                await showUpdateFailureDialog(error)
            }
            return
        }

        let latestGithubAppVersion = latestRelease.tagName
        
        let currentAppVersion = currentAppVersion()
        
        if newVersionAvailable(currentAppVersion, latestGithubAppVersion) == false {
            logger.info("No app update required, \(currentAppVersion, privacy: .public) is already the newest version")
            
            if notifyUserAboutNoNewVersion == true {
                    await showAlreadyUpToDateDialog()
            }
            return
        }
        
        guard await showShouldUpdateNowDialog(
            currentAppVersion: currentAppVersion,
            latestAppVersion: latestGithubAppVersion
        ) else {
            return
        }

        do {
            let pkgInstaller = try await downloadVerifiedInstaller(from: latestRelease)
            let pkgInstallerPathUrl = try FileHandler.savePkgInstallerToDisk(
                pkgInstaller: pkgInstaller,
                appVersion: latestGithubAppVersion
            )
            _ = await MainActor.run {
                NSWorkspace.shared.open(pkgInstallerPathUrl)
            }
        } catch {
            logger.error("Failed to download and verify the latest app installer: \(error.localizedDescription, privacy: .public)")
            await showUpdateFailureDialog(error)
        }
    }
    
    private static func downloadVerifiedInstaller(from release: GitHubRelease) async throws -> Data {
        guard let packageAsset = release.assets.first(where: { $0.name.hasSuffix(".pkg") }),
              let checksumAsset = release.assets.first(where: { $0.name == packageAsset.name + ".sha256" }) else {
            throw UpdateError.missingInstallerAssets(release.tagName)
        }

        async let packageData = DownloadManager.downloadPackage(from: packageAsset.browserDownloadUrl)
        async let checksumText = DownloadManager.downloadText(from: checksumAsset.browserDownloadUrl)
        let (installer, checksum) = try await (packageData, checksumText)
        guard verifyChecksum(packageData: installer, checksumText: checksum) else {
            throw UpdateError.checksumMismatch(packageAsset.name)
        }
        return installer
    }

    static func sha256Hex(for data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verifyChecksum(packageData: Data, checksumText: String) -> Bool {
        guard let expectedChecksum = checksumText
            .split(whereSeparator: { $0.isWhitespace })
            .first?
            .lowercased(),
              expectedChecksum.count == 64 else {
            return false
        }
        return sha256Hex(for: packageData) == expectedChecksum
    }
    
    @MainActor
    private static func showShouldUpdateNowDialog(currentAppVersion: String, latestAppVersion: String) -> Bool {
        let currentAppVersion = currentAppVersion.replacingOccurrences(of: "v", with: "")
        let latestAppVersion = latestAppVersion.replacingOccurrences(of: "v", with: "")
        let alert = NSAlert()
        alert.messageText = L("New version of BingWallpaper available")
        alert.informativeText = L("Do you want to update now?\nCurrent version: %@\nNew version: %@", currentAppVersion, latestAppVersion)
        let updateButton = alert.addButton(withTitle: L("Update"))
        alert.addButton(withTitle: L("Later"))
        alert.alertStyle = .informational
        
        alert.window.defaultButtonCell = updateButton.cell as? NSButtonCell
        
        return alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn
    }
    
    @MainActor
    private static func showAlreadyUpToDateDialog() {
        let alert = NSAlert()
        alert.messageText = L("BingWallpaper already up to date")
        alert.informativeText = L("There is no new version of BingWallpaper available")
        let updateButton = alert.addButton(withTitle: L("Ok"))
        alert.alertStyle = .informational
        
        alert.window.defaultButtonCell = updateButton.cell as? NSButtonCell
        
        alert.runModal()
    }

    @MainActor
    private static func showUpdateFailureDialog(_ error: Swift.Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Couldn’t Check for Updates")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
    
}
