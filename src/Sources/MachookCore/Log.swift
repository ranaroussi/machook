import os

/// os.Logger categories. Everything the app logs goes through here so
/// `log stream --predicate 'subsystem == "com.machook.app"'` shows the
/// whole picture.
public enum Log {
    private static let subsystem = "com.machook.app"

    public static let app     = Logger(subsystem: subsystem, category: "app")
    public static let api     = Logger(subsystem: subsystem, category: "api")
    public static let tunnel  = Logger(subsystem: subsystem, category: "tunnel")
    public static let runner  = Logger(subsystem: subsystem, category: "runner")
    public static let mcp     = Logger(subsystem: subsystem, category: "mcp")
}
