//
//  SpotifySupport.swift
//  boringNotch
//
//  Spotify helpers shared by SpotifyController and NowPlayingController:
//  - SpotifyScripting: reliable shuffle / repeat / track URI through Spotify's AppleScript
//    dictionary (Spotify ignores MediaRemote shuffle commands).
//  - SpotifyWebAPI: "Save to Liked Songs" through the Spotify Web API (OAuth PKCE with a
//    loopback redirect), since Spotify's AppleScript dictionary has no like command.
//

import AppKit
import CryptoKit
import Defaults
import Foundation
import Network
import Security

// MARK: - AppleScript bridge

enum SpotifyScripting {
    static let bundleIdentifier = "com.spotify.client"

    struct Extras: Equatable {
        var trackURI: String
        var isShuffled: Bool
        var isRepeating: Bool
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Track/episode URIs that can be saved to the library (local files cannot).
    static func isSavable(_ uri: String) -> Bool {
        uri.hasPrefix("spotify:track:") || uri.hasPrefix("spotify:episode:")
    }

    /// Reads the current track URI and the real shuffle / repeat state from Spotify.
    static func fetchExtras() async -> Extras? {
        guard isRunning else { return nil }
        let script = """
        tell application "Spotify"
            try
                return {id of current track, shuffling, repeating}
            on error
                return {"", false, false}
            end try
        end tell
        """
        guard let descriptor = try? await AppleScriptHelper.execute(script),
              descriptor.numberOfItems >= 3 else { return nil }
        return Extras(
            trackURI: descriptor.atIndex(1)?.stringValue ?? "",
            isShuffled: descriptor.atIndex(2)?.booleanValue ?? false,
            isRepeating: descriptor.atIndex(3)?.booleanValue ?? false
        )
    }

    /// Toggles shuffle and returns the new state. Uses an explicit if/else because
    /// `set shuffling to not shuffling` is not applied reliably by recent Spotify builds.
    @discardableResult
    static func toggleShuffle() async -> Bool? {
        await toggleBooleanProperty("shuffling")
    }

    /// Toggles repeat (Spotify's AppleScript only exposes on/off, not repeat-one).
    @discardableResult
    static func toggleRepeat() async -> Bool? {
        await toggleBooleanProperty("repeating")
    }

    private static func toggleBooleanProperty(_ property: String) async -> Bool? {
        guard isRunning else { return nil }
        let script = """
        tell application "Spotify"
            set previousValue to \(property)
            if previousValue then
                set \(property) to false
            else
                set \(property) to true
            end if
            return (not previousValue)
        end tell
        """
        guard let descriptor = try? await AppleScriptHelper.execute(script) else { return nil }
        return descriptor.booleanValue
    }
}

// MARK: - Web API errors

enum SpotifyWebAPIError: LocalizedError {
    case missingClientID
    case notAuthorized
    case authorizationDenied(String)
    case authorizationTimedOut
    case stateMismatch
    case invalidCallback
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Enter your Spotify app Client ID first."
        case .notAuthorized:
            return "Not connected to Spotify."
        case .authorizationDenied(let reason):
            return "Spotify authorization was denied (\(reason))."
        case .authorizationTimedOut:
            return "Spotify authorization timed out."
        case .stateMismatch:
            return "Spotify authorization failed (state mismatch)."
        case .invalidCallback:
            return "Spotify authorization failed (invalid callback)."
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Spotify API error \(status)\(trimmed.isEmpty ? "" : ": \(trimmed.prefix(200))")"
        }
    }
}

// MARK: - Web API client

/// Minimal Spotify Web API client used to like / unlike the current track.
///
/// Setup (once): create an app on https://developer.spotify.com/dashboard, add the redirect URI
/// `SpotifyWebAPI.redirectURI` and paste the app's Client ID in Settings > Media.
/// Since February 2026, Development Mode apps require the app owner to have Spotify Premium.
final class SpotifyWebAPI: ObservableObject, @unchecked Sendable {
    static let shared = SpotifyWebAPI()

    static let callbackPort: UInt16 = 43821
    static let redirectURI = "http://127.0.0.1:\(callbackPort)/callback"
    static let scopes = "user-library-read user-library-modify"
    static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!

