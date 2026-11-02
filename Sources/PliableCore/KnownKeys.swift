import Foundation

/// Meanings of well-known keys in Info.plist, entitlements and launchd property lists: a readable name, the expected
/// type and, where the value comes from a fixed set, the allowed values.
public struct KnownKey {
    public let key: String
    /// Readable name, as Xcode shows it (e.g. "Bundle identifier").
    public let title: String
    /// Expected type; nil when several types are valid (e.g. launchd's KeepAlive is a Boolean or a Dictionary).
    public let type: PlistType?
    /// Allowed values for the key's own (string) value.
    public let values: [String]
    /// Allowed values for the elements of an array value (e.g. interface orientations).
    public let elementValues: [String]
    /// Only meaningful in a launchd job (keys like Label or Program are too generic to match elsewhere).
    public let launchdOnly: Bool
}

public enum KnownKeys {
    /// The entry for `key` as a child of `parent`, or nil when the key is unknown there.
    public static func lookup(_ key: String, in parent: PlistNode?) -> KnownKey? {
        guard let k = byKey[key] else { return nil }
        if k.launchdOnly, !(parent.map(isLaunchdJob) ?? false) { return nil }
        return k
    }

    /// Known keys that start with `prefix` (case-insensitive) and aren't used in `parent` yet, best matches first.
    public static func completions(for prefix: String, in parent: PlistNode) -> [String] {
        guard parent.kind == .dictionary else { return [] }
        let launchd = isLaunchdJob(parent)
        let used = Set(parent.children.compactMap(\.key))
        let p = prefix.lowercased()
        return all.filter { k in
            (!k.launchdOnly || launchd) && !used.contains(k.key) && (p.isEmpty || k.key.lowercased().hasPrefix(p))
        }.map(\.key).sorted { a, b in
            // Exact-case prefix matches first, then alphabetical.
            let ea = a.hasPrefix(prefix), eb = b.hasPrefix(prefix)
            return ea != eb ? ea : a < b
        }
    }

    /// Allowed values for `node`'s value: from its own key, or from its array's key for array elements.
    public static func allowedValues(for node: PlistNode) -> [String] {
        guard let parent = node.parent else { return [] }
        if parent.kind == .array {
            guard let arrayKey = parent.key else { return [] }
            return lookup(arrayKey, in: parent.parent)?.elementValues ?? []
        }
        guard let key = node.key else { return [] }
        return lookup(key, in: parent)?.values ?? []
    }

    /// A launchd job: a top-level dictionary with Label and Program or ProgramArguments.
    static func isLaunchdJob(_ dict: PlistNode) -> Bool {
        guard dict.parent == nil, dict.kind == .dictionary else { return false }
        let keys = Set(dict.children.compactMap(\.key))
        return keys.contains("Label") && (keys.contains("Program") || keys.contains("ProgramArguments"))
    }

    // MARK: Catalog

    private static func k(_ key: String, _ title: String, _ type: PlistType?, values: [String] = [],
                          elements: [String] = [], launchd: Bool = false) -> KnownKey {
        KnownKey(key: key, title: title, type: type, values: values, elementValues: elements, launchdOnly: launchd)
    }

