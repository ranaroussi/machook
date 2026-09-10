import Foundation

/// POSIX shell quoting for values spliced into a command template.
///
/// This is the security boundary of the whole app. The command template
/// comes from the Settings window (trusted, local). Everything else —
/// the envelope file path today, request fields when field interpolation
/// lands — passes through `quote(_:)` first, so a caller sending
/// `; rm -rf ~` produces one inert argv element instead of a second
/// command.
///
/// Single-quote wrapping with `'` → `'\''` is a complete POSIX escape:
/// inside single quotes the shell interprets nothing at all, and the
/// `'\''` dance closes the quote, emits an escaped literal quote, and
/// reopens it.
public enum ShellQuote {
    /// Characters that are inert in every position in sh/bash/zsh, so a
    /// value made only of these can skip quoting for readability in logs.
    /// Deliberately conservative: `=` is excluded because zsh performs
    /// `=command` expansion on a leading equals, and `~` because of tilde
    /// expansion.
    private static let inert = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./")

    public static func quote(_ raw: String) -> String {
        if raw.isEmpty { return "''" }
        if raw.allSatisfy({ inert.contains($0) }) { return raw }
        return "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
