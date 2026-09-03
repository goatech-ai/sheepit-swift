import Foundation

/// Periodically fetches flag/experiment configuration from GET /v1/config.
/// Mirrors packages/sdk-js/src/config-sync.ts
actor ConfigSync {
    private let http: HTTPClient
    private let storage: StorageProvider
    private let refreshInterval: TimeInterval
    private let log: GTLogger
    private let onConfig: @Sendable (SDKConfigResponse) -> Void
    private var etag: String?
    private var refreshTask: Task<Void, Never>?

    init(
        http: HTTPClient,
        storage: StorageProvider,
        refreshInterval: TimeInterval,
        log: GTLogger,
        onConfig: @escaping @Sendable (SDKConfigResponse) -> Void
    ) {
        self.http = http
        self.storage = storage
        self.refreshInterval = refreshInterval
        self.log = log
        self.onConfig = onConfig
    }

    /// Start sync: load cache immediately, then fetch periodically.
    func start(deviceIdGetter: @escaping @Sendable () -> String) {
        // Load cached config synchronously for instant availability
        loadFromCache()

        // Start periodic refresh
        refreshTask = Task {
            while !Task.isCancelled {
                await fetchConfig(deviceId: deviceIdGetter())
                try? await Task.sleep(for: .seconds(refreshInterval))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Force a config refresh.
    func refresh(deviceId: String) async {
        await fetchConfig(deviceId: deviceId)
    }

    // MARK: - Private

    private func fetchConfig(deviceId: String) async {
        var headers: [String: String] = ["X-Device-ID": deviceId]
        if let etag { headers["If-None-Match"] = etag }

        do {
            let (data, response) = try await http.getRaw(path: SDKEndpoints.config, extraHeaders: headers)

            // 304 Not Modified
            if response.statusCode == 304 {
                log.debug("Config unchanged (304)")
                return
            }

            guard (200...299).contains(response.statusCode) else {
                log.warn("Config fetch failed: HTTP \(response.statusCode)")
                return
            }

            // Parse the config response
            let configResponse = try JSONDecoder().decode(ApiDataResponse<SDKConfigResponse>.self, from: data)
            let sdkConfig = configResponse.data

            // Update ETag
            etag = sdkConfig.etag

            log.debug("Config updated (v\(sdkConfig.configVersion))")

            // Cache the raw response
            storage.set(data, forKey: StorageKeys.sdkConfig)

            // Apply config via callback
            onConfig(sdkConfig)

        } catch {
            log.warn("Config fetch error: \(error.localizedDescription)")
        }
    }

    private func loadFromCache() {
        guard let data = storage.data(forKey: StorageKeys.sdkConfig),
              let cached = try? JSONDecoder().decode(ApiDataResponse<SDKConfigResponse>.self, from: data) else { return }
        log.debug("Loaded config from cache (v\(cached.data.configVersion))")
        onConfig(cached.data)
    }
}
