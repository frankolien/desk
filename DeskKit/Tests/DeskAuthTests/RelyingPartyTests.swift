import Foundation
import Testing

@testable import DeskAuth

@Suite("The relying party")
struct RelyingPartyTests {
    @Test("A plain domain is accepted and normalised")
    func accepted() throws {
        #expect(try RelyingParty("desk.trade").identifier == "desk.trade")
        #expect(try RelyingParty("Desk.Trade").identifier == "desk.trade")
        #expect(try RelyingParty("  desk.trade  ").identifier == "desk.trade")
        #expect(try RelyingParty("app.desk.trade").identifier == "app.desk.trade")
        #expect(try RelyingParty("my-desk.co.uk").identifier == "my-desk.co.uk")
    }

    @Test("A URL is not a relying party")
    func rejectsURLShapes() {
        // Each of these fails the ceremony on a device rather than at build time, which
        // is why they are caught here.
        #expect(throws: RelyingParty.Failure.containsScheme("https://desk.trade")) {
            try RelyingParty("https://desk.trade")
        }
        #expect(throws: RelyingParty.Failure.containsPath("desk.trade/app")) {
            try RelyingParty("desk.trade/app")
        }
        #expect(throws: RelyingParty.Failure.containsPort("desk.trade:443")) {
            try RelyingParty("desk.trade:443")
        }
        #expect(throws: RelyingParty.Failure.containsCredentials("user@desk.trade")) {
            try RelyingParty("user@desk.trade")
        }
    }

    @Test("A bare label has no registrable domain, so localhost is out")
    func rejectsBareLabels() {
        // No association file can be served for a bare label, so there is no local
        // shortcut and no temptation to ship one.
        #expect(throws: RelyingParty.Failure.notADomain("localhost")) { try RelyingParty("localhost") }
        #expect(throws: RelyingParty.Failure.notADomain("desk")) { try RelyingParty("desk") }
        #expect(throws: RelyingParty.Failure.notADomain("desk.trade.")) { try RelyingParty("desk.trade.") }
    }

    @Test("Malformed labels are refused")
    func rejectsBadLabels() {
        #expect(throws: (any Error).self) { try RelyingParty("desk..trade") }
        #expect(throws: (any Error).self) { try RelyingParty("-desk.trade") }
        #expect(throws: (any Error).self) { try RelyingParty("desk-.trade") }
        #expect(throws: (any Error).self) { try RelyingParty("desk_app.trade") }
        #expect(throws: (any Error).self) { try RelyingParty("") }
        #expect(throws: (any Error).self) { try RelyingParty(String(repeating: "a", count: 64) + ".trade") }
    }

    @Test("A non-ASCII domain must arrive already punycoded")
    func rejectsUnicode() {
        #expect(throws: RelyingParty.Failure.notASCII("büro.trade")) { try RelyingParty("büro.trade") }
        #expect(throws: Never.self) { try RelyingParty("xn--bro-vka.trade") }
    }

    @Test("The entitlement and the association URL are derived, never typed twice")
    func derivedStrings() throws {
        let party = try RelyingParty("desk.trade")
        #expect(party.associatedDomain == "webcredentials:desk.trade")
        #expect(party.associationFileURL.absoluteString
            == "https://desk.trade/.well-known/apple-app-site-association")
    }
}

@Suite("Passkey failures")
struct PasskeyFailureTests {
    @Test("Every failure says something a person can read")
    func everyCaseHasASentence() throws {
        let cases: [PasskeyFailure] = [
            .prfUnsupported, .prfReturnedNothing, .cancelledByUser, .noCredentialFound,
            .relyingPartyNotAssociated(try RelyingParty("desk.trade")),
            .platformRefused("The passkey server is unreachable."),
        ]
        for failure in cases {
            #expect(!failure.sentence.isEmpty)
            #expect(failure.sentence.first?.isUppercase == true)
            // No error codes, no domains, no "an error occurred".
            #expect(!failure.sentence.lowercased().contains("error"))
        }
    }

    @Test("No failure may fall back to a stored key")
    func noFallback() throws {
        // The product's first principle: there is no key at rest to fall back to, and a
        // case that implied otherwise would be a lie in a type.
        let cases: [PasskeyFailure] = [
            .prfUnsupported, .prfReturnedNothing, .cancelledByUser, .noCredentialFound,
            .relyingPartyNotAssociated(try RelyingParty("desk.trade")), .platformRefused("x"),
        ]
        for failure in cases { #expect(failure.mayFallBackToStoredKey == false) }
    }

    @Test("An authenticator with no PRF is told so plainly")
    func prfSentence() {
        // The product document's acceptance criterion for sign-in.
        let sentence = PasskeyFailure.prfUnsupported.sentence
        #expect(sentence.contains("passkey"))
        #expect(!sentence.contains("PRF"))
        #expect(!sentence.contains("seed"))
    }
}
