--[[--
backup_constants.lua
Constants and configuration definitions for backup.koplugin
--]]

local Constants = {}

-- Core plugins bundled by default with KOReader.
-- These are skipped during backup creation to keep archive sizes small (5-20MB instead of 150MB+).
Constants.CORE_KOREADER_PLUGINS = {
    ["archiveviewer.koplugin"] = true,
    ["autodim.koplugin"] = true,
    ["autostandby.koplugin"] = true,
    ["autosuspend.koplugin"] = true,
    ["autoturn.koplugin"] = true,
    ["autowarmth.koplugin"] = true,
    ["batterystat.koplugin"] = true,
    ["bookshortcuts.koplugin"] = true,
    ["calibre.koplugin"] = true,
    ["cloudstorage.koplugin"] = true,
    ["coverbrowser.koplugin"] = true,
    ["coverimage.koplugin"] = true,
    ["docsettingtweak.koplugin"] = true,
    ["exporter.koplugin"] = true,
    ["externalkeyboard.koplugin"] = true,
    ["gestures.koplugin"] = true,
    ["hello.koplugin"] = true,
    ["hotkeys.koplugin"] = true,
    ["httpinspector.koplugin"] = true,
    ["japanese.koplugin"] = true,
    ["keepalive.koplugin"] = true,
    ["kosync.koplugin"] = true,
    ["movetoarchive.koplugin"] = true,
    ["newsdownloader.koplugin"] = true,
    ["opds.koplugin"] = true,
    ["perceptionexpander.koplugin"] = true,
    ["profiles.koplugin"] = true,
    ["qrclipboard.koplugin"] = true,
    ["readtimer.koplugin"] = true,
    ["ssh.koplugin"] = true,
    ["statistics.koplugin"] = true,
    ["systemstat.koplugin"] = true,
    ["terminal.koplugin"] = true,
    ["texteditor.koplugin"] = true,
    ["timesync.koplugin"] = true,
    ["vocabbuilder.koplugin"] = true,
    ["wallabag.koplugin"] = true,
    ["wechatwork.koplugin"] = true,
}

-- Keys in settings.reader.lua that are strictly bound to physical hardware,
-- display drivers, e-ink waveform controllers, or platform sensors.
-- These are stripped when restoring in cross-device migration mode.
Constants.HARDWARE_KEYS = {
    -- Display & Blitter driver flags
    ["dev_no_hw_dither"] = true,
    ["dev_no_sw_dither"] = true,
    ["dev_no_c_blitter"] = true,
    ["mxcfb_bypass_wait_for"] = true,
    ["screen_dpi"] = true,
    ["dev_dpi"] = true,
    ["screen_width"] = true,
    ["screen_height"] = true,
    ["viewport_width"] = true,
    ["viewport_height"] = true,
    ["color_rendering"] = true,
    ["eink_full_refresh_cycles"] = true,
    ["eink_refresh_interval"] = true,
    ["closed_rotation_mode"] = true,
    ["screen_mode"] = true,
    ["hw_rotation"] = true,

    -- Frontlight & Warmth curves / sensors
    ["frontlight_intensity"] = true,
    ["is_frontlight_on"] = true,
    ["frontlight_warmth"] = true,
    ["frontlight_warmth_range"] = true,
    ["auto_warmth_settings"] = true,
    ["kindle_hall_effect_sensor_enabled"] = true,
    ["remarkable_hall_effect_sensor_enabled"] = true,
    ["battery_stats"] = true,

    -- Hardware input & touch drivers
    ["input_lock_gsensor"] = true,
    ["input_invert_page_turn_keys"] = true,
    ["ges_tap_interval_ms"] = true,
    ["ges_double_tap_interval_ms"] = true,
    ["ges_two_finger_tap_duration_ms"] = true,
    ["ges_hold_interval_ms"] = true,
    ["ges_swipe_interval_ms"] = true,
    ["multitouch_emulation"] = true,

    -- Platform & OS-specific keys (Android / Kindle / Kobo)
    ["android_screen_timeout"] = true,
    ["disable_android_fullscreen"] = true,
    ["android_ignore_volume_keys"] = true,
    ["android_ignore_back_button"] = true,
    ["haptic_feedback_override"] = true,
    ["device_id"] = true,
    ["wifi_timeout"] = true,
    ["wifi_connection_checker"] = true,
}

-- Settings containing absolute filesystem paths that vary across platforms
-- (e.g. /mnt/onboard on Kobo vs /mnt/us on Kindle vs /storage/emulated/0 on Android).
-- In cross-device migration mode, these are reset to target device defaults.
Constants.DEVICE_PATH_KEYS = {
    ["home_dir"] = true,
    ["lastdir"] = true,
    ["lastfile"] = true,
    ["download_dir"] = true,
    ["annotations_export_folder"] = true,
    ["extra_plugin_paths"] = true,
    ["screensaver_dir"] = true,
}

-- Available backup components that can be toggled by the user
Constants.COMPONENTS = {
    SETTINGS = "settings",
    PLUGINS = "plugins",
    PATCHES = "patches",
    FONTS = "fonts",
    SCREENSAVERS = "screensavers",
    STYLETWEAKS = "styletweaks",
    DOCSETTINGS = "docsettings",
    HISTORY = "history",
    DICTIONARIES = "dictionaries",
}

-- Default selection states for components when creating a backup
Constants.DEFAULT_COMPONENT_SELECTION = {
    [Constants.COMPONENTS.SETTINGS] = true,
    [Constants.COMPONENTS.PLUGINS] = true,
    [Constants.COMPONENTS.PATCHES] = true,
    [Constants.COMPONENTS.FONTS] = true,
    [Constants.COMPONENTS.SCREENSAVERS] = true,
    [Constants.COMPONENTS.STYLETWEAKS] = true,
    [Constants.COMPONENTS.DOCSETTINGS] = false, -- Opt-in (can be thousands of files)
    [Constants.COMPONENTS.HISTORY] = true,
    [Constants.COMPONENTS.DICTIONARIES] = false, -- Opt-in (can be gigabytes)
}

-- Default configuration values for backup.koplugin settings
Constants.DEFAULT_SETTINGS = {
    default_format = "zip", -- "zip" or "tar.gz"
    custom_backup_dir = nil, -- nil = use <DataStorage:getDataDir()>/backups
    retention_limit = 5, -- number of rolling backups to keep (0 = unlimited)
    clean_slate_restore = false, -- whether to delete unlisted user plugins on restore
    auto_sanitize_cross_device = true, -- auto-detect and sanitize on cross-device restore
    beam_relay_url = "https://nameless-grass-2b44.ultimatejimmy.workers.dev", -- default edge relay URL
}

-- Beam cross-device transfer constants
Constants.BEAM_DEFAULT_RELAY_URL = "https://nameless-grass-2b44.ultimatejimmy.workers.dev"
Constants.BEAM_CODE_LENGTH = 6
Constants.BEAM_TTL_SECONDS = 900 -- 15 minutes
Constants.BEAM_MAGIC_HEADER = "KOBEAM01"

-- Filename patterns and directory names
Constants.BACKUP_DIR_NAME = "backups"
Constants.ROLLBACK_DIR_NAME = "rollback"
Constants.ROLLBACK_FILE_NAME = "rollback_before_restore"
Constants.STAGING_DIR_NAME = "backup_staging"
Constants.MANIFEST_FILE_NAME = "manifest.json"

return Constants
