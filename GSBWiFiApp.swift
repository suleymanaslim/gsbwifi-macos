import SwiftUI
import UserNotifications
import AppKit

// MARK: - Models

struct Account: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var username: String
    var password: String
    var isSelected: Bool = false
}

final class AccountManager: ObservableObject {
    @Published var accounts: [Account] = [] {
        didSet { save() }
    }
    
    static let shared = AccountManager()
    private let key = "gsb_accounts"

    init() {
        load()
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = decoded
        }
    }

    func save() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    var selectedAccount: Account? {
        accounts.first(where: { $0.isSelected })
    }

    func select(account: Account) {
        for i in 0..<accounts.count {
            accounts[i].isSelected = (accounts[i].id == account.id)
        }
        objectWillChange.send()
    }

    func add(account: Account) {
        var newAccount = account
        if accounts.isEmpty { newAccount.isSelected = true }
        accounts.append(newAccount)
    }

    func remove(account: Account) {
        accounts.removeAll(where: { $0.id == account.id })
        if let first = accounts.first, selectedAccount == nil {
            select(account: first)
        }
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    enum ConnectionStatus: String {
        case idle = "Bekleniyor"
        case connecting = "Bağlanıyor..."
        case connected = "İnternet Aktif"
        case disconnected = "Bağlı Değil"
        case loggingIn = "Giriş Yapılıyor..."
        case sessionConflict = "Cihaz Sınırı!"
        case error = "Bağlantı Hatası"
    }

    @Published var status: ConnectionStatus = .idle
    @Published var statusMessage = ""
    @Published var networkName = "—"
    @Published var totalQuota: Double = 0
    @Published var remainingQuota: Double = 0
    @Published var quotaText = "—"
    @Published var speedText = "—"
    @Published var lastSpeed: Double? = nil
    @Published var remainingTimeText = "—"
    @Published var autoLoginEnabled = true
    @Published var isLoggingIn = false
    @Published var menuBarTitle = "GSB"
    @Published var quotaPercentage: Double = 0
    @Published var showAccountManager = false
    @Published var conflictHTML: String? = nil
    private var isShowingConflictAlert = false

    @ObservedObject var accountManager = AccountManager.shared
    var portal: PortalClient?
    let wifi: WiFiManager
    
    private let portalURL = "https://wifi.gsb.gov.tr"
    private var wasConnected = false
    private var checkTimer: Timer?
    private var lastSpeedCheck: Date = .distantPast
    private var lastLoginAttempt: Date = .distantPast

    init() {
        self.wifi = WiFiManager(targetSSID: "GSBWIFI", portalURL: portalURL)
        updatePortal()
    }

    func updatePortal() {
        if let acc = accountManager.selectedAccount {
            self.portal = PortalClient(portalURL: portalURL, username: acc.username, password: acc.password)
        } else {
            self.portal = nil
        }
    }

    func start() {
        wifi.startMonitoring()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.onTimerTick()
            }
        }
        Task { await onTimerTick() }
    }

    func stop() {
        wifi.stopMonitoring()
        checkTimer?.invalidate()
    }

    // MARK: - Timer

    private func onTimerTick() async {
        await wifi.checkConnection()

        let ssid = wifi.currentSSID
        let isConnected = wifi.isConnectedToTarget

        if let ssid {
            networkName = ssid
        } else if isConnected {
            networkName = "GSBWIFI (Algılandı)"
        } else {
            networkName = "Bağlı Değil"
        }

        let shouldRetryAutoLogin = autoLoginEnabled && !isLoggingIn && (status == .disconnected || status == .sessionConflict || status == .error) && Date().timeIntervalSince(lastLoginAttempt) >= 10

        if isConnected && !wasConnected {
            setStatus(.connecting, message: "GSBWIFI Algılandı")
            if autoLoginEnabled && !isLoggingIn {
                lastLoginAttempt = Date()
                await performLogin()
            }
        } else if isConnected && shouldRetryAutoLogin {
            gLog("Auto-login retry triggered (10s interval)...")
            lastLoginAttempt = Date()
            await performLogin()
        } else if !isConnected && wasConnected {
            setStatus(.disconnected, message: "Bağlantı koptu")
            resetQuota()
        }

        wasConnected = isConnected

        if isConnected && Date().timeIntervalSince(lastSpeedCheck) >= 240 {
            lastSpeedCheck = Date()
            await performSpeedTest()
        }
    }

    private func resetQuota() {
        quotaText = "—"
        speedText = "—"
        remainingTimeText = "—"
        quotaPercentage = 0
        totalQuota = 0
        remainingQuota = 0
    }

    // MARK: - Actions

    func performLogin() async {
        guard let portal else {
            setStatus(.error, message: "Hesap seçilmedi")
            return
        }
        guard !isLoggingIn else { return }
        isLoggingIn = true
        setStatus(.loggingIn, message: "Giriş denemesi...")

        let hasInternet = await portal.checkInternet()
        if hasInternet {
            let status = await portal.getStatus()
            if status.loggedIn {
                setStatus(.connected, message: "Oturum aktif")
                formatQuota(status.quota)
                isLoggingIn = false
                return
            }
        }

        let result = await portal.login()

        if result.success {
            setStatus(.connected, message: result.message)
            formatQuota(result.quota)
            sendNotification(title: "Giriş Başarılı", body: "İnternet bağlantınız hazır.")
        } else if result.needsTermination {
            conflictHTML = result.conflictHTML
            setStatus(.sessionConflict, message: "Lütfen diğer cihazınızdan çıkış yapın.")
            sendNotification(title: "Cihaz Sınırı!", body: "Çıkış yapmadan autologin kullanamazsınız.")
        } else {
            setStatus(.error, message: result.message)
            sendNotification(title: "Giriş Hatası", body: result.message)
        }

        lastLoginAttempt = Date()
        isLoggingIn = false
    }

    func performTermination() async {
        guard let portal, let html = conflictHTML else { return }
        setStatus(.loggingIn, message: "Oturum sonlandırılıyor...")
        
        let success = await portal.handleMaximumDeviceLimit(html: html)
        if success {
            conflictHTML = nil
            gLog("Termination complete. Re-logging in...")
            sendNotification(title: "Oturum Sonlandırıldı", body: "Lütfen bekleyin, giriş yapılıyor...")
            await performLogin()
        } else {
            setStatus(.error, message: "Oturum sonlandırılamadı.")
        }
    }

    func performLogout() async {
        guard let portal else { return }
        setStatus(.idle, message: "Çıkış yapılıyor...")
        let result = await portal.logout()
        if result.success {
            setStatus(.disconnected, message: "Oturum sonlandırıldı")
            resetQuota()
            sendNotification(title: "Çıkış Yapıldı", body: "Oturumunuz sonlandırıldı.")
        } else {
            setStatus(.error, message: result.message)
        }
    }

    func performRefresh() async {
        guard let portal else { return }
        setStatus(.idle, message: "Güncelleniyor...")
        let portalStatus = await portal.getStatus()
        if portalStatus.loggedIn {
            setStatus(.connected, message: "Bilgiler güncellendi")
            formatQuota(portalStatus.quota)
        } else {
            setStatus(.disconnected, message: "Oturum kapalı")
        }
    }

    func performSpeedTest() async {
        speedText = "..."
        await wifi.measureSpeed()
        if let speed = wifi.lastSpeedMbps {
            lastSpeed = speed
            speedText = String(format: "%.1f Mbps", speed)
        } else {
            speedText = "Hata"
        }
    }

    func openSharingPrefs() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.sharing?Internet%20Sharing") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    private func setStatus(_ s: ConnectionStatus, message: String) {
        status = s
        statusMessage = message
        switch s {
        case .connected: menuBarTitle = "GSB ✓"
        case .loggingIn, .connecting: menuBarTitle = "GSB …"
        case .sessionConflict: menuBarTitle = "GSB ⚠️"
        case .error: menuBarTitle = "GSB ✗"
        default: menuBarTitle = "GSB"
        }
    }

    private func formatQuota(_ quota: PortalClient.QuotaInfo) {
        if let remaining = quota.remainingMB, let total = quota.totalMB, total > 0 {
            totalQuota = total
            remainingQuota = remaining
            let rGB = remaining / 1024
            let tGB = total / 1024
            quotaPercentage = (remaining / total)
            quotaText = String(format: "%.1f / %.1f GB", rGB, tGB)
        } else if let remaining = quota.remainingMB {
            remainingQuota = remaining
            quotaText = "\(Int(remaining)) MB kaldı"
            quotaPercentage = 0
        }

        if let time = quota.remainingTime {
            remainingTimeText = time
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - SwiftUI App

@main
struct GSBWiFiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(state: appState)
                .frame(width: 280) // Increased width for better layout
                .onAppear {
                    appState.start()
                }
        } label: {
            Text(appState.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

// MARK: - Menu Content View

struct MenuContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if state.showAccountManager {
                AccountSettingsView(state: state)
            } else {
                ModernMainView(state: state)
            }
        }
        .background(VisualEffectView().ignoresSafeArea())
    }
}