    private static let privacy: [(String, String)] = [
        ("NSAppleEventsUsageDescription", "AppleEvents Sending"),
        ("NSBluetoothAlwaysUsageDescription", "Bluetooth Always"),
        ("NSCalendarsUsageDescription", "Calendars"),
        ("NSCalendarsFullAccessUsageDescription", "Calendars Full Access"),
        ("NSCameraUsageDescription", "Camera"),
        ("NSContactsUsageDescription", "Contacts"),
        ("NSDesktopFolderUsageDescription", "Desktop Folder"),
        ("NSDocumentsFolderUsageDescription", "Documents Folder"),
        ("NSDownloadsFolderUsageDescription", "Downloads Folder"),
        ("NSFaceIDUsageDescription", "Face ID"),
        ("NSHealthShareUsageDescription", "Health Share"),
        ("NSHealthUpdateUsageDescription", "Health Update"),
        ("NSLocalNetworkUsageDescription", "Local Network"),
        ("NSLocationAlwaysAndWhenInUseUsageDescription", "Location Always and When In Use"),
        ("NSLocationWhenInUseUsageDescription", "Location When In Use"),
        ("NSMicrophoneUsageDescription", "Microphone"),
        ("NSMotionUsageDescription", "Motion"),
        ("NSPhotoLibraryAddUsageDescription", "Photo Library Additions"),
        ("NSPhotoLibraryUsageDescription", "Photo Library"),
        ("NSRemindersUsageDescription", "Reminders"),
        ("NSRemovableVolumesUsageDescription", "Removable Volumes"),
        ("NSNetworkVolumesUsageDescription", "Network Volumes"),
        ("NSSpeechRecognitionUsageDescription", "Speech Recognition"),
        ("NSSystemAdministrationUsageDescription", "System Administration"),
        ("NSUserTrackingUsageDescription", "Tracking"),
    ]

