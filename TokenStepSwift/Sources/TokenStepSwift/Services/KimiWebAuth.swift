import CommonCrypto
import Foundation
import Security
import SQLite3

enum KimiWebAuth {
    static func resolveToken() -> String? {
        let stored = [
            ProcessInfo.processInfo.environment["KIMI_AUTH_TOKEN"],
            TokenStepSecrets.get(.kimiAccessToken),
            loadStoredToken()
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && looksLikeSession($0) }

        if let fresh = stored.first(where: isFresh) {
            return fresh
        }
        if let imported = importFreshFromBrowsers() {
            return imported
        }
        // JWT exp is a hint, not the API. Keep the last session so a
        // stale cookie still reaches GetSubscriptionStats, like the
        // standalone AIQuota client did.
        return stored.first
    }

    static func importFreshFromBrowsers() -> String? {
        let tokens = [
            importFromKimiDesktop(),
            importViaPythonHelper(),
            importFromBrowsers()
        ]
        guard let token = tokens.compactMap({ $0 }).first(where: isFresh) else {
            return nil
        }
        try? saveStoredToken(token)
        return token
    }

    static func isFresh(_ token: String) -> Bool {
        looksLikeSession(token) && isAccessToken(token) && !QuotaAuth.needsRefresh(token)
    }

    static func isAccessToken(_ token: String) -> Bool {
        let typ = (QuotaAuth.jwtPayload(token)?["typ"] as? String)?.lowercased()
        if typ == "refresh" { return false }
        return typ == "access" || typ == nil
    }

    static func saveStoredToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFresh(trimmed) else {
            throw TokenStepError.message(L("kimi-auth 已过期，请先打开 Kimi 桌面版或网页重新登录"))
        }
        TokenStepSecrets.set(.kimiAccessToken, value: trimmed)
        let url = storageURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try trimmed.data(using: .utf8)?.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func clearStoredToken() {
        TokenStepSecrets.delete(.kimiAccessToken)
        try? FileManager.default.removeItem(at: storageURL())
    }

    static func loadStoredToken() -> String? {
        if let stored = TokenStepSecrets.get(.kimiAccessToken), looksLikeSession(stored) {
            return stored
        }
        for url in [storageURL(), aiquotaStorageURL] {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  looksLikeSession(text)
            else { continue }
            return text
        }
        return nil
    }

    static func looksLikeSession(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().hasPrefix("sk-") { return false }
        return trimmed.split(separator: ".").count == 3 || trimmed.count >= 40
    }

    private static func storageURL() -> URL {
        AppPaths.appSupportRoot.appendingPathComponent("kimi-auth")
    }

