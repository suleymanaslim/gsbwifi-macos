import Foundation

/// A centralized logging utility that writes to both the console and a log file in ~/Library/Logs.
class FileLogger {
    static let shared = FileLogger()
    
    private let fileManager = FileManager.default
    private let logFileURL: URL
    
    init() {
        let logsFolder = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        logFileURL = logsFolder.appendingPathComponent("GSBWiFiManager.log")
        
        // Ensure folder exists
        try? fileManager.createDirectory(at: logsFolder, withIntermediateDirectories: true)
        
        // Start fresh for each session (optional, but requested for easier tracking)
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        
        log("--- GSBWiFi Manager Started ---")
    }
    
    func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        return // Logs disabled by user request
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logLine = "[\(timestamp)] [\(fileName):\(line)] \(function) -> \(message)\n"
        
        // Print to console (Stdout)
        print(logLine, terminator: "")
        
        // Append to file
        if let data = logLine.data(using: .utf8) {
            if fileManager.fileExists(atPath: logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
}

/// Shorthand global log function
func gLog(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    FileLogger.shared.log(message, file: file, function: function, line: line)
}
