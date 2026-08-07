import Foundation
import CommonCrypto
import Security
import SQLite3

/// Resolves the Kimi *website* `kimi-auth` JWT needed for membership quota APIs.
/// (Kimi Code CLI OAuth tokens cannot call GetSubscriptionStats — they return 401.)
enum KimiWebAuth {
    static func resolveToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["KIMI_AUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        if let stored = loadStoredToken(), !stored.isEmpty {
            return stored
        }
        // Prefer browser-cookie3 helper (handles Edge/Chrome cookie crypto correctly).
        if let viaPython = importViaPythonHelper(), !viaPython.isEmpty {
            try? saveStoredToken(viaPython)
            return viaPython
        }
        if let browser = importFromBrowsers(), !browser.isEmpty {
            // Cache for next launches (cookie DBs may be locked while browser is open).
            try? saveStoredToken(browser)
            return browser
        }
        return nil
    }

    /// Force re-import from browsers (ignores cached token).
    static func importFreshFromBrowsers() -> String? {
        if let viaPython = importViaPythonHelper(), !viaPython.isEmpty {
            try? saveStoredToken(viaPython)
            return viaPython
        }
        if let browser = importFromBrowsers(), !browser.isEmpty {
            try? saveStoredToken(browser)
            return browser
        }
        return nil
    }

    private static func importViaPythonHelper() -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("import_kimi_auth.py").path {
            candidates.append(bundled)
        }
        if let home = ProcessInfo.processInfo.environment["AIQUOTA_HOME"], !home.isEmpty {
            candidates.append((home as NSString).appendingPathComponent("scripts/import_kimi_auth.py"))
        }
        candidates.append(FileManager.default.currentDirectoryPath + "/scripts/import_kimi_auth.py")
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("AIQuota/scripts/import_kimi_auth.py").path
        )

        guard let script = candidates.first(where: {
            !$0.isEmpty && FileManager.default.fileExists(atPath: $0)
        }) else { return nil }

        for python in ["/usr/bin/python3", "/opt/homebrew/bin/python3"] {
            guard FileManager.default.isExecutableFile(atPath: python) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { continue }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let text, text.split(separator: ".").count == 3 { return text }
            } catch {
                continue
            }
        }
        return nil
    }

    static func saveStoredToken(_ token: String) throws {
        let url = storageURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try token.trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8)?
            .write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func clearStoredToken() {
        try? FileManager.default.removeItem(at: storageURL())
    }

    static func loadStoredToken() -> String? {
        guard let data = try? Data(contentsOf: storageURL()),
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    private static func storageURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIQuota/kimi-auth")
    }

    // MARK: - Browser cookie import

    private struct BrowserTarget {
        var cookiesPath: String
        var keychainService: String
        var keychainAccount: String
    }

    private static func importFromBrowsers() -> String? {
        for target in browserTargets() {
            if let token = readKimiAuth(from: target) {
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
                    result.append(BrowserTarget(
                        cookiesPath: path,
                        keychainService: browser.service,
                        keychainAccount: browser.account
                    ))
                }
            }
        }
        return result
    }

    private static func readKimiAuth(from target: BrowserTarget) -> String? {
        // Copy first — Chrome locks the live DB.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiquota-cookies-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.copyItem(atPath: target.cookiesPath, toPath: tmp.path)
            // Also copy WAL/SHM if present for consistency.
            for suffix in ["-wal", "-shm"] {
                let src = target.cookiesPath + suffix
                if FileManager.default.fileExists(atPath: src) {
                    try? FileManager.default.copyItem(atPath: src, toPath: tmp.path + suffix)
                }
            }
        } catch {
            return nil
        }

        guard let encrypted = queryEncryptedCookie(dbPath: tmp.path) else { return nil }
        guard let password = keychainPassword(
            service: target.keychainService,
            account: target.keychainAccount
        ) else { return nil }
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
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: blob, count: count)
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
        guard status == errSecSuccess, let data = item as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            // Fallback CLI (sometimes works when app isn't trusted yet).
            return keychainPasswordViaSecurity(service: service, account: account)
        }
        return password
    }

    private static func keychainPasswordViaSecurity(service: String, account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", service, "-a", account]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Chrome macOS cookie value: `v10` + AES-128-CBC(ciphertext), key from PBKDF2.
    private static func decryptChromeCookie(_ encrypted: Data, password: String) -> String? {
        guard encrypted.count > 3 else { return nil }
        let prefix = String(data: encrypted.prefix(3), encoding: .utf8) ?? ""
        guard prefix == "v10" || prefix == "v11" else {
            // Some older cookies store plaintext in `value`.
            if let text = String(data: encrypted, encoding: .utf8), text.contains(".") {
                return text
            }
            return nil
        }

        let key = pbkdf2(password: password, salt: Data("saltysalt".utf8), iterations: 1003, keyLength: 16)
        let iv = Data(repeating: 0x20, count: 16) // 16 spaces
        let cipher = encrypted.dropFirst(3)
        guard let plain = aes128CBCDecrypt(data: Data(cipher), key: key, iv: iv) else { return nil }
        let text = String(data: plain, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, text.contains(".") else { return nil }
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
