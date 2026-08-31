import AppKit
import CodexMetricsCore
import ServiceManagement
import Sparkle
import SwiftUI

private enum SubscriptionProviderValidationState: Equatable {
    case idle
    case validating
    case valid(String)
    case invalid(String)
}

func printableASCIICredential(_ value: String) -> String {
    String(value.unicodeScalars.filter { (0x20...0x7E).contains($0.value) })
}

struct DashboardSettingsView: View {
    @EnvironmentObject private var store: MenuBarStore
    @AppStorage(DashboardPreferences.showMenuBarIconKey, store: DashboardPreferences.sharedDefaults()) private var showMenuBarIcon = true
    @AppStorage(DashboardPreferences.menuBarQuotaIconStyleKey, store: DashboardPreferences.sharedDefaults()) private var menuBarQuotaIconStyle = MenuBarQuotaIconStyle.rings.rawValue
    @AppStorage(DashboardPreferences.weekStartsMondayKey, store: DashboardPreferences.sharedDefaults()) private var weekStartsMonday = true
    @AppStorage(DashboardPreferences.subscriptionProviderKey, store: DashboardPreferences.sharedDefaults()) private var subscriptionProviderRaw = DashboardSubscriptionProvider.default.rawValue
    @State private var selectedSubscriptionProviderRaw = DashboardSubscriptionProvider.default.rawValue
    @State private var cliProxyAPIEndpoint = "http://127.0.0.1:8317"
    @State private var cliProxyAPIManagementKey = ""
    @State private var cliProxyAPIValidationState: SubscriptionProviderValidationState = .idle
    @State private var sub2APIEndpoint = "http://127.0.0.1:8080"
    @State private var sub2APIAdminEmail = ""
    @State private var sub2APIAdminPassword = ""
    @State private var sub2APIAdminToken = ""
    @State private var sub2APIRefreshToken = ""
    @State private var sub2APIAccounts: [Sub2APIAdminAccount] = []
    @State private var sub2APIAccountID = ""
    @State private var sub2APIValidationState: SubscriptionProviderValidationState = .idle
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    private let settingsControlWidth: CGFloat = 190

