# Steering: Documentation and References (iOS)

## Official Documentation

- [BlackBerry Dynamics SDK for iOS — Development Guide](https://docs.blackberry.com/en/development-tools/blackberry-dynamics-sdk-ios/)
- [BlackBerry Dynamics iOS API Reference](https://developer.blackberry.com/files/blackberry-dynamics/ios/interface_g_di_o_s.html)
- [BlackBerry Dynamics SDK for iOS 15.0 Release Notes](https://docs.blackberry.com/en/blackberry-dynamics-sdk/15.x/blackberry-dynamics-sdk-for-ios/blackberry-dynamics-sdk-for-ios-release-notes/blackberry-dynamics-sdk-for-ios-version-15.0)
- [Crypto C Programming Interface (`GDCryptoPKCS7`)](https://developer.blackberry.com/files/blackberry-dynamics/ios/group__cryptolist.html)
- [Allow or block file transfer to non-BlackBerry Dynamics apps](https://docs.blackberry.com/en/development-tools/blackberry-dynamics-sdk-ios/15_0/allow-or-block-file-transfer-to-non-blackberry-dynamics-apps)

> **Removed in SDK 15.0:** BlackBerry Protect Mobile features (safe
> browsing with Dynamics apps; scanning URLs in text messages). Do not
> steer migrations toward Protect Mobile / SafeBrowsing APIs.

## Sample Applications

- [BlackBerry Dynamics iOS Samples (GitHub)](https://github.com/blackberry/BlackBerry-Dynamics-iOS-Samples)
- Sample apps included with SDK:
  - RSS Reader (Swift and Objective-C)
  - Secure Storage
  - Core Data
  - AppKinetics (Services Client/Server)
  - Bypass Unlock
  - Greetings Client/Server
  - SwiftUI Sample

## Key API References

| Class | Header | Purpose |
|-------|--------|---------|
| `GDiOS` | `GDiOS.h` | Main SDK entry point, authorization |
| `GDState` | `GDState.h` | Authorization state, KVO-compliant |
| `GDFileManager` | `GDFileManager.h` | Encrypted file operations |
| `GDFileHandle` | `GDFileHandle.h` | Encrypted file handle |
| `GDCReadStream` | `GDCReadStream.h` | Encrypted input stream |
| `GDCWriteStream` | `GDCWriteStream.h` | Encrypted output stream |
| `GDPersistentStoreCoordinator` | `GDPersistentStoreCoordinator.h` | Encrypted Core Data |
| `GDURLLoadingSystem` | `GDURLLoadingSystem.h` | Secure NSURLSession |
| `GDSocket` | `GDNETiOS.h` | Secure socket |
| `GDHttpRequest` | `GDNETiOS.h` | Secure HTTP request |
| `GDService` | `GDServices.h` | AppKinetics service provider |
| `GDServiceClient` | `GDServices.h` | AppKinetics service consumer |
| `GDNativePasteboardAccess` | `GDNativePasteboardAccess.h` | DLP pasteboard access |
| `GDSplashScreenCustomizer` | `GDSplashScreenCustomizer.h` | Custom splash screen |
| `GDPKI` / `GDPKICertificate` | `GDPKI.h` | Certificate management |
| `GDLogManager` | `GDLogManager.h` | Log management |
| `GDDiagnostic` | `GDDiagnostic.h` | Connectivity diagnostics |
| `GDPushChannel` | `GDPush.h` | Push notifications |
| `GDUtility` | `GDUtility.h` | Auth tokens, utility |
| `sqlite3enc_open` | `sqlite3enc.h` | Encrypted SQLite |

## UEM Documentation

- [UEM Administration Guide](https://docs.blackberry.com/en/endpoint-management/blackberry-uem/)
- [Creating App Entitlements](https://docs.blackberry.com/en/endpoint-management/blackberry-uem/current/managing-apps)
- [Configuring Connectivity Profiles](https://docs.blackberry.com/en/endpoint-management/blackberry-uem/current/managing-network-connections)
- [DLP Policy Configuration](https://docs.blackberry.com/en/endpoint-management/blackberry-uem/current/managing-device-features)

## CocoaPods

- [BlackBerryDynamics CocoaPod](https://cocoapods.org/pods/BlackBerryDynamics)
- [CocoaPods Getting Started](https://guides.cocoapods.org/using/getting-started.html)

## Swift Package Manager (Official)

- [BlackBerry Dynamics iOS SDK (SPM)](https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK)
  - Package URL: `https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK`
  - Approved pin for this toolkit: `15.0.0` (SDK build `15.0.8513.67`)
  - Required products: `BlackBerryDynamics`, `GSEProvider`
  - Optional test product: `BlackBerryDynamicsAutomatedTestSupportLibrary`

## API Verification Note

When verifying API signatures, use the installed SDK headers found in
`Pods/BlackBerryDynamics/` after `pod install`, in the SPM package checkout
after resolution, or in the manually linked `.xcframework`. The official
API reference at
`https://developer.blackberry.com/files/blackberry-dynamics/ios/` is the
authoritative public surface.
