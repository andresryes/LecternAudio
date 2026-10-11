import Foundation
import Testing
@testable import AudibleCore

@Test func decodesOpenAudibleBooksJSON() throws {
    let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let lib = try OpenAudibleLibrary(root: root)
    #expect(lib.books.count == 3)

    let book = try #require(lib.books.first { $0.title == "21 Lessons for the 21st Century" })
    #expect(book.seconds > 0)
    #expect(book.rating != nil)
    #expect(!book.chapters.isEmpty)
    #expect(book.hasAudio)
    #expect(lib.audioURL(for: book)?.path.hasSuffix("books/21 Lessons for the 21st Century.m4b") == true)
    #expect(lib.artURL(for: book)?.path.contains("/art/") == true)

    let first = lib.books[0]
    #expect(first.primaryGenre == "Business & Careers")
    #expect(!first.hasAudio)
}