    var body: some View {
        Form {
            Section("Subscription source") {
                Picker("Provider", selection: $selectedSubscriptionProviderRaw) {
                    ForEach(DashboardSubscriptionProvider.allCases) { provider in
                        Text(provider.label).tag(provider.rawValue)
                    }
                }
                .onChange(of: selectedSubscriptionProviderRaw) { _, rawValue in
                    selectSubscriptionProvider(rawValue)
                }

                if selectedSubscriptionProvider == .cliProxyAPI {
                    Text("CLIProxyAPI keeps the OAuth credentials. CodexDashboard selects the first active Codex credential returned by its management API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Endpoint", text: $cliProxyAPIEndpoint)
                        .textContentType(.URL)

                    SecureField("Management key", text: printableASCIIBinding($cliProxyAPIManagementKey))

                    HStack {
                        Button {
                            activateCLIProxyAPIConfiguration()
                        } label: {
                            Text(cliProxyAPIValidationState == .validating ? "Activating…" : "Activate CLIProxyAPI")
                        }
                        .disabled(cliProxyAPIValidationState == .validating)

                        switch cliProxyAPIValidationState {
                        case .idle:
                            EmptyView()
                        case .validating:
                            ProgressView()
                                .controlSize(.small)
                        case .valid(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .invalid(let message):
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                    Text("The management key is stored in macOS Keychain, not in preferences or logs. It is not your OAuth token.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if selectedSubscriptionProvider == .sub2API {
                    Text("Sub2API routes user API keys through backend-managed subscription accounts. CodexDashboard reads the selected upstream account's quota through the admin API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Endpoint", text: $sub2APIEndpoint)
                        .textContentType(.URL)

                    TextField("Admin email", text: $sub2APIAdminEmail)
                        .textContentType(.username)

                    SecureField("Admin password", text: printableASCIIBinding($sub2APIAdminPassword))
                        .textContentType(.password)

                    if sub2APIAccounts.isEmpty {
                        Text(hasSub2APIActivationCredentials
                            ? "Upstream accounts are unavailable. The saved account remains selected; activate to retry."
                            : "Sign in to load OpenAI/Codex upstream accounts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Upstream account", selection: sub2APIAccountSelection) {
                            ForEach(sub2APIAccounts) { account in
                                Text("\(account.name) (\(account.id))")
                                    .tag(String(account.id))
                            }
                        }
                    }

                    HStack {
                        Button {
                            signInToSub2API()
                        } label: {
                            Text(sub2APIValidationState == .validating ? "Signing in…" : "Sign in")
                        }
                        .disabled(sub2APIValidationState == .validating)

                        Button {
                            activateSub2APIConfiguration()
                        } label: {
                            Text(sub2APIValidationState == .validating ? "Activating…" : "Activate sub2api")
                        }
                        .disabled(sub2APIValidationState == .validating || !hasSub2APIActivationCredentials)

                        switch sub2APIValidationState {
                        case .idle:
                            EmptyView()
                        case .validating:
                            ProgressView()
                                .controlSize(.small)
                        case .valid(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .invalid(let message):
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                    Text("Sign-in uses the password only for authentication. The returned session tokens are stored in macOS Keychain; the endpoint and selected account are stored in preferences.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Use the local Codex data folder for subscription and quota information.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, isEnabled in
                        updateLaunchAtLogin(isEnabled)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                HStack {
                    Text("Quota icon")
                    Spacer()
                    Picker("Quota icon", selection: $menuBarQuotaIconStyle) {
                        ForEach(MenuBarQuotaIconStyle.allCases) { style in
                            HStack(spacing: 8) {
                                MenuBarQuotaIcon(
                                    windows: quotaIconPreviewWindows,
                                    style: style
                                )
                                    .accessibilityHidden(true)
                                Text(style.label)
                            }
                            .tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: settingsControlWidth, alignment: .trailing)
                }
                .disabled(!showMenuBarIcon)
                .frame(maxWidth: .infinity)
                HStack {
                    Text("Refresh metrics")
                    Spacer()
                    Picker("Refresh metrics", selection: refreshBinding) {
                        Text("Manually").tag(TimeInterval(0))
                        Text("Every 15 seconds").tag(TimeInterval(15))
                        Text("Every minute").tag(TimeInterval(60))
                        Text("Every 5 minutes").tag(TimeInterval(300))
                    }
                    .labelsHidden()
                    .frame(width: settingsControlWidth, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
                HStack {
                    Text("First day of week")
                    Spacer()
                    Picker("First day of week", selection: $weekStartsMonday) {
                        Text("Monday").tag(true)
                        Text("Sunday").tag(false)
                    }
                    .onChange(of: weekStartsMonday) { _, _ in
                        store.updateWeekStartsMonday(weekStartsMonday)
                    }
                    .labelsHidden()
                    .frame(width: settingsControlWidth, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
            }

            Section("Codex data") {
                LabeledContent("Location") {
                    Text(store.codexHome.path(percentEncoded: false))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(store.codexHome.path(percentEncoded: false))
                }
                HStack {
                    Button("Choose…") { chooseCodexHome() }
                    Button("Reveal in Finder") { NSWorkspace.shared.open(store.codexHome) }
                    Spacer()
                    Button("Use Default") { store.resetCodexHome() }
                        .disabled(store.codexHome.standardizedFileURL == defaultCodexHome.standardizedFileURL)
                }
                Text(codexDataDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Maintenance") {
                LabeledContent("History index") {
                    Button {
                        AppDelegate.shared?.dashboardCoordinator.rebuildHistoryIndex()
                    } label: {
                        Text("Rebuild")
                    }
                }
                Text("Rebuilds the stored token, cost, runtime, and model breakdowns from all saved sessions. This may take a while for large histories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                LabeledContent("Software Update") {
                    Button("Check for Updates…") {
                        AppUpdater.shared.checkForUpdates()
                    }
                }
                LabeledContent("Current Version") {
                    Text(appVersionDescription)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(4)
        .onAppear {
            selectedSubscriptionProviderRaw = subscriptionProviderRaw
            cliProxyAPIEndpoint = DashboardPreferences.sharedDefaults().string(
                forKey: DashboardPreferences.cliProxyAPIEndpointKey
            ) ?? cliProxyAPIEndpoint
            sub2APIEndpoint = DashboardPreferences.sharedDefaults().string(
                forKey: DashboardPreferences.sub2APIEndpointKey
            ) ?? sub2APIEndpoint
            switch selectedSubscriptionProvider {
            case .default:
                break
            case .cliProxyAPI:
                cliProxyAPIManagementKey = DashboardKeychain.readManagementKey() ?? ""
            case .sub2API:
                sub2APIAdminToken = DashboardKeychain.readSub2APIAdminToken() ?? ""
                sub2APIRefreshToken = DashboardKeychain.readSub2APIRefreshToken() ?? ""
            }
            sub2APIAccountID = DashboardPreferences.sharedDefaults().string(
                forKey: DashboardPreferences.sub2APIAccountIDKey
            ) ?? ""
            reloadSub2APIAccounts()
        }
    }

    private var appVersionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    private var quotaIconPreviewWindows: [UsageQuotaWindow] {
        store.subscription?.windows.sorted { $0.windowMinutes < $1.windowMinutes } ?? []
    }

    private var selectedSubscriptionProvider: DashboardSubscriptionProvider {
        DashboardSubscriptionProvider(rawValue: selectedSubscriptionProviderRaw) ?? .default
    }

    private var hasSub2APIActivationCredentials: Bool {
        !sub2APIAdminToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (Int64(sub2APIAccountID.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    private var sub2APIAccountSelection: Binding<String> {
        Binding(
            get: { sub2APIAccountID },
            set: { accountID in
                guard accountID != sub2APIAccountID else { return }
                sub2APIAccountID = accountID
                activateSub2APIConfiguration()
            }
        )
    }

    private func printableASCIIBinding(_ binding: Binding<String>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = printableASCIICredential($0) }
        )
    }

    private var codexDataDescription: String {
        switch selectedSubscriptionProvider {
        case .default:
            "CodexDashboard reads local session, account, and quota metadata from this folder. Credentials never leave your Mac."
        case .cliProxyAPI:
            "CodexDashboard still reads local session metrics from this folder. Quota and account credentials are managed by CLIProxyAPI."
        case .sub2API:
            "CodexDashboard still reads local session metrics from this folder. Quota is read from Wei-Shaw/sub2api."
        }
    }

    private var refreshBinding: Binding<TimeInterval> {
        Binding(
            get: { store.refreshInterval },
            set: { newValue in store.updateRefreshInterval(newValue) }
        )
    }

    private var defaultCodexHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private func chooseCodexHome() {
        let panel = NSOpenPanel()
        panel.title = "Choose Codex Data Folder"
        panel.prompt = "Choose"
        panel.directoryURL = store.codexHome
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.updateCodexHome(url)
    }

    private func selectSubscriptionProvider(_ rawValue: String) {
        let provider = DashboardSubscriptionProvider(rawValue: rawValue) ?? .default
        cliProxyAPIValidationState = .idle
        sub2APIValidationState = .idle
        if provider == .cliProxyAPI,
           let configuration = DashboardPreferences.cliProxyAPIConfiguration() {
            cliProxyAPIEndpoint = configuration.baseURL.absoluteString
            cliProxyAPIManagementKey = configuration.managementKey
            subscriptionProviderRaw = provider.rawValue
            store.updateSubscriptionProvider(provider)
            activateCLIProxyAPIConfiguration()
            return
        }
        if provider == .sub2API,
           let configuration = DashboardPreferences.sub2APIConfiguration() {
            sub2APIEndpoint = configuration.baseURL.absoluteString
            sub2APIAdminToken = configuration.adminToken
            sub2APIAccountID = String(configuration.accountID)
            subscriptionProviderRaw = provider.rawValue
            store.updateSubscriptionProvider(provider)
            reloadSub2APIAccounts()
            activateSub2APIConfiguration()
            return
        }
        guard provider == .default else { return }
        subscriptionProviderRaw = provider.rawValue
        store.updateSubscriptionProvider(provider)
    }

    private func reloadSub2APIAccounts() {
        Task {
            guard let configuration = await DashboardPreferences.refreshedSub2APIConfiguration() else { return }
            sub2APIAdminToken = configuration.adminToken
            sub2APIRefreshToken = DashboardKeychain.readSub2APIRefreshToken() ?? ""
            sub2APIAccounts = await Sub2APIReader.accounts(
                baseURL: configuration.baseURL,
                adminToken: configuration.adminToken
            )
        }
    }

    private func activateCLIProxyAPIConfiguration() {
        let endpoint = cliProxyAPIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            cliProxyAPIValidationState = .invalid("Enter a valid HTTP or HTTPS service URL.")
            return
        }
        let managementKey = cliProxyAPIManagementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !managementKey.isEmpty else {
            cliProxyAPIValidationState = .invalid("Enter the CLIProxyAPI management key.")
            return
        }
        cliProxyAPIValidationState = .validating
        let configuration = CLIProxyAPIConfiguration(baseURL: url, managementKey: managementKey)
        Task {
            let result = await CLIProxyAPIReader.validate(using: configuration)
            guard selectedSubscriptionProvider == .cliProxyAPI else { return }
            guard result.isValid else {
                cliProxyAPIValidationState = .invalid(result.message)
                return
            }
            guard DashboardKeychain.saveManagementKey(managementKey) else {
                cliProxyAPIValidationState = .invalid("Could not save the management key to Keychain.")
                return
            }
            DashboardPreferences.sharedDefaults().set(
                url.absoluteString,
                forKey: DashboardPreferences.cliProxyAPIEndpointKey
            )
            cliProxyAPIEndpoint = url.absoluteString
            subscriptionProviderRaw = DashboardSubscriptionProvider.cliProxyAPI.rawValue
            selectedSubscriptionProviderRaw = subscriptionProviderRaw
            if store.subscriptionProvider == .cliProxyAPI {
                store.refreshSubscriptionProvider()
            } else {
                store.updateSubscriptionProvider(.cliProxyAPI)
            }
            cliProxyAPIValidationState = .valid(result.message)
        }
    }

    private func activateSub2APIConfiguration() {
        let endpoint = sub2APIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            sub2APIValidationState = .invalid("Enter a valid HTTP or HTTPS service URL.")
            return
        }
        let adminToken = sub2APIAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adminToken.isEmpty else {
            sub2APIValidationState = .invalid("Enter the sub2api admin access token.")
            return
        }
        let accountID = sub2APIAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accountID = Int64(accountID), accountID > 0 else {
            sub2APIValidationState = .invalid("Enter a valid upstream account ID.")
            return
        }
        sub2APIValidationState = .validating
        let initialConfiguration = Sub2APIConfiguration(baseURL: url, adminToken: adminToken, accountID: accountID)
        Task {
            let configuration: Sub2APIConfiguration
            if DashboardKeychain.readSub2APIAdminToken() == adminToken,
               let refreshed = await DashboardPreferences.refreshedSub2APIConfiguration() {
                configuration = Sub2APIConfiguration(
                    baseURL: url,
                    adminToken: refreshed.adminToken,
                    accountID: accountID
                )
                sub2APIAdminToken = refreshed.adminToken
                sub2APIRefreshToken = DashboardKeychain.readSub2APIRefreshToken() ?? ""
            } else {
                configuration = initialConfiguration
            }
            let result = await Sub2APIReader.validate(using: configuration)
            guard selectedSubscriptionProvider == .sub2API else { return }
            guard sub2APIAccountID.trimmingCharacters(in: .whitespacesAndNewlines) == String(accountID) else { return }
            guard result.isValid else {
                sub2APIValidationState = .invalid(result.message)
                return
            }
            guard DashboardKeychain.saveSub2APICredentials(
                accessToken: configuration.adminToken,
                refreshToken: sub2APIRefreshToken
            ) else {
                sub2APIValidationState = .invalid("Could not save the admin session tokens to Keychain.")
                return
            }
            DashboardPreferences.sharedDefaults().set(
                url.absoluteString,
                forKey: DashboardPreferences.sub2APIEndpointKey
            )
            DashboardPreferences.sharedDefaults().set(
                String(accountID),
                forKey: DashboardPreferences.sub2APIAccountIDKey
            )
            sub2APIEndpoint = url.absoluteString
            subscriptionProviderRaw = DashboardSubscriptionProvider.sub2API.rawValue
            selectedSubscriptionProviderRaw = subscriptionProviderRaw
            if store.subscriptionProvider == .sub2API {
                store.refreshSubscriptionProvider(validatedSubscription: result.subscription)
            } else {
                store.updateSubscriptionProvider(.sub2API)
                store.receiveMenuBarSubscription(result.subscription)
            }
            sub2APIValidationState = .valid(result.message)
        }
    }

    private func signInToSub2API() {
        let endpoint = sub2APIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            sub2APIValidationState = .invalid("Enter a valid HTTP or HTTPS service URL.")
            return
        }
        let email = sub2APIAdminEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !sub2APIAdminPassword.isEmpty else {
            sub2APIValidationState = .invalid("Enter the admin email and password.")
            return
        }
        sub2APIValidationState = .validating
        let password = sub2APIAdminPassword
        Task {
            let result = await Sub2APIReader.signIn(email: email, password: password, baseURL: url)
            guard result.isValid,
                  let accessToken = result.accessToken,
                  let refreshToken = result.refreshToken,
                  !refreshToken.isEmpty else {
                sub2APIValidationState = .invalid(result.message)
                return
            }
            sub2APIAdminToken = accessToken
            sub2APIRefreshToken = refreshToken
            sub2APIAccounts = result.accounts
            if !result.accounts.contains(where: { String($0.id) == sub2APIAccountID }) {
                sub2APIAccountID = result.accounts.first.map { String($0.id) } ?? ""
            }
            sub2APIAdminPassword = ""
            sub2APIValidationState = .valid(result.message)
        }
    }

    private func updateLaunchAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
