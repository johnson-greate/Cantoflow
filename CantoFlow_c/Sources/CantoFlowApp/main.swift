import AppKit

// Parse CLI arguments
let config = AppConfig.fromArgs()

// Create and configure the application
let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate

// Run the application
app.run()
