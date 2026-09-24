local ok_loc, Localization = pcall(require, "localization_backup")
local _ = ok_loc and Localization:getHelper() or function(k) return k end

return {
    fullname = _("Device Backup & Restore"),
    description = _("Create, manage, and restore modular KOReader backups with intelligent cross-device hardware sanitization and disaster recovery."),
    author = "jpautz",
    version = "26.9.24",
}