    private static var aiquotaStorageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIQuota/kimi-auth")
    }

    private static func importViaPythonHelper() -> String? {
        let candidates = scriptCandidates()
        guard let script = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        for python in ["/usr/bin/python3", "/opt/homebrew/bin/python3"] {
            guard FileManager.default.isExecutableFile(atPath: python) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                continue
            }
            guard process.terminationStatus == 0 else { continue }
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, looksLikeSession(text) {
                return text
            }
        }
        return nil
    }

    private static func scriptCandidates() -> [String] {
        var result: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("import_kimi_auth.py").path {
            result.append(bundled)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        result.append(home.appendingPathComponent("AI/TokenStep/scripts/import_kimi_auth.py").path)
        result.append(home.appendingPathComponent("AI/AIQuota/scripts/import_kimi_auth.py").path)
        result.append(FileManager.default.currentDirectoryPath + "/scripts/import_kimi_auth.py")
        return result
    }

    private struct BrowserTarget {
        var cookiesPath: String
        var keychainService: String
        var keychainAccount: String
    }

    private static func importFromBrowsers() -> String? {
        for target in browserTargets() {
            if let token = readKimiAuth(from: target), isFresh(token) {
                return token
            }
        }
        return nil
    }

    private static func importFromKimiDesktop() -> String? {
        if let cookie = importFromKimiDesktopCookies(), isFresh(cookie) {
            return cookie
        }
        return importFromKimiDesktopLocalStorage()
    }

    private static func importFromKimiDesktopCookies() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kimi-desktop/Cookies")
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstep-kimi-desktop-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
            for suffix in ["-wal", "-shm", "-journal"] {
                let src = url.path + suffix
                if FileManager.default.fileExists(atPath: src) {
                    try? FileManager.default.copyItem(atPath: src, toPath: tmp.path + suffix)
                }
            }
        } catch {
            return nil
        }
        return queryPlainCookie(dbPath: tmp.path)
    }

    /// Kimi Desktop keeps a short-lived access JWT in Electron Local Storage
    /// and often leaves Cookies/kimi-auth stale. Prefer the newest access token.
    private static func importFromKimiDesktopLocalStorage() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent("Library/Application Support/kimi-desktop/Local Storage/leveldb"),
            home.appendingPathComponent("Library/Application Support/kimi-desktop/Session Storage")
        ]
        var best: (token: String, exp: Date)?
        for root in roots {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }
            for url in files {
                let name = url.lastPathComponent
                guard name.hasSuffix(".log") || name.hasSuffix(".ldb") else { continue }
                guard let data = try? Data(contentsOf: url) else { continue }
                for token in jwtTokens(in: data) where isFresh(token) {
                    guard let exp = QuotaAuth.jwtExp(token) else { continue }
                    if best == nil || exp > best!.exp {
                        best = (token, exp)
                    }
                }
            }
        }
        return best?.token
    }

    private static func jwtTokens(in data: Data) -> [String] {
        guard let text = String(data: data, encoding: .isoLatin1) else { return [] }
        var result: [String] = []
        var search = text.startIndex
        while let range = text.range(of: "eyJ", range: search..<text.endIndex) {
            var end = range.lowerBound
            while end < text.endIndex {
                let character = text[end]
                if character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." {
                    end = text.index(after: end)
                } else {
                    break
                }
            }
            let token = String(text[range.lowerBound..<end])
            if token.split(separator: ".").count == 3, looksLikeSession(token) {
                result.append(token)
            }
            search = end
        }
        return result
    }

    private static func queryPlainCookie(dbPath: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT value FROM cookies
        WHERE name = 'kimi-auth'
          AND (host_key = '.kimi.com' OR host_key = 'kimi.com' OR host_key LIKE '%kimi.com')
        ORDER BY last_access_utc DESC
        LIMIT 5;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(stmt, 0) else { continue }
            let token = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if isFresh(token) {
                return token
            }
        }
        return nil
    }

    private static func browserTargets() -> [BrowserTarget] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let profiles = ["Default"] + (1..<8).map { "Profile \($0)" }
        var result: [BrowserTarget] = []
        let browsers: [(dir: String, service: String, account: String)] = [
            ("Google/Chrome", "Chrome Safe Storage", "Chrome"),
            ("Arc/User Data", "Arc Safe Storage", "Arc"),
            ("Microsoft Edge", "Microsoft Edge Safe Storage", "Microsoft Edge"),
            ("BraveSoftware/Brave-Browser", "Brave Safe Storage", "Brave"),
            ("Chromium", "Chromium Safe Storage", "Chromium")
        ]
        for browser in browsers {
            for profile in profiles {
                let path = "\(home)/Library/Application Support/\(browser.dir)/\(profile)/Cookies"
                if FileManager.default.fileExists(atPath: path) {
                    result.append(
                        BrowserTarget(
                            cookiesPath: path,
                            keychainService: browser.service,
                            keychainAccount: browser.account
                        )
                    )
                }
            }
        }
        return result
    }

    private static func readKimiAuth(from target: BrowserTarget) -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstep-cookies-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.copyItem(atPath: target.cookiesPath, toPath: tmp.path)
            for suffix in ["-wal", "-shm"] {
                let src = target.cookiesPath + suffix
                if FileManager.default.fileExists(atPath: src) {
                    try? FileManager.default.copyItem(atPath: src, toPath: tmp.path + suffix)
                }
            }
        } catch {
            return nil
        }
        guard let encrypted = queryEncryptedCookie(dbPath: tmp.path),
              let password = keychainPassword(service: target.keychainService, account: target.keychainAccount)
        else { return nil }
        return decryptChromeCookie(encrypted, password: password)
    }

    private static func queryEncryptedCookie(dbPath: String) -> Data? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT encrypted_value FROM cookies
        WHERE name = 'kimi-auth'
          AND (host_key = '.kimi.com' OR host_key = 'kimi.com' OR host_key LIKE '%kimi.com')
        ORDER BY length(encrypted_value) DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    private static func keychainPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) {
            return password
        }
        return keychainPasswordViaSecurity(service: service, account: account)
    }

    private static func keychainPasswordViaSecurity(service: String, account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", service, "-a", account]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decryptChromeCookie(_ encrypted: Data, password: String) -> String? {
        guard encrypted.count > 3 else { return nil }
        let prefix = String(data: encrypted.prefix(3), encoding: .utf8) ?? ""
        guard prefix == "v10" || prefix == "v11" else {
            if let text = String(data: encrypted, encoding: .utf8), looksLikeSession(text) {
                return text
            }
            return nil
        }
        let key = pbkdf2(password: password, salt: Data("saltysalt".utf8), iterations: 1003, keyLength: 16)
        let iv = Data(repeating: 0x20, count: 16)
        guard let plain = aes128CBCDecrypt(data: Data(encrypted.dropFirst(3)), key: key, iv: iv),
              let text = String(data: plain, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              looksLikeSession(text)
        else { return nil }
        return text
    }

    private static func pbkdf2(password: String, salt: Data, iterations: UInt32, keyLength: Int) -> Data {
        var derived = Data(count: keyLength)
        _ = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, password.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    iterations,
                    derivedBytes.bindMemory(to: UInt8.self).baseAddress, keyLength
                )
            }
        }
        return derived
    }

    private static func aes128CBCDecrypt(data: Data, key: Data, iv: Data) -> Data? {
        let outLength = data.count + kCCBlockSizeAES128
        var out = Data(count: outLength)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outBytes.baseAddress, outLength,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }
}
