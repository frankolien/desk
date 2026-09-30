import Foundation
import Testing

@testable import DeskPerpl

@Suite("Order book")
struct OrderBookTests {
    private func frame(_ json: String) throws -> OrderBook.Frame {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try #require(OrderBook.Frame(json: object))
    }

    @Test("A snapshot sets both sides, best first, with the spread between them")
    func snapshot() throws {
        var book = OrderBook()
        book.apply(try frame(#"{"mt":15,"sid":4,"bid":[{"p":1000,"s":5,"o":1},{"p":1010,"s":2,"o":2}],"ask":[{"p":1030,"s":1,"o":1},{"p":1020,"s":"3","o":1}]}"#))
        #expect(book.isReady)
        #expect(book.levels(.bid, depth: 5).map(\.priceRaw) == [1010, 1000])
        #expect(book.levels(.ask, depth: 5).map(\.priceRaw) == [1020, 1030])
        #expect(book.spreadRaw == 10)
        #expect(book.levels(.ask, depth: 1).first?.sizeRaw == 3)
    }

    @Test("An update patches levels and o: 0 removes one")
    func update() throws {
        var book = OrderBook()
        book.apply(try frame(#"{"mt":15,"bid":[{"p":1000,"s":5,"o":1}],"ask":[{"p":1020,"s":3,"o":1}]}"#))
        book.apply(try frame(#"{"mt":16,"bid":[{"p":1000,"s":7,"o":2},{"p":1015,"s":1,"o":1}],"ask":[{"p":1020,"s":0,"o":0}]}"#))
        #expect(book.levels(.bid, depth: 5).map(\.priceRaw) == [1015, 1000])
        #expect(book.levels(.bid, depth: 5).last?.sizeRaw == 7)
        #expect(book.levels(.ask, depth: 5).isEmpty)
        #expect(book.spreadRaw == nil)
    }

    @Test("Updates before a snapshot are ignored, and a new snapshot replaces the book")
    func ordering() throws {
        var book = OrderBook()
        #expect(book.apply(try frame(#"{"mt":16,"bid":[{"p":1,"s":1,"o":1}],"ask":[]}"#)) == false)
        #expect(book.levels(.bid, depth: 5).isEmpty)
        book.apply(try frame(#"{"mt":15,"bid":[{"p":5,"s":1,"o":1}],"ask":[]}"#))
        book.apply(try frame(#"{"mt":15,"bid":[{"p":6,"s":1,"o":1}],"ask":[]}"#))
        #expect(book.levels(.bid, depth: 5).map(\.priceRaw) == [6])
    }

    @Test("Depth caps each side and other frames are not book frames")
    func depthAndOthers() throws {
        var book = OrderBook()
        let bids = (1...30).map { #"{"p":\#($0),"s":1,"o":1}"# }.joined(separator: ",")
        book.apply(try frame(#"{"mt":15,"bid":[\#(bids)],"ask":[]}"#))
        #expect(book.levels(.bid, depth: 8).count == 8)
        #expect(book.levels(.bid, depth: 8).first?.priceRaw == 30)
        #expect(OrderBook.Frame(json: ["mt": 9, "d": [:]]) == nil)
    }
}
