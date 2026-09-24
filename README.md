# backup.koplugin: KOReader Device Backup & Restore

A robust, independent plugin for [KOReader](https://github.com/koreader/koreader) providing full disaster recovery, intelligent cross-device configuration cloning, modular component backup, automatic pre-restore safety rollback snapshots, and native folder browsing.

---

## Key Features

- **Modular Component Selection**: Choose exactly what to include in each backup:
  - Core Settings & UI Gestures (`settings.reader.lua` + `settings/`)
  - User-Installed Plugins (automatically skips KOReader bundled core plugins)
  - User Patches (`patches/`)
  - Custom Fonts & Screensavers (`fonts/`, `screensavers/`)
  - Style Tweaks (`styletweaks/`)
  - Reading Progress & Book Notes (`docsettings/`, `hashdocsettings/`)
  - Reading History & Statistics (`history/`)
  - Dictionaries & OCR Data (`data/dict/`, `data/tessdata/`)
- **Intelligent Cross-Device Sanitization**:
  - Automatically compares the archive's origin hardware against the current device.
  - Strips hardware-tied keys (screen DPI, e-ink dithering/waveforms, frontlight warmth curves, sensor orientations, battery stats) to prevent boot loops and display issues across different device models.
  - Resets storage paths (`home_dir`, `lastdir`, `download_dir`) to target platform defaults.
- **Safety Rollback Snapshot & "Undo Last Restore"**:
  - Automatically creates a safety rollback snapshot (`rollback_before_restore.zip`) before applying any restore.
  - One-tap "Undo Last Restore" in the menu to revert cleanly if desired.
- **In-Memory Settings Synchronization**:
  - Updates `G_reader_settings.data` in memory prior to reboot, preventing KOReader's `Device:exit()` shutdown sequence from overwriting restored settings.
- **Dual Archival Engine with Fallback**:
  - Native `.zip` and `.tar.gz` support via KOReader's `ffi/archiver.lua` (`libarchive`).
  - Zero-dependency pure Lua TAR writer and reader fallback for maximum cross-platform resilience.
- **Interactive Folder Browser**:
  - Integrated touch- and keypad-navigable directory picker (adapted from Storefront) with parent traversal, breadcrumbs, and new folder creation.
- **Rolling Retention Pruning**:
  - Automatically retains the newest $N$ backups (default: 5), protecting storage space while never deleting safety rollback snapshots.

---

## Installation

1. Copy the `backup.koplugin` folder to your KOReader plugins directory:
   - **Kobo**: `/mnt/onboard/.koreader/plugins/backup.koplugin`
   - **Kindle**: `/mnt/us/koreader/plugins/backup.koplugin`
   - **Android**: `/sdcard/koreader/plugins/backup.koplugin`
   - **Linux / Desktop**: `~/.config/koreader/plugins/backup.koplugin`
2. Restart KOReader.
3. Access **Device Backup & Restore** from the Tools (wrench icon) menu in either File Manager or Reader view.

---

## Archive Structure

Each backup archive contains a self-describing `manifest.json`:

```text
backup_2026-09-15_163000.zip
├── manifest.json
├── settings/
│   ├── settings.reader.lua
│   └── (plugin settings)
├── plugins/
│   └── (user plugins only)
├── patches/
├── fonts/
├── screensavers/
└── styletweaks/
```

---

## Running Tests

Automated unit tests use [Busted](https://lunarmodules.github.io/busted/):

```bash
# On Linux / WSL:
./run_tests.sh

# On Windows (PowerShell / CMD):
.\run_tests.bat
```