    @Published private(set) var isAuthorized: Bool = false
    @Published private(set) var isAuthorizing: Bool = false
    @Published private(set) var lastError: String?

    private let lock = NSLock()
    private var accessToken: String?
    private var accessTokenExpiry: Date = .distantPast
    private var refreshToken: String?
    private var refreshTask: Task<String, Error>?

    private let keychainService = "com.boringnotch.spotify"
    private let keychainAccount = "refresh_token"

    private init() {
        refreshToken = readKeychain()
        isAuthorized = refreshToken != nil
    }

    var clientID: String {
        Defaults[.spotifyClientID].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when likes can be read/written (client ID set and user connected).
    var isReady: Bool {
        let hasRefreshToken = lock.withLock { refreshToken != nil }
        return hasRefreshToken && !clientID.isEmpty
    }

    // MARK: Library

    func isSaved(uri: String) async throws -> Bool {
        let data = try await send(method: "GET", path: "/me/library/contains", uris: [uri])
        let values = try JSONDecoder().decode([Bool].self, from: data)
        return values.first ?? false
    }

    func setSaved(_ saved: Bool, uri: String) async throws {
        _ = try await send(method: saved ? "PUT" : "DELETE", path: "/me/library", uris: [uri])
    }

    private func send(method: String, path: String, uris: [String], isRetry: Bool = false) async throws -> Data {
        let token = try await validAccessToken()

        var components = URLComponents(string: "https://api.spotify.com/v1" + path)!
        components.percentEncodedQuery = "uris=" + uris.map(Self.percentEncode).joined(separator: ",")

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 && !isRetry {
            invalidateAccessToken()
            return try await send(method: method, path: path, uris: uris, isRetry: true)
        }
        guard (200..<300).contains(status) else {
            throw SpotifyWebAPIError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: Authorization (PKCE + loopback redirect)

    @MainActor
    func authorize() async {
        guard !isAuthorizing else { return }
        let clientID = self.clientID
        guard !clientID.isEmpty else {
            lastError = SpotifyWebAPIError.missingClientID.localizedDescription
            return
        }

        isAuthorizing = true
        lastError = nil
        defer { isAuthorizing = false }

        let verifier = Self.randomURLSafeString(byteCount: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(byteCount: 16)

        var authorizeURL = URLComponents(string: "https://accounts.spotify.com/authorize")!
        authorizeURL.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Self.scopes),
        ]
        guard let url = authorizeURL.url else { return }

        do {
            let server = SpotifyOAuthCallbackServer()
            let callback = try await server.waitForCallback(port: Self.callbackPort, timeout: 300) {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            let items = callback.queryItems ?? []
            if let error = items.first(where: { $0.name == "error" })?.value {
                throw SpotifyWebAPIError.authorizationDenied(error)
            }
            guard items.first(where: { $0.name == "state" })?.value == state else {
                throw SpotifyWebAPIError.stateMismatch
            }
            guard let code = items.first(where: { $0.name == "code" })?.value else {
                throw SpotifyWebAPIError.invalidCallback
            }

            let token = try await requestToken([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "client_id": clientID,
                "code_verifier": verifier,
            ])
            store(token)
            isAuthorized = true
            NSApp.activate(ignoringOtherApps: true)
            MusicManager.shared.refreshFavoriteSupport()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func signOut() {
        lock.withLock {
            accessToken = nil
            accessTokenExpiry = .distantPast
            refreshToken = nil
            refreshTask?.cancel()
            refreshTask = nil
        }
        deleteKeychain()
        isAuthorized = false
        lastError = nil
        MusicManager.shared.refreshFavoriteSupport()
    }

    // MARK: Tokens

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    private enum TokenLookup {
        case cached(String)
        case pending(Task<String, Error>)
        case started(Task<String, Error>)
        case missing
    }

    private func validAccessToken() async throws -> String {
        let clientID = self.clientID
        // Everything happens under the lock so concurrent callers share a single refresh
        // (Spotify may rotate refresh tokens, so two parallel refreshes could fail).
        let lookup: TokenLookup = lock.withLock {
            if let token = accessToken, accessTokenExpiry > Date().addingTimeInterval(60) {
                return .cached(token)
            }
            if let task = refreshTask {
                return .pending(task)
            }
            guard let currentRefreshToken = refreshToken else {
                return .missing
            }
            let task = Task<String, Error> { [weak self] in
                guard let self else { throw SpotifyWebAPIError.notAuthorized }
                let response = try await self.requestToken([
                    "grant_type": "refresh_token",
                    "refresh_token": currentRefreshToken,
                    "client_id": clientID,
                ])
                self.store(response)
                return response.access_token
            }
            refreshTask = task
            return .started(task)
        }

        let task: Task<String, Error>
        switch lookup {
        case .cached(let token):
            return token
        case .pending(let pendingTask):
            return try await pendingTask.value
        case .missing:
            throw SpotifyWebAPIError.notAuthorized
        case .started(let startedTask):
            task = startedTask
        }

        defer {
            lock.withLock { refreshTask = nil }
        }
        do {
            return try await task.value
        } catch SpotifyWebAPIError.http(let status, let body) where status == 400 {
            // Refresh token revoked or expired: force a new connection.
            await MainActor.run { self.signOut() }
            throw SpotifyWebAPIError.http(status: status, body: body)
        }
    }

    private func invalidateAccessToken() {
        lock.withLock {
            accessToken = nil
            accessTokenExpiry = .distantPast
        }
    }

    private func store(_ response: TokenResponse) {
        let tokenToPersist: String? = lock.withLock {
            accessToken = response.access_token
            accessTokenExpiry = Date().addingTimeInterval(TimeInterval(response.expires_in))
            if let newRefreshToken = response.refresh_token {
                refreshToken = newRefreshToken
            }
            return refreshToken
        }
        if let tokenToPersist {
            writeKeychain(tokenToPersist)
        }
    }

    private func requestToken(_ parameters: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .map { "\(Self.percentEncode($0.key))=\(Self.percentEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw SpotifyWebAPIError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: Keychain

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private func readKeychain() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychain(_ value: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            keychainQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var query = keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private func deleteKeychain() {
        SecItemDelete(keychainQuery as CFDictionary)
    }

    // MARK: Helpers

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? value
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback OAuth callback server

/// Tiny one-shot HTTP server bound to 127.0.0.1 that captures Spotify's OAuth redirect.
private final class SpotifyOAuthCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.boringnotch.spotify.oauth")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URLComponents, Error>?

    /// Starts listening, calls `onReady` once the port is bound (open the browser there),
    /// and returns the callback URL components.
    func waitForCallback(
        port: UInt16,
        timeout: TimeInterval,
        onReady: @escaping @Sendable () -> Void
    ) async throws -> URLComponents {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.allowLocalEndpointReuse = true
                    parameters.requiredLocalEndpoint = .hostPort(
                        host: .ipv4(.loopback),
                        port: NWEndpoint.Port(rawValue: port)!
                    )
                    let listener = try NWListener(using: parameters)
                    listener.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            onReady()
                        case .failed(let error):
                            self?.finish(.failure(error))
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.handle(connection)
                    }
                    self.listener = listener
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        self.finish(.failure(SpotifyWebAPIError.authorizationTimedOut))
                    }
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    /// Must be called on `queue`.
    private func finish(_ result: Result<URLComponents, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        listener?.cancel()
        listener = nil
        continuation.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let requestLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")

            guard parts.count >= 2,
                  let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
                  components.path == "/callback" else {
                self.respond(on: connection, status: "404 Not Found", message: "Not found")
                return
            }

            let succeeded = components.queryItems?.contains { $0.name == "code" } ?? false
            self.respond(
                on: connection,
                status: "200 OK",
                message: succeeded
                    ? "Boring Notch is now connected to Spotify. You can close this tab."
                    : "Spotify authorization failed. You can close this tab and try again."
            )
            self.finish(.success(components))
        }
    }

    private func respond(on connection: NWConnection, status: String, message: String) {
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><title>Boring Notch</title></head>
        <body style="font-family:-apple-system,sans-serif;background:#000;color:#fff;display:flex;\
        align-items:center;justify-content:center;height:100vh;margin:0">
        <p style="font-size:18px">\(message)</p></body></html>
        """
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
