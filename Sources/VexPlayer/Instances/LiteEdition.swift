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

    // MARK: Minimal

    /// Bump when the Minimal list or settings change: Minimal instances apply them again on their next boot.
    static let minimalVersion = 1

    /// Chrome 124 in the Android 15 (and older) images never leaves its first-run spinner without Google Play
    /// services: it retries the Google account lookup forever. Android 16's Chrome starts without them.
    static let minimalMinAPI = 36

    /// Minimal edition: Lite, plus Google Play services and everything else that starts at boot without being
    /// needed by a game and a browser. Measured on Android 16 Google APIs: Android uses 1.05 GB instead of Lite's
    /// 1.37 GB, and an idle instance costs 5.7 % of a Mac core instead of 7.6 %. Chrome works without Google
    /// Play services; apps that need them (Play Store, Google sign-in, push) don't, and VexIME is the keyboard.
    static let minimalPackages = disabledPackages + [
        // Google Play services, Play Store and their helpers
        "com.google.android.gms", "com.google.android.gsf", "com.android.vending",
        "com.google.android.configupdater", "com.google.android.partnersetup", "com.google.android.googlesdksetup",
        "com.google.android.onetimeinitializer", "com.google.android.federatedcompute",
        "com.google.android.ondevicepersonalization.services", "com.google.android.odad", "com.google.android.rkpdapp",
        "com.google.android.healthconnect.controller", "com.google.android.printservice.recommendation",
        "com.google.android.markup", "com.google.android.avatarpicker", "com.google.android.tag",
        "com.google.android.hotspot2.osulogin",
        // Gboard: VexIME takes its place
        "com.google.android.inputmethod.latin",
        // System apps woken at boot for phone, work-profile, backup and printing features
        "com.android.managedprovisioning", "com.android.imsserviceentitlement", "com.android.providers.calendar",
        "com.android.dynsystem", "com.android.localtransport", "com.android.cellbroadcastreceiver",
        "com.android.carrierdefaultapp", "com.android.printspooler", "com.android.mms.service", "com.android.musicfx",
        "com.android.wallpaper.livepicker", "com.android.storagemanager", "com.android.ons",
        "com.android.systemui.accessibility.accessibilitymenu", "com.android.bluetoothmidiservice",
        "com.android.DeviceAsWebcam",
    ]

    /// Applied once, like the package list: the user can turn any of these back on in Android's settings.
    static let minimalSettings = [
        "cmd location set-location-enabled false",
        "settings put global wifi_scan_always_enabled 0", "settings put global ble_scan_always_enabled 0",
        "settings put secure spell_checker_enabled 0", "bmgr enable false",
    ]
}