    static let all: [KnownKey] = {
        var out: [KnownKey] = [
            // Bundle
            k("CFBundleDevelopmentRegion", "Default localization", .string),
            k("CFBundleDisplayName", "Bundle display name", .string),
            k("CFBundleExecutable", "Executable file", .string),
            k("CFBundleIconFile", "Icon file", .string),
            k("CFBundleIconName", "Icon name (asset catalog)", .string),
            k("CFBundleIcons", "Icon files", .dictionary),
            k("CFBundleIdentifier", "Bundle identifier", .string),
            k("CFBundleInfoDictionaryVersion", "Info dictionary format version", .string),
            k("CFBundleName", "Bundle name", .string),
            k("CFBundlePackageType", "Bundle package type", .string,
              values: ["APPL", "FMWK", "BNDL", "XPC!", "KEXT", "DEXT"]),
            k("CFBundleShortVersionString", "Version (marketing)", .string),
            k("CFBundleVersion", "Build number", .string),
            k("CFBundleSignature", "Bundle creator code", .string),
            k("CFBundleSupportedPlatforms", "Supported platforms", .array,
              elements: ["MacOSX", "iPhoneOS", "iPhoneSimulator", "AppleTVOS", "WatchOS", "XROS", "DriverKit"]),
            k("CFBundleLocalizations", "Localizations", .array),
            k("CFBundleAllowMixedLocalizations", "Allow mixed localizations", .boolean),
            k("CFBundleGetInfoString", "Get Info string (deprecated)", .string),
            k("CFBundleHelpBookFolder", "Help book folder", .string),
            k("CFBundleHelpBookName", "Help book identifier", .string),
            k("CFBundleURLTypes", "URL types", .array),
            k("CFBundleURLName", "URL identifier", .string),
            k("CFBundleURLSchemes", "URL schemes", .array),
            k("CFBundleDocumentTypes", "Document types", .array),
            k("CFBundleTypeName", "Document type name", .string),
            k("CFBundleTypeRole", "Document role", .string, values: ["Editor", "Viewer", "Shell", "QLGenerator", "None"]),
            k("CFBundleTypeIconFile", "Document icon file", .string),
            k("CFBundleTypeExtensions", "Document extensions (deprecated)", .array),
            k("LSItemContentTypes", "Document content types (UTIs)", .array),
            k("LSHandlerRank", "Handler rank", .string, values: ["Owner", "Default", "Alternate", "None"]),
            k("LSTypeIsPackage", "Document is a package", .boolean),
            k("UTExportedTypeDeclarations", "Exported type identifiers", .array),
            k("UTImportedTypeDeclarations", "Imported type identifiers", .array),
            k("UTTypeIdentifier", "Type identifier", .string),
            k("UTTypeDescription", "Type description", .string),
            k("UTTypeConformsTo", "Conforms to types", .array),
            k("UTTypeTagSpecification", "Type tags (extensions, MIME types)", .dictionary),
            k("NSPrincipalClass", "Principal class", .string),
            k("NSMainNibFile", "Main nib file base name", .string),
            k("NSMainStoryboardFile", "Main storyboard file base name", .string),
            k("NSHumanReadableCopyright", "Copyright", .string),
            k("NSHighResolutionCapable", "High resolution capable", .boolean),
            k("NSSupportsAutomaticGraphicsSwitching", "Supports automatic graphics switching", .boolean),
            k("NSRequiresAquaSystemAppearance", "Requires light (Aqua) appearance", .boolean),
            k("NSServices", "Services", .array),
            k("NSDockTilePlugIn", "Dock tile plug-in", .string),
            k("NSAppTransportSecurity", "App Transport Security settings", .dictionary),
            k("NSAllowsArbitraryLoads", "Allow arbitrary loads", .boolean),
            k("NSAllowsArbitraryLoadsInWebContent", "Allow arbitrary loads in web content", .boolean),
            k("NSAllowsLocalNetworking", "Allow local networking", .boolean),
            k("NSExceptionDomains", "Exception domains", .dictionary),
            k("NSExceptionAllowsInsecureHTTPLoads", "Allow insecure HTTP loads", .boolean),
            k("NSIncludesSubdomains", "Include subdomains", .boolean),
            k("NSExtension", "Extension", .dictionary),
            k("NSExtensionPointIdentifier", "Extension point", .string),
            k("NSExtensionPrincipalClass", "Extension principal class", .string),
            k("NSExtensionAttributes", "Extension attributes", .dictionary),
            k("ITSAppUsesNonExemptEncryption", "Uses non-exempt encryption", .boolean),
            // Launch Services
            k("LSApplicationCategoryType", "App category", .string, values: [
                "public.app-category.business", "public.app-category.developer-tools", "public.app-category.education",
                "public.app-category.entertainment", "public.app-category.finance", "public.app-category.games",
                "public.app-category.graphics-design", "public.app-category.healthcare-fitness",
                "public.app-category.lifestyle", "public.app-category.medical", "public.app-category.music",
                "public.app-category.news", "public.app-category.photography", "public.app-category.productivity",
                "public.app-category.reference", "public.app-category.social-networking", "public.app-category.sports",
                "public.app-category.travel", "public.app-category.utilities", "public.app-category.video",
                "public.app-category.weather",
            ]),
            k("LSMinimumSystemVersion", "Minimum macOS version", .string),
            k("LSUIElement", "Agent app (no Dock icon or menu bar)", .boolean),
            k("LSBackgroundOnly", "Background-only app", .boolean),
            k("LSMultipleInstancesProhibited", "Prohibit multiple instances", .boolean),
            k("LSRequiresNativeExecution", "Requires native execution (no Rosetta)", .boolean),
            k("LSArchitecturePriority", "Architecture priority", .array),
            k("LSApplicationQueriesSchemes", "Queried URL schemes", .array),
            k("LSRequiresIPhoneOS", "Requires iOS environment", .boolean),
            k("MinimumOSVersion", "Minimum OS version", .string),
            k("OSMinimumDriverKitVersion", "Minimum DriverKit version", .string),
            // UIKit
            k("UIApplicationSceneManifest", "Application scene manifest", .dictionary),
            k("UIApplicationSupportsMultipleScenes", "Supports multiple scenes", .boolean),
            k("UILaunchScreen", "Launch screen", .dictionary),
            k("UILaunchStoryboardName", "Launch screen storyboard", .string),
            k("UIMainStoryboardFile", "Main storyboard file base name", .string),
            k("UIDeviceFamily", "Device family", .array),
            k("UIRequiredDeviceCapabilities", "Required device capabilities", .array),
            k("UIBackgroundModes", "Background modes", .array, elements: [
                "audio", "location", "voip", "external-accessory", "bluetooth-central", "bluetooth-peripheral",
                "fetch", "remote-notification", "processing", "nearby-interaction", "push-to-talk",
            ]),
            k("UISupportedInterfaceOrientations", "Supported interface orientations", .array, elements: [
                "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
            ]),
            k("UIStatusBarStyle", "Status bar style", .string,
              values: ["UIStatusBarStyleDefault", "UIStatusBarStyleLightContent", "UIStatusBarStyleDarkContent"]),
            k("UIStatusBarHidden", "Status bar initially hidden", .boolean),
            k("UIViewControllerBasedStatusBarAppearance", "View controller-based status bar appearance", .boolean),
            k("UIUserInterfaceStyle", "Appearance", .string, values: ["Automatic", "Light", "Dark"]),
            k("UIFileSharingEnabled", "File sharing enabled", .boolean),
            k("UISupportsDocumentBrowser", "Supports document browser", .boolean),
            k("UIRequiresFullScreen", "Requires full screen", .boolean),
            k("UIApplicationSupportsIndirectInputEvents", "Supports indirect input events", .boolean),
            // Build information added by Xcode
            k("BuildMachineOSBuild", "Build machine OS build", .string),
            k("DTCompiler", "Compiler", .string),
            k("DTPlatformBuild", "Platform build", .string),
            k("DTPlatformName", "Platform name", .string),
            k("DTPlatformVersion", "Platform version", .string),
            k("DTSDKBuild", "SDK build", .string),
            k("DTSDKName", "SDK name", .string),
            k("DTXcode", "Xcode version", .string),
            k("DTXcodeBuild", "Xcode build", .string),
            // Kernel and driver extensions
            k("IOKitPersonalities", "IOKit personalities", .dictionary),
            k("IOClass", "Driver class", .string),
            k("IOProviderClass", "Provider class", .string),
            k("IOMatchCategory", "Match category", .string),
            k("IOUserClass", "User-space driver class", .string),
            k("IOUserServerName", "User-space server name", .string),
            k("OSBundleLibraries", "Linked libraries", .dictionary),
            k("OSBundleRequired", "Required at boot", .string,
              values: ["Root", "Local-Root", "Network-Root", "Safe Boot", "Console"]),
            // Service Management
            k("SMPrivilegedExecutables", "Privileged helper tools", .dictionary),
            k("SMAuthorizedClients", "Authorized clients", .array),
            // Entitlements
            k("com.apple.security.app-sandbox", "App Sandbox", .boolean),
            k("com.apple.security.files.user-selected.read-only", "User-selected files: read-only", .boolean),
            k("com.apple.security.files.user-selected.read-write", "User-selected files: read/write", .boolean),
            k("com.apple.security.files.downloads.read-write", "Downloads folder: read/write", .boolean),
            k("com.apple.security.network.client", "Outgoing network connections", .boolean),
            k("com.apple.security.network.server", "Incoming network connections", .boolean),
            k("com.apple.security.device.camera", "Camera", .boolean),
            k("com.apple.security.device.audio-input", "Audio input", .boolean),
            k("com.apple.security.device.usb", "USB", .boolean),
            k("com.apple.security.device.bluetooth", "Bluetooth", .boolean),
            k("com.apple.security.personal-information.location", "Location", .boolean),
            k("com.apple.security.personal-information.addressbook", "Contacts", .boolean),
            k("com.apple.security.personal-information.calendars", "Calendars", .boolean),
            k("com.apple.security.personal-information.photos-library", "Photos library", .boolean),
            k("com.apple.security.automation.apple-events", "Apple Events automation", .boolean),
            k("com.apple.security.application-groups", "App groups", .array),
            k("com.apple.security.get-task-allow", "Allow debugging (get-task-allow)", .boolean),
            k("get-task-allow", "Allow debugging (get-task-allow)", .boolean),
            k("com.apple.security.cs.allow-jit", "Allow JIT-compiled code", .boolean),
            k("com.apple.security.cs.allow-unsigned-executable-memory", "Allow unsigned executable memory", .boolean),
            k("com.apple.security.cs.allow-dyld-environment-variables", "Allow DYLD environment variables", .boolean),
            k("com.apple.security.cs.disable-library-validation", "Disable library validation", .boolean),
            k("com.apple.security.cs.disable-executable-page-protection", "Disable executable memory protection", .boolean),
            k("com.apple.application-identifier", "Application identifier", .string),
            k("application-identifier", "Application identifier", .string),
            k("com.apple.developer.team-identifier", "Team identifier", .string),
            k("keychain-access-groups", "Keychain access groups", .array),
            k("aps-environment", "Push notifications environment", .string, values: ["development", "production"]),
            k("com.apple.developer.aps-environment", "Push notifications environment", .string,
              values: ["development", "production"]),
            k("com.apple.developer.associated-domains", "Associated domains", .array),
            k("com.apple.developer.icloud-container-identifiers", "iCloud containers", .array),
            k("com.apple.developer.icloud-services", "iCloud services", .array, elements: ["CloudKit", "CloudDocuments"]),
            k("com.apple.developer.driverkit", "DriverKit", .boolean),
            k("com.apple.developer.system-extension.install", "Install system extensions", .boolean),
            k("com.apple.developer.networking.networkextension", "Network extensions", .array, elements: [
                "packet-tunnel-provider", "app-proxy-provider", "content-filter-provider", "dns-proxy",
                "dns-settings", "relay",
            ]),
            // launchd jobs
            k("Label", "Job label", .string, launchd: true),
            k("Program", "Program path", .string, launchd: true),
            k("ProgramArguments", "Program arguments", .array, launchd: true),
            k("RunAtLoad", "Run at load", .boolean, launchd: true),
            k("KeepAlive", "Keep alive", nil, launchd: true),
            k("Disabled", "Disabled", .boolean, launchd: true),
            k("StartInterval", "Start interval (seconds)", .integer, launchd: true),
            k("StartCalendarInterval", "Start calendar interval", nil, launchd: true),
            k("StartOnMount", "Start when a volume mounts", .boolean, launchd: true),
            k("WatchPaths", "Watch paths", .array, launchd: true),
            k("QueueDirectories", "Queue directories", .array, launchd: true),
            k("StandardInPath", "Standard input path", .string, launchd: true),
            k("StandardOutPath", "Standard output path", .string, launchd: true),
            k("StandardErrorPath", "Standard error path", .string, launchd: true),
            k("WorkingDirectory", "Working directory", .string, launchd: true),
            k("RootDirectory", "Root directory", .string, launchd: true),
            k("EnvironmentVariables", "Environment variables", .dictionary, launchd: true),
            k("UserName", "Run as user", .string, launchd: true),
            k("GroupName", "Run as group", .string, launchd: true),
            k("MachServices", "Mach services", .dictionary, launchd: true),
            k("Sockets", "Sockets", .dictionary, launchd: true),
            k("ThrottleInterval", "Throttle interval (seconds)", .integer, launchd: true),
            k("ExitTimeOut", "Exit timeout (seconds)", .integer, launchd: true),
            k("TimeOut", "Idle timeout (seconds)", .integer, launchd: true),
            k("Nice", "Nice value", .integer, launchd: true),
            k("Umask", "Umask", nil, launchd: true),
            k("AbandonProcessGroup", "Abandon process group", .boolean, launchd: true),
            k("LaunchOnlyOnce", "Launch only once", .boolean, launchd: true),
            k("LowPriorityIO", "Low-priority I/O", .boolean, launchd: true),
            k("ProcessType", "Process type", .string, values: ["Background", "Standard", "Adaptive", "Interactive"],
              launchd: true),
            k("LimitLoadToSessionType", "Session types", nil, launchd: true),
            k("AssociatedBundleIdentifiers", "Associated app bundle identifiers", nil, launchd: true),
            k("BundleProgram", "Program path inside the app bundle", .string, launchd: true),
        ]
        out += privacy.map { k($0.0, "Privacy – \($0.1) usage description", .string) }
        return out
    }()

    private static let byKey: [String: KnownKey] = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
}