// MARK: - Modern Main View

struct ModernMainView: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        VStack(spacing: 16) {
            // Top Section: Status & Account
            VStack(spacing: 12) {
                ModernStatusHeader(state: state)
                
                Divider().opacity(0.5)
                
                AccountSelector(state: state)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            
            // Middle Section: Data & Info
            if state.status == .connected || state.remainingQuota > 0 {
                VStack(spacing: 12) {
                    QuotaProgressBar(percentage: state.quotaPercentage, text: state.quotaText)
                    
                    ModernInfoGrid(state: state)
                }
                .padding(.horizontal, 16)
            }
            
            // Bottom Section: Actions
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                
                HStack(spacing: 12) {
                    ActionButtonBlock(state: state)
                    
                    Button(action: { Task { await state.performRefresh() } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Yenile")
                }
                .padding(16)
                
                Divider().opacity(0.5)
                
                BottomSettingsBar(state: state)
            }
        }
    }
}

// MARK: - Modern Components

struct ModernStatusHeader: View {
    @ObservedObject var state: AppState
    
    var statusColor: Color {
        switch state.status {
        case .connected: return .green
        case .sessionConflict: return .yellow
        case .error: return .red
        case .loggingIn, .connecting: return .orange
        case .disconnected, .idle: return .gray
        }
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Pulsating Indicator
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 24, height: 24)
                    .scaleEffect(shouldPulse ? 1.5 : 1.0)
                    .opacity(shouldPulse ? 0.0 : 1.0)
                    .animation(Animation.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: shouldPulse)
                
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: statusColor.opacity(0.4), radius: 4, x: 0, y: 0)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(state.status.rawValue)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                
                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
        }
    }
    
    var shouldPulse: Bool {
        state.status == .loggingIn || state.status == .connecting || state.status == .sessionConflict
    }
}

