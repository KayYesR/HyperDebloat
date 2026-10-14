# HyperDebloat

> Tested so far on a Redmi 9 Prime (MIUI 12, Android 10). HyperOS testing on a POCO X8 Pro Max is next; reports from other phones are welcome (run with `-DryRun -SaveRaw` and attach `raw_adb_output.txt` and the report CSV to an issue).

A device-aware debloater for Xiaomi, Redmi and POCO phones running HyperOS or MIUI. Windows only, no root, no install.

It reads every package and running process on **your** phone and rates each package from what the phone itself reports about it. Community debloat lists are used only to describe packages and to cross-check the phone's verdict.

| Colour | Rating | Meaning |
|---|---|---|
| 🟢 Green | SAFE | Independent app. Removing it breaks nothing else. |
| 🟡 Yellow | MODERATE | A minor feature may stop working. |
| 🟠 Orange | HIGH | A notable or core feature may stop working. |
| 🔴 Red | UNSAFE | Can stop the phone booting or working properly. |
| ⚪ Grey | FLAGGED | Unknown to every list, contradicts the lists, or the phone gave no data. Never touched. |

## How to use

1. On the phone: **Settings > About phone**, tap **OS version** 7 times. Then **Settings > Additional settings > Developer options > USB debugging: ON**.
2. Connect the phone to the PC by USB and tap **Allow** on the phone.
3. Open the apps you rely on (file manager, camera, gallery, payment apps), so the scan can see what they use.
4. Put `HyperDebloat.ps1` and `Run-HyperDebloat.bat` in the same folder and double-click `Run-HyperDebloat.bat`.
5. The home window opens. Choose an action:
   - **Recommended** shows every green package, all ticked. Untick anything you want to keep and press **Remove selected**.
   - **Custom** opens the full colour-coded list. Tick what you want and press **Remove selected**. Red packages ask for an extra confirmation.
   - **Restore** asks the phone what has been removed or disabled, by this tool or any other (Xiaomi ADB/Fastboot Tools, UAD, plain adb), and puts back what you tick. Removed system apps are reinstalled, disabled apps are re-enabled, and ordinary apps whose file was deleted get their Play Store page opened on the phone.
   - **Rescan phone**, **Open reports folder** and **Quit**.

   Every list has a **< Back** button, and after each action you return to the home window. Progress is shown in the console window behind it.

To see the ratings without changing anything, run `.\Run-HyperDebloat.bat -DryRun` from a terminal in that folder. Add `-SaveRaw` to also save the phone's raw output (`raw_adb_output.txt`), which helps when reporting a wrong rating.

If ADB is missing, the script offers to download Google's platform-tools for you.

## How ratings are decided

### Step 1: the phone's own evidence

| Signal (read over ADB) | Effect |
|---|---|
| Persistent (Android keeps it running) | Red |
| Current default launcher, dialer, SMS app or keyboard | Red |
| Device administrator | Red |
| Provides location services (network/fused location, geocoding, geofencing) | Red |
| Another app is using its services or content providers right now | Orange |
| Active overlay on the Android framework, System UI or Settings | Orange |
| Runs as a system user (system, phone, bluetooth...) | Orange |
| Installed with the hardware drivers (`vendor` or `odm` partition) | Orange |
| Signed with the platform key | soft |
| Privileged system app | soft |
| Provides protected permissions to other apps | soft |
| No app icon (background component) | soft |

No signals means green. One or two soft signals means yellow, three or more means orange.

### Step 2: cross-check with the lists

The lists are [UAD-ng](https://github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation), [fadeltd/xiaomi-debloater](https://github.com/fadeltd/xiaomi-debloater) and [ovsky/hyperos-debloater](https://github.com/ovsky/hyperos-debloater), downloaded fresh on every run. If GitHub is unreachable, the last saved copy is used.

- A list rates it higher than the phone does: the rating goes up to the list's rating.
- The phone sees an independent app (green) but a list says expert or danger: contradiction. The package is flagged grey and never touched.
- The lists rate it lower: the phone's evidence wins. The one exception is when nothing is using it, no red signal applies, and every list (at least two) says safe; then it drops one step, but never to green.
- No list knows the package: it is flagged grey and never touched, because nothing says what it does.

## Limits

- Tested on a Redmi 9 Prime (MIUI 12, Android 10). HyperOS phones have not been tested yet.
- The live-connection check is a snapshot. It only sees apps that are open or running during the scan.
- Green ratings are reliable; yellow and orange are informed warnings, not guarantees. After removing anything beyond green, reboot and test what you rely on.

## Safety

- Only system apps are handled. Ordinary apps, including preloads installed to user storage (on many ROMs Google Drive, Photos or Facebook), are left out: removing them this way deletes the app file, so they could not be restored. Uninstall those normally on the phone.
- Packages are removed for user 0 only (`pm uninstall -k --user 0`). Nothing is deleted from the system partition, OTA updates keep working, and a factory reset restores everything.
- Restore does not depend on this tool's logs: it reads the phone's own record of removed and disabled packages, so removals from earlier sessions or other tools can be undone. It checks each app is really back, and if one is not, it says so and offers to open its Play Store page on the phone; your app data is kept.
- Some packages are protected by MIUI/HyperOS and refuse removal (`Failure [-1000]`). Nothing changes in that case.
- Every run saves a dated report in `Documents\HyperDebloat\<model>_<build>\`: phone model, HyperOS build, every rating, the phone's evidence, the lists' ratings and the final reasoning. Removals are logged in the same folder.

## Credits

Made by **kayyesr**, perfected by **Claude** (Anthropic, Claude Opus 5.5).

Package descriptions and cross-check data come from the [UAD-ng](https://github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation), [fadeltd/xiaomi-debloater](https://github.com/fadeltd/xiaomi-debloater) and [ovsky/hyperos-debloater](https://github.com/ovsky/hyperos-debloater) projects and their contributors. The lists are downloaded at run time and are not included in this repository.

## Licence

MIT - see [LICENSE](LICENSE). Use at your own risk: removing system packages can break features, and in the worst case may need a factory reset.
