# PortHole User Guide

PortHole puts your Android phone in Finder. Once it's set up, plug in your phone and it appears in Finder's sidebar under **Locations**, as `PortHole-<phone name>`.

- [1. Install](#1-install)
- [2. Turn on PortHole in System Settings](#2-turn-on-porthole-in-system-settings)
- [3. Connect your phone](#3-connect-your-phone)
- [4. Using it](#4-using-it)
- [5. Wi-Fi](#5-wi-fi)
- [6. Settings](#6-settings)
- [7. Troubleshooting](#7-troubleshooting)
- [8. Uninstall](#8-uninstall)

## 1. Install

**Requirements:** macOS 14 Sonoma or later, on an Apple Silicon or Intel Mac.

1. Download `PortHole-<version>.dmg` from the [Releases page](https://github.com/arunesh-singh/PortHole/releases/latest).
2. Open the DMG and drag **PortHole** onto the **Applications** folder.
3. Eject the DMG, then open PortHole from Applications. Don't run it from inside the DMG.

### “PortHole” can't be opened / Apple could not verify…

Release builds are currently not notarized by Apple, so macOS asks you to confirm once:

1. Open PortHole and click **Done** (or **OK**) on the warning.
2. Open **System Settings › Privacy & Security**, scroll down to the message about PortHole, and click **Open Anyway**.
3. Open PortHole again and confirm.

If you prefer Terminal, this does the same thing:

```sh
xattr -dr com.apple.quarantine /Applications/PortHole.app
```

You only need to do this once per version. If you don't want to trust a prebuilt download, [build it yourself](DEVELOPMENT.md#quick-start) from the source code.

## 2. Turn on PortHole in System Settings

macOS requires you to allow any app that adds locations to Finder:

1. Click the PortHole icon in the menu bar (a phone with radio waves).
2. If it shows **“Turn on PortHole in System Settings”**, click **Open System Settings**.
3. Under **General › Login Items & Extensions › File Providers**, turn on **PortHole**.

The banner disappears once it's on.

## 3. Connect your phone

PortHole can reach your phone two ways. You can use either one or both.

### Option A: File transfer (MTP). Easiest.

1. Connect the phone with a USB cable that carries data. Some cables only charge.
2. Unlock the phone.
3. Pull down the notification shade, tap the **USB** notification (“Charging this device via USB”), and choose **File transfer** (sometimes called **Transfer files** or **MTP**).

When the phone connects, PortHole takes it over from macOS's built-in camera service (Image Capture). That's normal.

### Option B: USB debugging (ADB). Faster, also works over Wi-Fi.

1. Install Google's platform tools on your Mac (one time):
   ```sh
   brew install android-platform-tools
   ```
   Or install Android Studio, which includes them.
2. On the phone, enable **Developer options**: go to **Settings › About phone** and tap **Build number** seven times.
3. In **Settings › Developer options**, turn on **USB debugging**.
4. Connect the phone. When it asks **“Allow USB debugging?”**, tick **Always allow from this computer** and tap **Allow**.

If both options are available, PortHole uses ADB. You can change this in Settings.

## 4. Using it

- **Open:** click the 📁 button next to the phone in the menu, or pick it in Finder's sidebar.
- **Storage:** inside you'll find **Internal storage** (called *Internal shared storage* over MTP) and any SD card.
- **Copy to the phone:** drag files into a folder. They upload in the background.
- **Copy from the phone:** open or drag out a file. It downloads on demand. Photos and videos show thumbnails without being downloaded (videos only over MTP).
- **Disk space:** Finder can only read a phone file after downloading a copy to your Mac. PortHole keeps those copies under **Settings › Keep opened phone files on this Mac** (2 GB by default) and removes them all when your Mac has less than 5 GB free. Removing a copy never touches the phone. Copying a whole camera roll to another drive is safe.
- **Rename, move, new folder, delete** all work as usual. ⚠️ The phone has no Trash: **deleting removes files from the phone right away.**
- **Changes made on the phone** appear in Finder within about 30 seconds, or right away when you click ↻ in the menu.
- **Unmount:** click ⏏ in the menu, or just unplug the phone.
- **Quit** from the menu. This removes the phone from Finder.

## 5. Wi-Fi

Wi-Fi uses ADB, so set up [option B](#option-b-usb-debugging-adb-faster-also-works-over-wi-fi) first. The phone and Mac must be on the same network.

**Android 11 and newer (Wireless debugging):**

1. On the phone, go to **Settings › Developer options › Wireless debugging** and turn it on.
2. First time only: tap **Pair device with pairing code**. In the PortHole menu, open **Connect over Wi-Fi**, enter the IP address:port and the 6-digit code shown on the phone, and click **Pair**.
3. Enter the IP address:port shown on the main **Wireless debugging** screen (it's a different port from the pairing one), then click **Connect**.

**Older phones:** connect over USB once and run `adb tcpip 5555` in Terminal. Unplug, then connect to `<phone-ip>:5555` in the menu.

To disconnect, click ⓧ next to the phone.

## 6. Settings

Open the menu, then **Settings…**:

| Setting | What it does |
|---|---|
| MTP / ADB | Turns each connection method on or off. |
| When both are available, use ADB | Shows one location per phone instead of two. |
| adb path | Only needed if `adb` is installed somewhere unusual. |
| Check phone for changes | How often PortHole looks for changes made on the phone. |
| Open in Finder when a phone is mounted | Opens a Finder window automatically. |
| Launch at login | Starts PortHole when you log in. |

## 7. Troubleshooting

**The phone doesn't show up at all**
- Unlock the phone and check the USB mode is **File transfer**, not *Charging only*.
- Try another cable or port. Hubs and charge-only cables are common culprits.
- For ADB, run `adb devices` in Terminal. *unauthorized* means you need to accept the prompt on the phone.

**“Couldn't open the phone over MTP”**
- Quit other apps that use MTP: Android File Transfer, OpenMTP, MacDroid, Photos/Image Capture imports.
- Click **Retry**, then **Release from Image Capture**.
- Unplug the phone and plug it back in.

**The location is in Finder but empty, or shows “Operation timed out”**
- Make sure PortHole is turned on in System Settings (see [step 2](#2-turn-on-porthole-in-system-settings)).
- Make sure PortHole is running (its icon is in the menu bar).
- Quit PortHole, then reopen it from **Applications**.

**“The application cannot be used right now”** (in Console), or nothing mounts after updating or moving the app
- Keep only one copy of PortHole, in Applications. Delete any old copies and eject the DMG, then reopen PortHole.

**Files changed on the phone don't appear**
- Click ↻ in the menu, or lower the interval in Settings.

**Opening a photo freezes for a few seconds** (MTP)
- Opening photos in **Preview** wakes macOS's camera service, which resets the phone's USB connection. PortHole reconnects and retries automatically, usually within a couple of seconds. If it keeps happening, use ADB, which isn't affected.

**Folders named like “PortHole-RMX5085 (13-10-26 12:16 AM)”** in `~/Library/CloudStorage`
- Versions before 0.1.3 left copies of opened files behind when a phone was unmounted. They're plain copies, so you can delete those folders.

**My Mac's disk filled up while copying from the phone** (versions before 0.1.5)
- Older versions kept a copy of every file you opened or copied, on the Mac's internal disk. Update to 0.1.5 or later. To free the space right away, quit PortHole from its menu (this removes the copies, not the phone's files).

**Photos copied over ADB don't show in the phone's Gallery**
- Over ADB, Android doesn't index new files right away. Restart the phone or use MTP for media.

**Still stuck?** [Open an issue](https://github.com/arunesh-singh/PortHole/issues/new/choose) with your macOS version, phone model, connection method, and what you see.

## 8. Uninstall

1. Quit PortHole from its menu.
2. Drag **PortHole** from Applications to the Trash.
3. Optionally, remove its data:
   ```sh
   rm -rf ~/Library/Application\ Support/PortHole
   defaults delete com.arunesh.porthole
   ```
