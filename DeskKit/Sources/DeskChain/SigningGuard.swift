import Foundation

extension EIP712 {
    /// What must hold of a server-supplied payload before the wallet key signs it.
    ///
    /// The enrolment payload is chosen by Perpl and hashed by us, and the wallet key
    /// signs the result. Nothing in the hashing can tell an enrolment from an ERC-2612
    /// `Permit` — both are valid typed data — so a gateway that answered
    /// `/api-key/payload` with a permit naming an attacker as spender and `2^256-1` as
    /// value would be handed a signed unlimited allowance over the user's AUSD, with
    /// every line of the hashing behaving correctly.
    ///
    /// `encodedType` is the load-bearing check. It is the canonical type string, so
    /// pinning it fixes the primary type and every field name and field type in one
    /// comparison, and no substituted struct can match it.
    public struct Expectation: Sendable, Hashable {
        public let encodedType: String
        public let domainEncodedType: String
        public let domainName: String
        public let domainVersion: String
        public let allowedChainIDs: Set<UInt64>
        /// The message field that must name our own address, binding the payload to the
        /// key about to sign it.
        public let signerField: String
        public let signer: String
        public let statementField: String?
        public let statement: String?

        public init(
            encodedType: String,
            domainEncodedType: String,
            domainName: String,
            domainVersion: String,
            allowedChainIDs: Set<UInt64>,
            signerField: String,
            signer: String,
            statementField: String? = nil,
            statement: String? = nil
        ) {
            self.encodedType = encodedType
            self.domainEncodedType = domainEncodedType
            self.domainName = domainName
            self.domainVersion = domainVersion
            self.allowedChainIDs = allowedChainIDs
            self.signerField = signerField
            self.signer = signer
            self.statementField = statementField
            self.statement = statement
        }

        public static let perplEncodedType = """
            PerplRegisterApiKey(address signer,string statement,string publicKey,string \
            scope,string label,string expiresAt,string ipCidrs,string origin,string \
            builderId,string maxBuilderFeePer100K,uint64 time)
            """

        public static let perplDomainEncodedType =
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)"

        public static let perplStatement =
            "I authorize the creation of Perpl API key with the specified scope and parameters"

        public static func perplEnrolment(signer: String, chainID: UInt64) -> Expectation {
            Expectation(
                encodedType: perplEncodedType,
                domainEncodedType: perplDomainEncodedType,
                domainName: "perpl.xyz",
                domainVersion: "1",
                allowedChainIDs: [chainID],
                signerField: "signer",
                signer: signer,
                statementField: "statement",
                statement: perplStatement)
        }
    }

    public enum GuardFailure: Error, Equatable, Sendable {
        case typeNotAsExpected(expected: String, got: String)
        case domainTypeNotAsExpected(expected: String, got: String)
        case domainFieldNotAsExpected(name: String, got: String?)
        case chainIDNotAllowed(String?)
        case signerIsNotOurs(expected: String, got: String?)
        case statementNotAsExpected(String?)
        case messageHasUndeclaredFields([String])
    }

    /// The only way to a signable digest.
    public static func digest(_ typedData: TypedData, expecting expectation: Expectation) throws -> Data {
        let encoded = try encodeType(typedData.primaryType, types: typedData.types)
        guard encoded == expectation.encodedType else {
            throw GuardFailure.typeNotAsExpected(expected: expectation.encodedType, got: encoded)
        }

        let domainEncoded = try encodeType("EIP712Domain", types: typedData.types)
        guard domainEncoded == expectation.domainEncodedType else {
            throw GuardFailure.domainTypeNotAsExpected(
                expected: expectation.domainEncodedType, got: domainEncoded)
        }

        for (name, expected) in [("name", expectation.domainName), ("version", expectation.domainVersion)] {
            let got = typedData.domain[name]?.stringValue
            guard got == expected else { throw GuardFailure.domainFieldNotAsExpected(name: name, got: got) }
        }

        let chainText = typedData.domain["chainId"]?.stringValue
        guard let chainText, let chainID = Self.chainID(chainText),
              expectation.allowedChainIDs.contains(chainID)
        else { throw GuardFailure.chainIDNotAllowed(chainText) }

        let signer = typedData.message[expectation.signerField]?.stringValue
        guard let signer, Self.sameAddress(signer, expectation.signer) else {
            throw GuardFailure.signerIsNotOurs(expected: expectation.signer, got: signer)
        }

        if let field = expectation.statementField, let expected = expectation.statement {
            let got = typedData.message[field]?.stringValue
            guard got == expected else { throw GuardFailure.statementNotAsExpected(got) }
        }

        // A field the type does not declare is a field the signature does not cover, so
        // it must not exist rather than be quietly ignored.
        let declared = Set((typedData.types[typedData.primaryType] ?? []).map(\.name))
        let undeclared = Set(typedData.message.keys).subtracting(declared)
        guard undeclared.isEmpty else {
            throw GuardFailure.messageHasUndeclaredFields(undeclared.sorted())
        }

        return try digest(typedData)
    }

    static func chainID(_ text: String) -> UInt64? {
        guard let word = try? ABIWord.uint(text, bits: 64) else { return nil }
        return word.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    static func sameAddress(_ lhs: String, _ rhs: String) -> Bool {
        func normalised(_ text: String) -> String? {
            guard let bytes = try? ABIWord.hexBytes(text), bytes.count == 20 else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        guard let left = normalised(lhs), let right = normalised(rhs) else { return false }
        return left == right
    }
}
