import Foundation

/// Which books the library-wide actions apply to (Controls ▸ Download All From Audible,
/// Convert All to M4B). Pure so the app can both count them when the library changes and build the
/// work list when the menu item is chosen, from one rule.
public enum LibraryJobs {
    /// Books this account owns that have no playable audio yet.
    ///
    /// `owned` is the ASINs of the synced Audible catalog: a book only in the local folder cannot be
    /// downloaded, however little audio it has.
    public static func downloadable(_ books: [Book], owned: Set<String>) -> [Book] {
        books.filter { !$0.asin.isEmpty && !$0.hasAudio && owned.contains($0.asin) }
    }

    /// Books with an encrypted file and no playable audio that this account can activate, so the
    /// conversion never stops to ask for activation bytes. The caller additionally requires the AAX
    /// to resolve to a readable path inside the library folder.
    public static func convertible(_ books: [Book], owned: Set<String>) -> [Book] {
        books.filter { $0.hasEncrypted && !$0.hasAudio && !$0.asin.isEmpty && owned.contains($0.asin) }
    }
}