struct AccountSelector: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            
            if let acc = state.accountManager.selectedAccount {
                Text(acc.name)
                    .font(.system(size: 13, weight: .medium))
            } else {
                Text("Hesap Seçilmedi")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button("Değiştir") {
                withAnimation { state.showAccountManager = true }
            }
            .buttonStyle(.link)
            .font(.system(size: 11, weight: .medium))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04))
        .clipShape(Capsule())
    }
}

struct QuotaProgressBar: View {
    var percentage: Double
    var text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Kalan Kota")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(text)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                    
                    Capsule()
                        .fill(LinearGradient(gradient: Gradient(colors: [.blue, .cyan]), startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(percentage))))
                        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: percentage)
                }
            }
            .frame(height: 6)
        }
    }
}

struct ModernInfoGrid: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        HStack(spacing: 0) {
            InfoItem(icon: "wifi", label: "Ağ", value: state.networkName)
            Divider().frame(height: 20).padding(.horizontal, 8)
            InfoItem(icon: "clock", label: "Süre", value: state.remainingTimeText)
            Divider().frame(height: 20).padding(.horizontal, 8)
            InfoItem(icon: "speedometer", label: "Hız", value: state.speedText)
        }
        .padding(.top, 4)
    }
}

struct InfoItem: View {
    var icon: String
    var label: String
    var value: String
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
    }
}

