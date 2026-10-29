import os

/// Signposts for every pipeline stage, visible in Instruments' Points of Interest.
public enum Signposts {
    public static let subsystem = "com.chriskonstad.lighteditor"
    public static let decode = OSSignposter(subsystem: subsystem, category: "Decode")
    public static let render = OSSignposter(subsystem: subsystem, category: "Render")
    public static let display = OSSignposter(subsystem: subsystem, category: "Display")
    public static let export = OSSignposter(subsystem: subsystem, category: "Export")
    public static let library = OSSignposter(subsystem: subsystem, category: "Library")
}
