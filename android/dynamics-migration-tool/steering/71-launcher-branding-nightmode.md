# Steering: Launcher, Branding API, and Night Mode

These are optional Dynamics SDK features that enhance the user experience.
They are not required for a basic migration but should be considered for
production apps.

> **Multi-module note**: `app/src/main/assets/...` references below are
> canonical-shape illustrations. Place
> `com.blackberry.dynamics.settings.json` at every entry in
> `${primary_assets_dirs}` from
> `dynamics-migration-tool/output/module-map.json`.
> See `04-multi-module-projects.md`.

---

## BlackBerry Dynamics Launcher

The Launcher is the blue BlackBerry icon that lets users switch between
Dynamics apps, access settings, and use quick-create tools. As of SDK
13.0, it is integrated into the SDK and enabled by default.

### Default Behavior

- The Launcher starts automatically when the app runs
- A floating blue BB icon appears in the app
- Users can switch between Dynamics apps, access settings, etc.

### Disabling the Launcher

If the Launcher is not desired, add to
`app/src/main/assets/com.blackberry.dynamics.settings.json`:

```json
{
  "AutomaticLauncherManagement": false
}
```

### Customizing the Launcher

Use `LauncherDelegate` to control behavior:

```java
import com.blackberry.launcher.Launcher;
import com.blackberry.launcher.LauncherDelegate;

// [BB_DYNAMICS-MIGRATION] Custom Launcher delegate
Launcher.getInstance().setLauncherDelegate(new LauncherDelegate() {
    @Override
    public void onSettingsCommand(Activity originActivity) {
        // Open your custom settings page
        // If not overridden, the SDK shows a default settings page
    }

    @Override
    public boolean shouldShowButton(Activity activity) {
        // Return false to hide the Launcher button for specific activities
        return true;
    }

    @Override
    public boolean shouldShowCoachmark() {
        // Return false to disable the first-launch tutorial
        return true;
    }
});
```

### Migration Note

For most migrations, the Launcher works out of the box with no code
changes. Only customize if the app has specific UX requirements.

---

## Branding API (Custom Logo and Colors)

Use `configureUI` to add a custom logo and colors to the Dynamics SDK
UI screens (activation, unlock, etc.):

```java
// [BB_DYNAMICS-MIGRATION] Custom branding for Dynamics SDK screens
GDAndroid.getInstance().configureUI(config);
```

Refer to the `configureUI` method in the API reference for the full
configuration options (logo drawable, primary/secondary colors, etc.).

### Migration Note

Branding is cosmetic and optional. Consider adding it after the core
migration is complete and the app is functionally working.

---

## Night Mode Support

The Dynamics SDK supports Night Mode (dark theme) as of SDK 6.1.

### Enabling Night Mode

Night Mode works automatically if the app uses AppCompat themes. No
additional code is needed.

### Disabling Night Mode

If the app does not support Night Mode and you want consistent light-mode
UI across all screens (including Dynamics SDK screens):

```java
import androidx.appcompat.app.AppCompatDelegate;

// [BB_DYNAMICS-MIGRATION] Disable Night Mode for consistent UI
AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_NO);
```

Add this in `Application.onCreate()` before any Activity is created.

### Important Note

The SDK's internal style and theme definitions may change between versions.
Do NOT rely on Dynamics SDK internal styles for your app's UI. Use your
own theme definitions.

---

## Migration Relevance

- **Launcher**: Works automatically. No action needed unless you want to
  disable or customize it.
- **Branding**: Optional cosmetic enhancement. Low priority during migration.
- **Night Mode**: If the app already supports dark theme, it works
  automatically. If not, consider disabling it for consistency.
