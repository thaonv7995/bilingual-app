import Foundation

/// Runtime feature flags synchronized from the backend (`/api/config`),
/// falling back to the client config (`Info.plist`) while offline or before load.
struct AppFeatureFlags: Codable, Equatable {
    let audiobookEnabled: Bool

    static let clientDefault = AppFeatureFlags(
        audiobookEnabled: (Bundle.main.object(forInfoDictionaryKey: "ENABLE_AUDIOBOOK") as? Bool) ?? false
    )
}

struct AppConfigResponse: Codable {
    let features: AppFeatureFlags
}

