import Foundation

struct SupabaseSessionValue: Equatable, Sendable {
    let userID: UUID
    let email: String?
    let displayName: String?
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval
}

enum SupabaseSessionMapper {
    static func map(_ value: SupabaseSessionValue) throws -> AuthenticationSession {
        guard hasContent(value.accessToken),
              hasContent(value.refreshToken),
              value.expiresAt.isFinite,
              value.expiresAt > 0 else {
            throw AuthenticationProviderError.invalidSession
        }

        let maskedEmail = mask(email: value.email)
        let displayName = normalized(value.displayName, maximumCharacters: 120)
            ?? maskedEmail
            ?? "Google User"
        return AuthenticationSession(
            summary: AccountSummary(
                provider: .google,
                accountID: value.userID.uuidString.lowercased(),
                displayName: displayName,
                maskedEmail: maskedEmail,
                expiresAt: Date(timeIntervalSince1970: value.expiresAt)
            ),
            accessToken: value.accessToken,
            refreshCredential: value.refreshToken
        )
    }

    private static func mask(email: String?) -> String? {
        guard let email = normalized(email, maximumCharacters: 320),
              let atIndex = email.firstIndex(of: "@"),
              atIndex != email.startIndex,
              email.index(after: atIndex) != email.endIndex,
              email[email.index(after: atIndex)...].contains(".") else {
            return nil
        }
        let localPart = email[..<atIndex]
        let domain = email[email.index(after: atIndex)...]
        guard localPart.count <= 64, domain.count <= 255 else { return nil }
        let hiddenCount = max(localPart.count - 1, 0)
        return "\(localPart.first!)\(String(repeating: "•", count: hiddenCount))@\(domain)"
    }

    private static func normalized(
        _ value: String?,
        maximumCharacters: Int
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumCharacters,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return nil
        }
        return trimmed
    }

    private static func hasContent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
