import Foundation

/// メニューバーに出すビルド識別子。ハッシュはビルド時に Info.plist へ書く。
enum BuildStamp {
    static func label(version: String?, commit: String?) -> String? {
        let versionText = cleaned(version)
        let commitText = cleaned(commit)
        switch (versionText, commitText) {
        case let (version?, commit?):
            return "\(version) · \(commit)"
        case let (nil, commit?):
            return commit
        case let (version?, nil):
            return version
        default:
            return nil
        }
    }

    static func label(in bundle: Bundle = .main) -> String? {
        label(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            commit: bundle.object(forInfoDictionaryKey: "GitCommitHash") as? String
        )
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.hasPrefix("$(") { return nil }
        return value
    }
}
