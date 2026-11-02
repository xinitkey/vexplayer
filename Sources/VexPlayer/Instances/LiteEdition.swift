import Foundation

/// The Lite edition of an image: the same Google system image without the apps and background services
/// a game never needs. Android itself then uses about 0.5 GB less memory and wakes up less often, so Lite
/// instances get 1 GB less RAM by default. Packages are disabled, not removed: Settings → Apps brings any back.
enum LiteEdition {
    /// Bump when the list changes: Lite instances apply it again on their next boot.
    static let version = 1

    static let disabledPackages = [
        // Assistant, on-device intelligence, speech
        "com.google.android.googlequicksearchbox", "com.google.android.as", "com.google.android.as.oss",
        "com.google.android.tts", "com.google.android.settings.intelligence",
        // Preinstalled apps that sync in the background
        "com.google.android.apps.photos", "com.google.android.apps.messaging", "com.google.android.gm",
        "com.google.android.calendar", "com.google.android.contacts", "com.google.android.dialer",
        "com.google.android.deskclock", "com.google.android.apps.maps", "com.google.android.apps.docs",
        "com.google.android.youtube", "com.google.android.apps.youtube.music", "com.android.camera2",
        // Phone-only services
        "com.google.android.apps.wellbeing", "com.google.android.apps.safetyhub", "com.google.android.apps.restore",
        "com.google.android.projection.gearhead", "com.google.android.feedback", "com.google.android.adservices.api",
        "com.google.android.cellbroadcastreceiver", "com.google.android.apps.wallpaper", "com.android.stk",
        "com.android.devicediagnostics", "com.android.dreams.basic", "com.android.egg", "com.android.traceur",
        "com.android.bips",
        // Accessibility services
        "com.google.android.apps.accessibility.voiceaccess", "com.google.android.marvin.talkback",
        "com.google.android.accessibility.switchaccess",
    ]

    /// Android keeps fewer old apps cached in the background and reclaims their memory sooner.
    static let maxCachedProcesses = 16
}
