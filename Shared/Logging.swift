import os

extension Logger {
    /// A logger for one part of the app, under the app's subsystem.
    init(category: String) { self.init(subsystem: "com.owais.OwlLuna", category: category) }
}

extension OSSignposter {
    /// A signposter for one part of the app, under the app's subsystem.
    init(category: String) { self.init(subsystem: "com.owais.OwlLuna", category: category) }
}
