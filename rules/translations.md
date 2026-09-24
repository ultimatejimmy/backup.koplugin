---
trigger: always_on
description: Guidelines and rules for translation management, key synchronization, and character length constraints in backup.koplugin.
---

# Translation Guidelines & Rules

## 1. Master Language & Key Synchronization
- **English Master (`en.po`)**: `en.po` is the primary master translation template.
- **100% Key Parity**: All translation keys referenced in Lua source code (`_("key")`, `loc:t("key")`, `KEY_ALIASES`, `FALLBACKS`) MUST exist in `en.po` and be synchronized across ALL 18 target `.po` files.
- **Automated Synchronization & Auditing**:
  - Run `python tools/sync_translations.py` whenever adding or modifying translation keys.
  - Run `python tools/check_translations.py` to verify 100% key coverage across all languages with 0 missing, empty, or stale keys.

## 2. Character Length & Proportional Scaling Rules
- **Similar Length Requirement**: Target language translations (`msgstr`) should be kept similar in character length to the English source text (`msgid`). Avoid unnecessarily verbose phrasing or long compound words that distort UI alignment.
- **Action Buttons & Modal Controls**:
  - Single-line action buttons (`Restart now`, `Restart later`, `Create`, `Cancel`, `Close`, `OK`) MUST stay within tight character bounds (<= 14–18 chars) to avoid text truncation or awkward wrapping on small e-ink screens.
- **Automated Auditing**:
  - Run `python tools/audit_translations.py` to automatically audit and flag un-wrapped UI strings, missing keys, empty keys, and length violations.

## 3. Localization Best Practices
- **Format Specifiers**: Retain all format specifiers (`%s`, `%d`, `%1$s`) exactly in translated strings.
- **Brand Protection**: Terms like `KOReader`, `Beam`, `Cloudflare`, `SHA-256`, `TAR`, and `GZIP` must remain un-translated.
- **Positional Reordering**: When target languages require a different phrase structure, use positional tokens (`%1$s`, `%2$d`) rather than re-ordering un-indexed `%s` specifiers.
