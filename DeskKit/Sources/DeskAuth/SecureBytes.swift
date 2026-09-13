import Darwin
import Foundation

/// A byte buffer that is wiped when it goes away.
///
/// Write-once: there is no mutable accessor, which is what makes `@unchecked Sendable`
/// sound rather than a suppressed warning. The contents cannot change after `init`, so
/// there is nothing to tear.
///
/// The honest limit, stated where someone will read it: Swift and its crypto libraries
/// copy bytes where they please, so this narrows the window rather than closing it. The
/// property that actually holds is that nothing here is written to disk and nothing
/// survives the object.
public final class SecureBytes: @unchecked Sendable {
    public let count: Int
    private let storage: UnsafeMutableRawPointer

    public init(count: Int) {
        precondition(count >= 0)
        self.count = count
        storage = .allocate(byteCount: Swift.max(count, 1), alignment: 1)
        memset(storage, 0, Swift.max(count, 1))
    }

    public convenience init(_ bytes: Data) {
        self.init(count: bytes.count)
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            storage.copyMemory(from: base, byteCount: bytes.count)
        }
    }

    deinit {
        // memset_s rather than memset: the compiler is forbidden from eliding it.
        _ = memset_s(storage, count, 0, count)
        storage.deallocate()
    }

    /// The pointer is valid only for the duration of `body`. Letting it escape reads
    /// freed memory — the same contract CryptoKit's accessors carry.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try withExtendedLifetime(self) {
            try body(UnsafeRawBufferPointer(start: storage, count: count))
        }
    }

    public func constantTimeEquals(_ other: SecureBytes) -> Bool {
        guard count == other.count else { return false }
        return withUnsafeBytes { lhs in
            other.withUnsafeBytes { rhs in
                var difference: UInt8 = 0
                for index in 0..<count { difference |= lhs[index] ^ rhs[index] }
                return difference == 0
            }
        }
    }
}

// Deliberately absent: CustomStringConvertible, Codable, Equatable, and any mutable
// accessor. A secret that can be interpolated into a string is a secret that reaches a
// log.
