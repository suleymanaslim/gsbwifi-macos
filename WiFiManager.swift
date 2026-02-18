import Foundation
import Network
import SystemConfiguration
import CoreWLAN

/// Monitors WiFi connection state and detects GSBWIFI network.
/// Uses NWPathMonitor for real-time network change detection
/// and CoreWLAN for fast SSID retrieval.
@MainActor
final class WiFiManager: ObservableObject {

    // MARK: - Published State

    @Published var isConnectedToTarget = false
    @Published var currentSSID: String?
    @Published var lastSpeedMbps: Double?
    @Published var isCheckingSpeed = false

    // MARK: - Properties

    let targetSSID: String
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let monitorQueue = DispatchQueue(label: "wifi.monitor", qos: .utility)
    private var portalURL: String
    private let wifiClient = CWWiFiClient.shared()

    // MARK: - Init

    init(targetSSID: String = "GSBWIFI", portalURL: String = "https://wifi.gsb.gov.tr") {
        self.targetSSID = targetSSID
        self.portalURL = portalURL
    }

    // MARK: - Monitoring

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if path.status == .satisfied && path.usesInterfaceType(.wifi) {
                    gLog("Network path satisfied (WiFi detected). Checking connection...")
                    await self.checkConnection()
                } else {
                    gLog("Network path not satisfied or not WiFi. Status: \(path.status)")
                    self.isConnectedToTarget = false
                    self.currentSSID = nil
                }
            }
        }
        monitor.start(queue: monitorQueue)

        // Initial check
        Task { await checkConnection() }
    }

    func stopMonitoring() {
        monitor.cancel()
    }

    /// Force a connection re-check.
    func checkConnection() async {
        // Use CoreWLAN for fast SSID detection (non-blocking)
        let ssid = getSSID()
        currentSSID = ssid

        if ssid == targetSSID {
            if !isConnectedToTarget { gLog("Confirmed connection to \(targetSSID)") }
            isConnectedToTarget = true
            return
        }

        // Fallback: portal reachability (macOS Sequoia+ redacts SSID if location denied)
        if await hasWiFiIP() {
            isConnectedToTarget = await isPortalReachable()
        } else {
            isConnectedToTarget = false
        }
    }

    // MARK: - SSID Detection

    /// Get current WiFi SSID using CoreWLAN (fast) and networksetup (fallback).
    private func getSSID() -> String? {
        // Method 1: CoreWLAN (Native & Fast)
        if let interface = wifiClient.interface(), let ssid = interface.ssid() {
            return ssid
        }

        // Method 2: networksetup (Fallback for macOS versions)
        // Run in a separate task to avoid blocking if possible, 
        // but since this is private and getSSID is usually fast, we keep it synchronous-looking.
        for iface in ["en0", "en1"] {
            if let ssid = ssidViaNetworkSetup(interface: iface) {
                return ssid
            }
        }

        return nil
    }

    private func ssidViaNetworkSetup(interface: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getairportnetwork", interface]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let range = output.range(of: "Current Wi-Fi Network: ") {
                let ssid = String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !ssid.isEmpty { return ssid }
            }
        } catch {}
        return nil
    }

    // MARK: - Network Helpers

    private func hasWiFiIP() async -> Bool {
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
            process.arguments = ["getifaddr", "en0"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return process.terminationStatus == 0 && !output.isEmpty
            } catch {
                return false
            }
        }.value
    }

    /// Check if the captive portal is reachable on the local network.
    private func isPortalReachable() async -> Bool {
        guard let url = URL(string: "\(portalURL)/login.html") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        req.setValue("GSBWiFi-Check/1.0", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        let delegate = InsecureSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        do {
            let (_, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            gLog("Portal reachability check returned HTTP \(status)")
            return [200, 301, 302, 303, 307, 308].contains(status)
        } catch {
            gLog("Portal reachability check failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Speed Test

    /// Measure download speed in Mbps.
    func measureSpeed() async {
        isCheckingSpeed = true
        defer { isCheckingSpeed = false }

        let testURL = URL(string: "http://speedtest.tele2.net/1MB.zip")!
        var request = URLRequest(url: testURL)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        let startTime = Date()
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 0 {
                let speedMbps = Double(data.count * 8) / (elapsed * 1_000_000)
                lastSpeedMbps = (speedMbps * 100).rounded() / 100  // 2 decimal places
            }
        } catch {
            lastSpeedMbps = nil
        }
    }
}
