# KOReader Plugin Style Guide: Backup & Restore

This document establishes the UI, UX, and architectural design standards for the KOReader Device Backup & Restore plugin (`backup.koplugin`). All current modules and future contributions must strictly comply with these guidelines.

---

## 1. Iconography Standards: Feather Icons Only

### The Golden Rule
> **MANDATORY**: **Only Feather Icons (`assets/*.svg`) must be used for all graphical icons throughout the plugin.**

- **NO Stock Icon References**: Never reference stock KOReader icon names (e.g., `icon = "notice-warning"`, `icon = "folder"`, `icon = "check"`) without explicit paths. KOReader looks for these in `resources/icons/mdlight/`. When an icon is unmapped or missing from the host system, KOReader renders `icon-not-found.svg` (the broken black triangle caution icon).
- **NO Unicode Emojis**: Never use unicode emojis (such as `📁`, `☑`, `☐`, `↺`, `◀`, `▶`) in UI labels or buttons. E-ink rendering engines and custom reader fonts frequently lack glyph coverage for emojis, rendering them as hollow rectangles, missing glyphs, or misaligned boxes.
- **Self-Contained Bundling**: All icons must reside directly inside the plugin's [`assets/`](file:///c:/Users/jpautz/Documents/backup/backup.koplugin/assets) directory as standalone SVGs.

### Supported Feather Icons
The following Feather SVGs are bundled and standardized in `assets/`:
- **Navigation & Actions**: `arrow-up.svg`, `arrow-left.svg`, `chevron-left.svg`, `chevron-right.svg`, `chevron-down.svg`, `chevrons-left.svg`, `chevrons-right.svg`
- **File & Folder Operations**: `folder.svg`, `package.svg`, `package-active.svg`, `download.svg`, `trash-2.svg`, `plus.svg`, `x.svg`, `check.svg`
- **Toggles & Selection**: `check-square.svg`, `square.svg`, `toggle-left.svg`, `toggle-right.svg`
- **System & Status**: `settings.svg`, `rotate-cw.svg`, `refresh-cw.svg`, `alert-triangle.svg`, `info.svg`, `lock.svg`, `key.svg`

### Icon Rendering Pattern
Icons must be rendered via `ImageWidget` using the cached `getAssetPath()` resolver:
```lua
local ImageWidget = require("ui/widget/imagewidget")

local icon_widget = ImageWidget:new{
    file = getAssetPath("folder.svg"),
    width = sc(22),
    height = sc(22),
    scale_factor = 0,
    is_icon = true,
    alpha = true,
}
```

---

## 2. Modal Window & Dialog Hierarchy

### Z-Order and Modal Stacking
KOReader's `UIManager` sorts windows using the `modal` property:
- Any window without `modal = true` will be placed **underneath** active modals in the stack.
- Custom overlays (like the Folder Browser or Wizard Sheets) **must** declare:
  ```lua
  modal = true,
  covers_fullscreen = true,
  ```
- Always display custom modal containers in the `"ui"` layer:
  ```lua
  UIManager:show(overlay, "ui")
  ```

### Clean Dialog Transitions
Never stack interactive modals on top of each other:
1. When opening a child dialog (such as launching `FolderPicker` or `InputDialog` from `SettingsDialog`), **close the parent dialog first**:
   ```lua
   if dialog then UIManager:close(dialog) end
   ```
2. When the child modal confirms or cancels, reopen the parent dialog inside `UIManager:nextTick()`:
   ```lua
   on_confirm = function(chosen)
       saveSetting(chosen)
       UIManager:nextTick(function()
           BackupUI.showSettingsDialog()
       end)
   end,
   on_cancel = function()
       UIManager:nextTick(function()
           BackupUI.showSettingsDialog()
       end)
   end
   ```

---

## 3. ButtonDialog Syntax Standards

`ButtonDialog` requires a strict two-dimensional table structure where each outer element is a **row** containing an array of button definitions:

```lua
-- CORRECT: Row 1 has 1 button; Row 2 has 2 buttons side-by-side
local buttons = {
    {
        {
            text = _("Create Backup..."),
            callback = function() ... end,
        },
    },
    {
        {
            text = _("Settings..."),
            callback = function() ... end,
        },
        {
            text = _("Close"),
            callback = function() ... end,
        },
    },
}
```

> [!CAUTION]
> **Avoid 3-level table nesting**: Wrapping a button in an extra table `{ { { text = ... } } }` causes KOReader's `ButtonDialog` parser to fail, incorrectly assuming the button is an icon widget and rendering `icon-not-found.svg` placeholders.

---

## 4. E-Ink Readability & Layout

- **DPI Scaling**: Always wrap dimensions, paddings, and font offsets in `sc(val)` (`Device.screen:scaleBySize(val)`).
- **Text Wrapping & Path Safety**: Paths or dynamically generated strings must be wrapped across lines (e.g. `Backup Folder:\n%s`) or truncated with `truncateToWidth()` to prevent button text overflowing borders.
- **High Contrast**: Use solid black text (`Blitbuffer.COLOR_BLACK`) on pure white backgrounds (`Blitbuffer.COLOR_WHITE`) with crisp dividing rules (`Size.line.thin` or `Size.line.medium`).
- **Touch Ergonomics**: Maintain a minimum touch-target height of 36–44px for buttons on e-ink devices.

---

## 5. Internationalization & Localization Standards

### Zero-Dependency Localization Architecture
The plugin provides its own pure-Lua localization system (`localization_backup.lua`) with standard GNU gettext `.po` catalog support:
- **No Unwrapped UI Strings**: Never hardcode user-facing English strings in widget properties (`text = "..."`, `title = "..."`, `description = "..."`). Always wrap user-facing text in `_("...")`.
- **Dynamic Helper Import**:
  ```lua
  local Localization = require("localization_backup")
  local _ = Localization:getHelper()
  ```
- **Automatic Language Detection**: The runtime automatically queries KOReader's global settings (`G_reader_settings:readSetting("language")`), normalizes locale tags (e.g. `pt_BR` -> `pt_br`, `es_ES` -> `es`), and falls back safely to English master (`en.po`).
- **100% Key Parity**: All translation keys across all 19 supported language files (`languages/*.po`) must maintain 100% key parity with 0 missing or empty keys.
- **Automated Tooling**:
  - Run `python tools/sync_translations.py` to extract source keys and synchronize all language catalogs (with Gemini AI translation support).
  - Run `python tools/check_translations.py` to audit unwrapped strings, key completeness, and format specifiers.