struct ActionButtonBlock: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        Group {
            if state.status == .sessionConflict {
                ModernActionButton(title: "Tekrar Dene", icon: "arrow.clockwise.circle.fill", color: .orange) {
                    Task { await state.performLogin() }
                }
            } else if state.status != .connected {
                ModernActionButton(title: "Giriş Yap", icon: "lock.open.fill", color: .blue) {
                    Task { await state.performLogin() }
                }
                .disabled(state.isLoggingIn || state.accountManager.selectedAccount == nil)
            } else {
                ModernActionButton(title: "Çıkış Yap", icon: "power", color: .red) {
                    Task { await state.performLogout() }
                }
            }
        }
    }
}

struct ModernActionButton: View {
    var title: String
    var icon: String
    var color: Color
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color.opacity(0.1))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(color.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct BottomSettingsBar: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        HStack {
            Toggle(isOn: $state.autoLoginEnabled) {
                Text("Otomatik Giriş")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            
            Spacer()
            
            Menu {
                // Button("İnternet Paylaşımı") { state.openSharingPrefs() } // Removed
                // Divider()
                Button("Çıkış") {
                    state.stop()
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20, height: 20)
        }
        .padding(12)
        .background(Color.primary.opacity(0.02))
    }
}

// MARK: - Account Settings View

struct AccountSettingsView: View {
    @ObservedObject var state: AppState
    @State private var newName = ""
    @State private var newUsername = ""
    @State private var newPassword = ""
    @State private var showAddForm = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { withAnimation { state.showAccountManager = false } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Geri")
                    }
                    .font(.system(size: 13, weight: .medium))
                }.buttonStyle(.plain)
                .foregroundStyle(.blue)
                
                Spacer()
                Text("Hesap Yönetimi").font(.system(size: 14, weight: .semibold))
                Spacer()
                
                Button(action: { withAnimation { showAddForm.toggle() } }) {
                    Image(systemName: showAddForm ? "minus.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.blue)
                }.buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.primary.opacity(0.03))
            
            Divider()

            if showAddForm {
                addAccountForm
                    .padding(16)
                    .background(Color.blue.opacity(0.05))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(state.accountManager.accounts) { acc in
                        accountRow(acc)
                    }
                    if state.accountManager.accounts.isEmpty {
                        Text("Henüz hesap eklenmedi")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 300)
        }
    }

    private var addAccountForm: some View {
        VStack(spacing: 12) {
            TextField("Hesap Adı (örn: Okul)", text: $newName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            TextField("T.C. Kimlik No", text: $newUsername)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            SecureField("GSB Şifre", text: $newPassword)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            Button(action: {
                if !newUsername.isEmpty && !newPassword.isEmpty {
                    let acc = Account(name: newName.isEmpty ? newUsername : newName, username: newUsername, password: newPassword)
                    state.accountManager.add(account: acc)
                    state.updatePortal()
                    newName = ""; newUsername = ""; newPassword = ""
                    withAnimation { showAddForm = false }
                }
            }) {
                Text("Hesabı Kaydet")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    private func accountRow(_ acc: Account) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(acc.name).font(.system(size: 13, weight: .medium))
                Text(acc.username).font(.caption).foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if acc.isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Seç") {
                    state.accountManager.select(account: acc)
                    state.updatePortal()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            Button(action: {
                state.accountManager.remove(account: acc)
                state.updatePortal()
            }) {
                Image(systemName: "trash.fill")
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(acc.isSelected ? Color.blue.opacity(0.05) : Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(acc.isSelected ? Color.blue.opacity(0.2) : Color.clear, lineWidth: 1)
                )
        )
    }
}

// MARK: - Visual Effects

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .menu
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
