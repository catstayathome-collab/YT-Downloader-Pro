import Auth
import Foundation
import XCTest
@testable import YTDownloaderPro2

final class EphemeralSupabaseAuthStorageTests: XCTestCase {
    func testEphemeralStorageStartsEmptyAndSupportsMemoryOnlyRoundTrip() throws {
        let storage = EphemeralSupabaseAuthStorage()

        XCTAssertNil(try storage.retrieve(key: "session"))
        try storage.store(key: "session", value: Data("temporary".utf8))
        XCTAssertEqual(try storage.retrieve(key: "session"), Data("temporary".utf8))
        try storage.remove(key: "session")
        try storage.remove(key: "session")
        XCTAssertNil(try storage.retrieve(key: "session"))
    }

    func testNewStorageInstanceCannotRestorePriorProcessState() throws {
        let first = EphemeralSupabaseAuthStorage()
        try first.store(key: "session", value: Data("temporary".utf8))

        let replacement = EphemeralSupabaseAuthStorage()

        XCTAssertNil(try replacement.retrieve(key: "session"))
        XCTAssertEqual(try first.retrieve(key: "session"), Data("temporary".utf8))
    }

    func testStorageConformsToSDKBoundaryWithoutUsingCredentialVault() throws {
        let storage: any AuthLocalStorage = EphemeralSupabaseAuthStorage()

        try storage.store(key: "pkce", value: Data("memory-only".utf8))

        XCTAssertEqual(try storage.retrieve(key: "pkce"), Data("memory-only".utf8))
    }
}
