import Foundation

/// HTTP client for the GSBWIFI captive portal (wifi.gsb.gov.tr).
/// Handles login, logout, status check, and quota parsing.
/// Uses URLSession with a custom delegate to bypass SSL verification
/// (the captive portal uses a self-signed certificate).
actor PortalClient {

    // MARK: - Types

    struct LoginResult {
        var success = false
        var message = ""
        var needsTermination = false
        var conflictHTML: String? = nil
        var quota = QuotaInfo()
    }

    struct LogoutResult {
        var success = false
        var message = ""
    }

    struct StatusResult {
        var loggedIn = false
        var quota = QuotaInfo()
        var message = ""
    }

    struct QuotaInfo {
        var totalMB: Double?
        var remainingMB: Double?
        var sessionTime: String?
        var loginTime: String?
        var remainingTime: String?
        var location: String?
    }

    // MARK: - Properties

    private let portalURL: String
    private let username: String
    private let password: String
    private let session: URLSession
    private var loggedIn = false
    private var currentQuota = QuotaInfo()
    private var viewState: String?
    private var cookies: [HTTPCookie] = []

    // MARK: - Init

    init(portalURL: String, username: String, password: String) {
        self.portalURL = portalURL.hasSuffix("/") ? String(portalURL.dropLast()) : portalURL
        self.username = username
        self.password = password

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "tr-TR,tr;q=0.9,en;q=0.8",
        ]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30

        let delegate = InsecureSessionDelegate()
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Public API

    var isLoggedIn: Bool { loggedIn }
    var quotaInfo: QuotaInfo { currentQuota }

    /// Login to the captive portal.
    /// Flow: GET /login.html → POST /j_spring_security_check → check dashboard
    func login() async -> LoginResult {
        var result = LoginResult()

        do {
            // Step 1: GET login page to establish session cookies
            log("Login Step 1: GET /login.html...")
            if let loginURL = URL(string: "\(portalURL)/login.html") {
                let req = URLRequest(url: loginURL)
                let _ = try? await session.data(for: req)
            }

            // Step 2: POST credentials
            let loginURL = "\(portalURL)/j_spring_security_check"
            log("Login Step 2: POST \(loginURL)")

            var request = URLRequest(url: URL(string: loginURL)!)
            request.httpMethod = "POST"
            let body = "j_username=\(urlEncode(username))&j_password=\(urlEncode(password))&submit=Giri%C5%9F"
            request.httpBody = body.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let (data, response) = try await session.data(for: request)
            let httpResp = response as? HTTPURLResponse
            let pageText = String(data: data, encoding: .utf8) ?? ""
            let finalURL = httpResp?.url?.absoluteString ?? ""

            log("Login Step 2 response: status=\(httpResp?.statusCode ?? 0), url=\(finalURL), len=\(pageText.count)")

            // Check for login error via URL redirect
            if finalURL.contains("login_error") || finalURL.contains("error=true") || finalURL.hasSuffix("login.html?error") {
                result.message = "Kullanıcı adı veya şifre hatalı!"
                return result
            }

            // Check if Step 2 already redirected to device limit page
            let step2Lower = pageText.lowercased()
            if finalURL.contains("maksimumCihazHakkiDolu.html") || step2Lower.contains("maksimum giriş sayısına ulaştınız") {
                gLog("Maximum device limit detected at Step 2 (URL: \(finalURL))")
                result.needsTermination = true
                result.conflictHTML = pageText
                result.message = "Maksimum cihaz sınırına ulaşıldı."
                return result
            }

            // Check if we landed on dashboard
            if isDashboard(pageText) {
                log("Landed on dashboard directly!")
                loggedIn = true
                result.success = true
                result.message = "Giriş başarılı!"
                result.quota = parseQuota(from: pageText)
                currentQuota = result.quota
                viewState = extractViewState(from: pageText)
                return result
            }

            // Step 3: Try GET /index.html
            log("Login Step 3: GET /index.html...")
            let (data3, response3) = try await session.data(for: URLRequest(url: URL(string: "\(portalURL)/index.html")!))
            let pageText3 = String(data: data3, encoding: .utf8) ?? ""
            let finalURL3 = (response3 as? HTTPURLResponse)?.url?.absoluteString ?? ""

            if isDashboard(pageText3) {
                log("Dashboard loaded via /index.html!")
                loggedIn = true
                result.success = true
                result.message = "Giriş başarılı!"
                result.quota = parseQuota(from: pageText3)
                currentQuota = result.quota
                viewState = extractViewState(from: pageText3)
                return result
            }

            // Check if still on login page or redirected to "Maximum Device Limit"
            let pageLower = pageText3.lowercased()
            if finalURL3.contains("maksimumCihazHakkiDolu.html") || pageLower.contains("maksimum giriş sayısına ulaştınız") {
                gLog("Maximum device limit detected, requiring manual termination (URL: \(finalURL3))")
                result.needsTermination = true
                result.conflictHTML = pageText3
                result.message = "Maksimum cihaz sınırına ulaşıldı."
                return result
            }

            if finalURL3.contains("login.html") || pageLower.contains("j_username") {
                if pageLower.contains("aktif") || pageLower.contains("başka") || pageLower.contains("sonlandır") {
                    log("Session conflict detected, attempting termination...")
                    result.needsTermination = true
                    if await terminateAndRetry() {
                        result.success = true
                        result.needsTermination = false
                        result.message = "Diğer oturum sonlandırıldı, giriş yapıldı."
                        result.quota = currentQuota
                    } else {
                        result.message = "Diğer oturum sonlandırılamadı."
                    }
                } else {
                    result.message = "Giriş yapılamadı (login sayfasında kaldı)."
                }
                return result
            }

            result.message = "Giriş durumu belirsiz."

        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .notConnectedToInternet {
            result.message = "Portal'a bağlanılamıyor. GSBWIFI'ye bağlı mısınız?"
        } catch let error as URLError where error.code == .timedOut {
            gLog("Login timed out: \(error.localizedDescription)")
            result.message = "Portal zaman aşımına uğradı."
        } catch {
            gLog("Login error: \(error.localizedDescription)")
            result.message = "Hata: \(error.localizedDescription)"
        }

        return result
    }

    /// Logout from the captive portal.
    func logout() async -> LogoutResult {
        var result = LogoutResult()

        do {
            log("Logging out...")

            // Hit logout URL
            let logoutURL = "\(portalURL)/cikisSon.html?logout=1"
            let _ = try await session.data(for: URLRequest(url: URL(string: logoutURL)!))

            // Clear state
            if let storage = session.configuration.httpCookieStorage {
                storage.cookies?.forEach { storage.deleteCookie($0) }
            }
            loggedIn = false
            viewState = nil
            result.success = true
            result.message = "Oturum sonlandırıldı."

        } catch {
            result.message = "Çıkış hatası: \(error.localizedDescription)"
        }

        return result
    }

    /// Check current session status and quota.
    func getStatus() async -> StatusResult {
        var result = StatusResult()

        do {
            log("Checking session status...")
            let (data, _) = try await session.data(for: URLRequest(url: URL(string: "\(portalURL)/index.html")!))
            let pageText = String(data: data, encoding: .utf8) ?? ""

            if isDashboard(pageText) {
                result.loggedIn = true
                result.quota = parseQuota(from: pageText)
                currentQuota = result.quota
                loggedIn = true
                viewState = extractViewState(from: pageText)
                log("Session is active.")
            } else {
                loggedIn = false
                result.message = "Oturum açık değil."
            }

        } catch {
            result.message = "Durum sorgulanamadı: \(error.localizedDescription)"
        }

        return result
    }

    /// Check if we have real internet access (bypass captive portal).
    func checkInternet() async -> Bool {
        do {
            var req = URLRequest(url: URL(string: "http://clients3.google.com/generate_204")!)
            req.timeoutInterval = 5
            // Prevent following redirects for this check
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 204
        } catch {
            return false
        }
    }

    // MARK: - Private: Dashboard Detection

    private func isDashboard(_ html: String) -> Bool {
        let indicators = [
            "mainPanel", "servisUpdateForm", "Oturum Süresi",
            "Kota bilgileri", "Toplam Kota", "Internet Servisi",
            "Oturumu Sonlandır",
        ]
        let lower = html.lowercased()
        return indicators.contains { lower.contains($0.lowercased()) }
    }

    // MARK: - Private: Quota Parsing

    private func parseQuota(from html: String) -> QuotaInfo {
        var quota = QuotaInfo()
        // Strip HTML tags for text-based parsing
        let text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        let patterns: [(key: WritableKeyPath<QuotaInfo, String?>, pattern: String)] = [
            (\.loginTime, #"Login Zaman[ıi][\s:]*(.+?)(?:\n|$)"#),
            (\.sessionTime, #"Oturum S[üu]resi[\s:]*(.+?)(?:\n|$)"#),
            (\.remainingTime, #"Kalan Kota Zaman[ıi][\s:]*(.+?)(?:\n|$)"#),
            (\.location, #"Konum\s*:\s*(.+?)(?:\n|$)"#),
        ]

        // Numeric patterns
        if let match = text.range(of: #"Toplam Kota \(MB\)[\s:]*([0-9.]+)"#, options: .regularExpression) {
            let captured = extractFirstGroup(from: text, range: match, pattern: #"Toplam Kota \(MB\)[\s:]*([0-9.]+)"#)
            quota.totalMB = Double(captured ?? "")
        }
        if let match = text.range(of: #"Toplam Kalan Kota \(MB\)[\s:]*([0-9.]+)"#, options: .regularExpression) {
            let captured = extractFirstGroup(from: text, range: match, pattern: #"Toplam Kalan Kota \(MB\)[\s:]*([0-9.]+)"#)
            quota.remainingMB = Double(captured ?? "")
        }

        // String patterns
        for item in patterns {
            if let captured = regexFirstGroup(in: text, pattern: item.pattern) {
                quota[keyPath: item.key] = captured.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        log("Quota: total=\(quota.totalMB ?? 0)MB, remaining=\(quota.remainingMB ?? 0)MB, time=\(quota.remainingTime ?? "?")")
        return quota
    }

    // MARK: - Private: ViewState

    private func extractViewState(from html: String) -> String? {
        // Try partial-response CDATA format
        if let vs = regexFirstGroup(in: html, pattern: #"javax\.faces\.ViewState[^>]*>\s*<!\[CDATA\[\s*([^\]]+?)\s*\]\]>"#) {
            return vs
        }
        // Try hidden input
        if let vs = regexFirstGroup(in: html, pattern: #"name="javax\.faces\.ViewState"[^>]*value="([^"]+)""#) {
            return vs
        }
        return nil
    }

    // MARK: - Private: Session Termination

    /// Handles the "Maximum Device Limit Reached" page by terminating ALL active sessions.
    /// Uses PrimeFaces ConfirmDialog bypass — simulates PrimeFaces.ab({s:buttonId, u:"@all"}).
    func handleMaximumDeviceLimit(html: String) async -> Bool {
        gLog("Session termination requested...")
        
        var currentHTML = html
        var vs = extractViewState(from: html)
        var terminatedCount = 0
        let maxAttempts = 5
        var clickedButtons = Set<String>()
        
        for attempt in 0..<maxAttempts {
            gLog("--- Termination attempt \(attempt + 1) ---")
            
            guard let currentVS = vs else {
                gLog("No ViewState found — stopping.")
                break
            }
            
            // Find termination button (language-agnostic)
            // Priority: Terminate (Step 1) -> Confirm (Step 2)
            // We use a blacklist to avoid clicking the same button 5 times if it fails to transition the state.
            let patterns: [(String, String)] = [
                ("End",                #"<button[^>]*id="([^"]+)"[^>]*><span[^>]*>End"#),
                ("PrimeFaces.confirm", #"<button[^>]*id="([^"]+)"[^>]*onclick="PrimeFaces\.confirm"#),
                ("Sonlandır",          #"id="([^"]+)"[^>]*><span[^>]*>Sonland[ıi]r"#),
                ("Terminate",          #"id="([^"]+)"[^>]*><span[^>]*>Terminate"#),
                ("End Session",        #"id="([^"]+)"[^>]*><span[^>]*>End Session"#),
                ("OK button",          #"<button[^>]*id="(j_idt[^"]+)"[^>]*><span[^>]*>OK"#),
                ("Tamam",              #"<button[^>]*id="([^"]+)"[^>]*><span[^>]*>Tamam"#),
                ("Evet",               #"<button[^>]*id="([^"]+)"[^>]*><span[^>]*>Evet"#),
                ("ConfirmDialog Yes",  #"<button[^>]*id="([^"]+)"[^>]*class="[^"]*ui-confirmdialog-yes"#),
            ]
            
            var btnId: String? = nil
            var btnLabel: String = "Unknown"
            
            for (label, pat) in patterns {
                if let m = regexFirstGroup(in: currentHTML, pattern: pat) {
                    if clickedButtons.contains(m) {
                        gLog("Skipping already clicked button: \(m) (\(label))")
                        continue
                    }
                    gLog("Found Button '\(label)': \(m)")
                    btnId = m
                    btnLabel = label
                    break
                }
            }
            
            // Fallback for generic confirm command if regex didn't match typical buttons
            if btnId == nil {
                if let s = regexFirstGroup(in: currentHTML, pattern: #"PrimeFaces\.ab\(\{s:&quot;([^&]+)&quot;"#) {
                    if !clickedButtons.contains(s) {
                        gLog("Button via pfconfirmcommand: \(s)")
                        btnId = s
                        btnLabel = "PFCommand"
                    }
                }
            }
            
            guard let btnId else {
                gLog(terminatedCount > 0 ? "No more clickable buttons after \(terminatedCount) attempts. ✅" : "ERROR: No button found.")
                break
            }
            
            clickedButtons.insert(btnId)
            let formId = btnId.components(separatedBy: ":").first ?? btnId
            gLog("POST: button=\(btnId), form=\(formId)")
            
            var req = URLRequest(url: URL(string: "\(portalURL)/maksimumCihazHakkiDolu.html")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.setValue("partial/ajax", forHTTPHeaderField: "Faces-Request")
            req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            req.setValue("\(portalURL)/maksimumCihazHakkiDolu.html", forHTTPHeaderField: "Referer")
            
            let params: [String: String] = [
                "javax.faces.partial.ajax": "true",
                "javax.faces.source": btnId,
                "javax.faces.partial.execute": "@all",
                "javax.faces.partial.render": "@all",
                "javax.faces.behavior.event": "action",
                formId: formId,
                btnId: btnId,
                "javax.faces.ViewState": currentVS
            ]
            let body = params.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&")
            req.httpBody = body.data(using: .utf8)
            
            do {
                let (data, _) = try await session.data(for: req)
                let respText = String(data: data, encoding: .utf8) ?? ""
                gLog("Response len=\(respText.count)")
                terminatedCount += 1

                 // Update ViewState from the full XML response (crucial for multi-step flows)
                if let newVS = extractViewState(from: respText) {
                    vs = newVS
                    gLog("Updated ViewState found.")
                }
                
                // Extract updated page from CDATA in partial-response
                if let cdata = regexFirstGroup(in: respText, pattern: #"CDATA\[([\s\S]*?)\]\]"#) {
                    gLog("Updated HTML from CDATA (\(cdata.count) chars)")
                    currentHTML = cdata
                    
                    // Allow clicking 'Confirm' buttons even if they appeared before, 
                    // because the DOM update might have made them valid/visible/active?
                    // Actually, if we are in a loop, we should keep the blacklist to FORCE trying the next button.
                    // But if the page REFRESHED completely, maybe we should clear blacklist?
                    // Let's keep strict blacklist for this 'attempt' loop to force progression.
                    
                } else if respText.contains("redirect") {
                    gLog("✅ Redirect — sessions cleared!")
                    break
                } else {
                    gLog("⚠️ No CDATA or redirect found. Response start: \(String(respText.prefix(500)))")
                    currentHTML = respText
                }
                
                // Simple check: Did the "Confirm" dialog appear?
                if currentHTML.contains("ui-confirmdialog-yes") && !btnLabel.contains("Confirm") {
                     gLog("Confirm dialog detected.")
                }
                
                gLog("Waiting 1s for server...")
                try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
            } catch {
                gLog("Request failed: \(error.localizedDescription)")
                return false
            }
        }
        
        if terminatedCount > 0 {
            gLog("Terminated \(terminatedCount) step(s). Clearing cookies + logout...")
            
            // Clear cookies for clean re-login
            if let storage = session.configuration.httpCookieStorage,
               let host = URL(string: portalURL)?.host {
                storage.cookies?.filter { $0.domain.contains(host) || host.contains($0.domain) }
                    .forEach { storage.deleteCookie($0) }
            }
            
            // Hit logout endpoint for server-side cleanup
            let _ = try? await session.data(for: URLRequest(url: URL(string: "\(portalURL)/cikisSon.html?logout=1")!))
            gLog("Cookie clear + logout done. Ready for fresh login.")
            return true
        }
        
        return false
    }

    private func terminateAndRetry() async -> Bool {
        do {
            // Logout to clear session
            let _ = try await session.data(for: URLRequest(url: URL(string: "\(portalURL)/cikisSon.html?logout=1")!))

            // Retry login
            var request = URLRequest(url: URL(string: "\(portalURL)/j_spring_security_check")!)
            request.httpMethod = "POST"
            let body = "j_username=\(urlEncode(username))&j_password=\(urlEncode(password))&submit=Giri%C5%9F"
            request.httpBody = body.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let (data, _) = try await session.data(for: request)
            let pageText = String(data: data, encoding: .utf8) ?? ""

            if isDashboard(pageText) {
                loggedIn = true
                currentQuota = parseQuota(from: pageText)
                viewState = extractViewState(from: pageText)
                return true
            }

            // Try /index.html
            let (data2, _) = try await session.data(for: URLRequest(url: URL(string: "\(portalURL)/index.html")!))
            let pageText2 = String(data: data2, encoding: .utf8) ?? ""

            if isDashboard(pageText2) {
                loggedIn = true
                currentQuota = parseQuota(from: pageText2)
                viewState = extractViewState(from: pageText2)
                return true
            }
        } catch {}
        return false
    }

    // MARK: - Helpers

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

    private func regexFirstGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange) else { return nil }
        guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func extractFirstGroup(from text: String, range: Range<String.Index>, pattern: String) -> String? {
        regexFirstGroup(in: text, pattern: pattern)
    }

    private func log(_ msg: String) {
        gLog(msg)
    }
}

// MARK: - SSL Bypass Delegate

/// URLSession delegate that accepts any SSL certificate.
/// Required for the self-signed captive portal certificate.
final class InsecureSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
