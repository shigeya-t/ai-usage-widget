import Foundation

/// 同じ bundle ID のアプリが `/Applications` と `~/Applications` の両方にあると、
/// 再起動のたびに Launch Services が両方を登録し直す（`lsregister -u` しても戻る）。
/// その直後の chronod / Notification Center は拡張を引けず
/// （"Widget extension could not be looked up"）、ウィジェットがプレースホルダのまま残る。
enum DuplicateInstall {
    static func applicationFolders(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// 起動時に再登録される場所にある、実行中のもの以外のコピー。
    /// `candidates` は bundle ID が一致するものだけを渡す。
    static func otherCopies(candidates: [URL], running: URL, folders: [URL]) -> [URL] {
        let runningPath = normalized(running)
        let folderPaths = folders.map { normalized($0) + "/" }
        var seen = Set<String>()
        var result: [URL] = []
        for url in candidates {
            let path = normalized(url)
            guard path != runningPath,
                  !path.hasPrefix(runningPath + "/"),
                  folderPaths.contains(where: { path.hasPrefix($0) }),
                  seen.insert(path).inserted
            else { continue }
            result.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return result.sorted { $0.path < $1.path }
    }

    /// ホームを `~` にした表示用のパス。
    static func displayPath(_ url: URL, home: URL) -> String {
        let path = normalized(url)
        let homePath = normalized(home)
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    private static func normalized(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path.precomposedStringWithCanonicalMapping
    }
}
