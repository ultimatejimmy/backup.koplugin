# Device Backup & Restore for KOReader

![Platform](https://img.shields.io/badge/platform-KOReader-green.svg)
![License](https://img.shields.io/badge/license-GPL_3.0-yellow.svg)
![Status](https://img.shields.io/badge/status-active-brightgreen.svg)

A simple, reliable backup, restore, and migration plugin for [KOReader](https://github.com/koreader/koreader). 

Save your reading settings, custom fonts, plugins, sleep screens, and book progress in one tap—or beam your entire setup wirelessly to another e-reader using a quick 6-character code.

---

## Key Highlights

- **Pick What to Save**: Choose exactly what to include in your backup—reading settings, user plugins, custom fonts, screensavers, style tweaks, or reading history.
- **Safe Device Switching**: Moving from Kindle to Kobo, or Android to an e-ink reader? The plugin automatically adapts screen and hardware settings so your new device starts up cleanly without display glitches.
- **Wireless Device Beaming**: Transfer backups directly between e-readers without cables or a computer. Just generate a 6-character code on one device and enter it on the other.
- **One-Tap Undo Safety Net**: A safety rollback snapshot is automatically created before any restore, so you can revert back anytime if you ever change your mind.
- **Built-in Folder Picker**: Easily browse your device's storage and pick your favorite folder for backups.
- **Automatic Multi-Language Support**: Fully translated into 18 languages, automatically matching your KOReader language.

---

## Quick Installation

1. Download the latest release from the [Releases page](https://github.com/ultimatejimmy/backup.koplugin/releases).
2. Copy the `backup.koplugin` folder into your KOReader `plugins` directory:
   - **Kobo**: `/mnt/onboard/.koreader/plugins/`
   - **Kindle**: `/mnt/us/koreader/plugins/`
   - **Android**: `/sdcard/koreader/plugins/`
   - **Desktop (Linux)**: `~/.config/koreader/plugins/`
3. Restart KOReader.
4. Open the plugin from the **Tools** (wrench icon) menu → **Device Backup & Restore**.

---

## Documentation & Wiki

For detailed guides and walkthroughs, visit our [Wiki](https://github.com/ultimatejimmy/backup.koplugin/wiki):

- [1. Installation](https://github.com/ultimatejimmy/backup.koplugin/wiki/1.-Installation) — Platform-specific install instructions and requirements.
- [2. Usage](https://github.com/ultimatejimmy/backup.koplugin/wiki/2.-Usage) — Creating backups, choosing components, and restoring your setup.
- [3. Management](https://github.com/ultimatejimmy/backup.koplugin/wiki/3.-Management) — Browsing backups, checking contents, and using the Undo safety net.
- [4. Language Support](https://github.com/ultimatejimmy/backup.koplugin/wiki/4.-Language-Support) — Supported languages and automatic language detection.
- [5. Troubleshooting](https://github.com/ultimatejimmy/backup.koplugin/wiki/5.-Troubleshooting) — Quick answers to common questions.
- [6. Settings](https://github.com/ultimatejimmy/backup.koplugin/wiki/6.-Settings) — Customizing backup folders, file formats, and storage limits.
- [7. Beam Wireless Transfer](https://github.com/ultimatejimmy/backup.koplugin/wiki/7.-Beam-Transfer) — Beaming backups between e-readers wirelessly.

---

## Feedback & Issues

Have a question, suggestion, or bug report? Feel free to open an issue on the [GitHub Issue Tracker](https://github.com/ultimatejimmy/backup.koplugin/issues).
