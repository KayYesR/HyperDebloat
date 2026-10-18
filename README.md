# HyperDebloat

> Tested so far on a Redmi 9 Prime (MIUI 12, Android 10) and a Redmi Turbo 5 (HyperOS 3, Android 16). HyperOS testing on a POCO X8 Pro Max is next; reports from other phones are welcome (run with `-DryRun -SaveRaw` and attach `raw_adb_output.txt` and the report CSV to an issue).

A device-aware debloater for Xiaomi, Redmi and POCO phones running HyperOS or MIUI. Windows only, no root, no install.

It reads every package and running process on **your** phone and rates each package from what the phone itself reports about it. Community debloat lists are used only to describe packages and to cross-check the phone's verdict.

| Colour | Rating | Meaning |
|---|---|---|
| 🟢 Green | SAFE | Independent app. Removing it breaks nothing else. |
| 🟡 Yellow | MODERATE | A minor feature may stop working. |
| 🟠 Orange | HIGH | A notable or core feature may stop working. |
| 🔴 Red | UNSAFE | Can stop the phone booting or working properly. |
| ⚪ Grey | FLAGGED | Unknown to every list, contradicts the lists, or the phone gave no data. Never ticked for you; in Custom you can tick it after a warning. |

## How to use

1. On the phone: **Settings > About phone**, tap **OS version** 7 times. Then **Settings > Additional settings > Developer options > USB debugging: ON**.
2. Connect the phone to the PC by USB and tap **Allow** on the phone.
3. Open the apps you rely on (file manager, camera, gallery, payment apps), so the scan can see what they use.
4. Put `HyperDebloat.ps1` and `Run-HyperDebloat.bat` in the same folder and double-click `Run-HyperDebloat.bat`.
5. The home window opens. Choose an action:
   - **Recommended** shows every green package, all ticked. Untick anything you want to keep and press **Remove selected**.
   - **Custom** opens the full colour-coded list, with the same packages ticked as in Recommended. Pick a **Category** (Ads & tracking, Google apps, Xiaomi & phone apps...) or type a name to narrow it, tick what you want and press **Remove selected**. Red and grey packages ask for an extra confirmation.
   - **Restore** asks the phone what has been removed or disabled, by this tool or any other (Xiaomi ADB/Fastboot Tools, UAD, plain adb), and puts back what you tick. Removed system apps are reinstalled, disabled apps are re-enabled, and ordinary apps whose file was deleted get their Play Store page opened on the phone.
   - **Rescan phone**, **Open reports folder** and **Quit**.

   Every list has a **< Back** button, and after each action you return to the home window. Progress is shown in the console window behind it.

To see the ratings without changing anything, run `.\Run-HyperDebloat.bat -DryRun` from a terminal in that folder. Add `-SaveRaw` to also save the phone's raw output (`raw_adb_output.txt`), which helps when reporting a wrong rating.

If ADB is missing, the script offers to download Google's platform-tools for you.

## How ratings are decided

### Step 1: what depends on it, according to the phone

| Signal (read over ADB) | Effect |
|---|---|
| Persistent (Android keeps it running) | Red |
| Current default launcher, dialer, SMS app or keyboard | Red |
| Device administrator | Red |
| Provides location services (network/fused location, geocoding, geofencing) | Red |
| Another app is using its services or content providers right now | Orange |
| Active overlay on the Android framework, System UI or Settings | Orange |
| 5 or more other apps hold permissions it defines | Orange |
| 1 to 4 other apps hold permissions it defines | Yellow |
| Installed with the hardware drivers (`vendor` or `odm` partition) | Yellow at least |

No dependency means green. How a package is built (signed with the platform key, privileged, no app icon, running as a system user) is shown in the report for information but does not count against it: on Xiaomi phones nearly every package, junk included, looks like that.

### Step 2: cross-check with the lists

