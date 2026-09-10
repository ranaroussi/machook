import Foundation

/// Renders an endpoint's command template into the string handed to the
/// shell.
///
/// v1 supports exactly one placeholder, `{{request}}`, which becomes the
/// path of the request envelope JSON file. The substituted value is one
/// we generated ourselves, and it still goes through `ShellQuote` so the
/// contract stays uniform when field interpolation
/// (`{{request.body.user.id}}`) is added later.
///
/// Any other `{{…}}` is rejected rather than passed through literally.
/// Silently leaving `{{request.body.id}}` in the command would hand the
/// script the literal text `{{request.body.id}}`, which is a miserable
/// thing to debug; failing loudly at save time and at request time is
/// kinder, and turning it into a supported form later is a non-breaking
/// change.
public enum CommandTemplate {
    public enum TemplateError: Error, Equatable, LocalizedError {
        case unsupportedPlaceholder(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedPlaceholder(let name):
                return "Unsupported placeholder {{\(name)}}. Only {{request}} is available."
            }
        }
    }

    /// Matches `{{ anything-without-a-brace }}`, plus one optional
    /// quote character on each side so `"{{request}}"` written out of
    /// habit doesn't end up double-quoted.
    private static let pattern = try! NSRegularExpression(
        pattern: "([\"']?)\\{\\{([^{}]*)\\}\\}([\"']?)"
    )

    /// Placeholder names in `template` that we don't understand.
    /// Used by the Settings UI to flag a bad command before saving.
    public static func unsupportedPlaceholders(in template: String) -> [String] {
        matches(in: template).compactMap { match in
            let name = match.name
            return name == "request" ? nil : name
        }
    }

    public static func referencesRequest(_ template: String) -> Bool {
        matches(in: template).contains { $0.name == "request" }
    }

    /// Substitutes `{{request}}` with the shell-quoted `envelopePath`.
    public static func render(_ template: String, envelopePath: String) throws -> String {
        var out = template
        // Replace back-to-front so earlier ranges stay valid.
        for match in matches(in: template).reversed() {
            guard match.name == "request" else {
                throw TemplateError.unsupportedPlaceholder(match.name)
            }
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: ShellQuote.quote(envelopePath))
        }
        return out
    }

    // MARK: - Internals

    private struct Match {
        let range: NSRange
        let name: String
    }

    private static func matches(in template: String) -> [Match] {
        let ns = template as NSString
        let full = NSRange(location: 0, length: ns.length)
        return pattern.matches(in: template, range: full).map { result in
            let name = ns.substring(with: result.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Only strip surrounding quotes when both sides carry the
            // same character. `"{{request}}"` is the habit we want to
            // absorb; `echo "prefix {{request}}"` must keep its closing
            // quote, or we'd break the user's own string.
            let left  = ns.substring(with: result.range(at: 1))
            let right = ns.substring(with: result.range(at: 3))
            let paired = !left.isEmpty && left == right

            let range = paired
                ? result.range
                : NSRange(
                    location: result.range.location + (left as NSString).length,
                    length: result.range.length - (left as NSString).length - (right as NSString).length
                  )
            return Match(range: range, name: name)
        }
    }
}
