# Steering: Launcher and Branding (iOS)

## BlackBerry Dynamics Launcher

The Dynamics Launcher provides a consistent app-switching experience
across Dynamics-enabled apps.

### Integration

```swift
// [BB_DYNAMICS-MIGRATION] Get the managed Launcher view controller
if let launcherVC = GDiOS.sharedInstance().getManagedLauncherViewController() {
    // Present or embed the launcher
    present(launcherVC, animated: true)
}
```

### GTLauncherViewController

```swift
import BlackBerryDynamics

class MainViewController: UIViewController, GTLauncherViewControllerDelegate {

    func launcherViewController(_ launcher: GTLauncherViewController,
                                didSelectApp app: String) {
        // Handle app selection
    }
}
```

---

## Branding API

The Dynamics SDK supports custom branding for the activation and
authorization UI:

### Custom Splash Screen

Set `UILaunchStoryboardName` in Info.plist to a custom storyboard, or
use `GDSplashScreenCustomizer`:

```swift
// [BB_DYNAMICS-MIGRATION] Custom splash screen during authorization
let customizer = GDSplashScreenCustomizer()
customizer.delegate = self
```

### Brand Colors and Logo

Branding is typically configured through UEM policy, not in the app code.
The UEM admin controls:
- Company logo displayed during activation
- Brand colors for the lock screen
- Custom messages

---

## Dark Mode

The Dynamics SDK respects the system dark mode setting. Ensure your app's
custom UI adapts to both light and dark appearances when displayed
alongside the SDK's authorization UI.