The lists are [UAD-ng](https://github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation), [fadeltd/xiaomi-debloater](https://github.com/fadeltd/xiaomi-debloater) and [ovsky/hyperos-debloater](https://github.com/ovsky/hyperos-debloater), downloaded fresh on every run. If GitHub is unreachable, the last saved copy is used.

- A list rates it higher than the phone does: the rating goes up to the list's rating.
- All three lists say it is junk and nothing red applies: green, or yellow if other apps clearly rely on it or it sits with the hardware drivers.
- The two lists that know it both say safe and nothing is using it right now: one step lower.
- Only one list knows it: never green, because it cannot be cross-checked.
- No list knows it: flagged grey, because nothing says what it does. Recommended never offers it; Custom lets you tick it after a warning.

Recommended ticks green background components automatically. Green apps with an icon (Gmail, YouTube, Calculator...) are listed but not ticked, because you may use them. YouTube, Chrome, Google Lens, Google Meet, WhatsApp, Instagram, Google Drive and Gmail are never ticked for you, even on phones where they have no icon; tick them yourself to remove them.
Before anything is removed, the confirmation names every ticked app that has an icon on the home screen.

### Categories

Each package also gets a category from its name, its list description, whether it has an app icon and where it is installed. Categories only help you find things; they do not change the rating.

| Category | What it holds |
|---|---|
| Ads & tracking | Ad, telemetry and usage-data services (MSA, Analytics, Daemon, Quick Apps, Facebook stubs) |
| Google apps / Google services | Google apps with an icon / Google background services |
| Xiaomi & phone apps | Other apps with an icon (Notes, Calendar, Scanner, GetApps, Themes...) |
| Xiaomi services | Xiaomi background services |
| Android system | Android background components |
| Themes & overlays | Colour, icon, navigation-bar and resource overlays |
| Hardware & drivers | Chipset, fingerprint and factory test packages, and anything on the `vendor`/`odm` partition |
| Third-party preloads | Preinstalled apps from other companies |

## Limits

- Tested on a Redmi 9 Prime (MIUI 12, Android 10) and a Redmi Turbo 5 (HyperOS 3, Android 16). Other models have not been tested yet.
- The live-connection check is a snapshot. It only sees apps that are open or running during the scan.
- Green ratings are reliable; yellow and orange are informed warnings, not guarantees. After removing anything beyond green, reboot and test what you rely on.

## Safety

- Only system apps are handled. Ordinary apps, including preloads installed to user storage (on many ROMs Google Drive, Photos or Facebook), are left out: removing them this way deletes the app file, so they could not be restored. Uninstall those normally on the phone.
- Packages are removed for user 0 only (`pm uninstall -k --user 0`). Nothing is deleted from the system partition, OTA updates keep working, and a factory reset restores everything.
- Restore does not depend on this tool's logs: it reads the phone's own record of removed and disabled packages, so removals from earlier sessions or other tools can be undone. It checks each app is really back, and if one is not, it says so and offers to open its Play Store page on the phone; your app data is kept.
- After each removal the tool checks the app is really gone; some HyperOS versions answer `Success` and keep the app.
- Some packages are protected by MIUI/HyperOS and refuse removal over USB (`Failure [-1000]`). For these, and for apps that stayed despite `Success`, the tool offers to open the phone's own uninstall screen for them (the same one Settings uses); tap OK on the phone and it checks the app is gone. An app removed that way is removed completely (or only its update, for a system app), so Restore may not bring it back; reinstall it from a store.
- The tool remembers what it removed. If a later scan finds one of those apps installed again, it tells you and saves the phone's log from that moment as `came_back_<date>.txt` in the reports folder. Please attach that file to a GitHub issue so the cause can be found.
- Every run saves a dated report in `Documents\HyperDebloat\<model>_<build>\`: phone model, HyperOS build, every rating, the phone's evidence, the lists' ratings and the final reasoning. Removals are logged in the same folder.

## Credits

Made by **kayyesr**, perfected by **Claude** (Anthropic, Claude Opus 5.5).

Package descriptions and cross-check data come from the [UAD-ng](https://github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation), [fadeltd/xiaomi-debloater](https://github.com/fadeltd/xiaomi-debloater) and [ovsky/hyperos-debloater](https://github.com/ovsky/hyperos-debloater) projects and their contributors. The lists are downloaded at run time and are not included in this repository.

## Licence

MIT - see [LICENSE](LICENSE). Use at your own risk: removing system packages can break features, and in the worst case may need a factory reset.
