#!/usr/bin/env python3
"""
Populates all 18 target language .po files for backup.koplugin with 100% key parity,
matching Storefront's translation conventions and e-ink UI character constraints.
"""

import os
import sys
import hashlib

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PLUGIN_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, '..', 'backup.koplugin'))
if not os.path.exists(PLUGIN_DIR):
    PLUGIN_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, '..'))

import importlib.util

SPEC = importlib.util.spec_from_file_location("sync_translations", os.path.join(PLUGIN_DIR, 'tools', 'sync_translations.py'))
sync_translations = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync_translations)

sys.path.insert(0, SCRIPT_DIR)
import lang_data_1
import lang_data_2
import lang_data_3

STOREFRONT_LANG_DIR = "C:/Users/jpautz/Documents/storefront/storefront.koplugin/storefront.koplugin/languages"

# Load storefront translations for common keys
sf_translations = {}
if os.path.exists(STOREFRONT_LANG_DIR):
    for f in os.listdir(STOREFRONT_LANG_DIR):
        if f.endswith('.po'):
            code = f.replace('.po', '')
            entries = sync_translations.parse_po(os.path.join(STOREFRONT_LANG_DIR, f))
            sf_translations[code] = {e['msgid']: e['msgstr'] for e in entries if e['msgid'] and e['msgstr']}

# Base translations dictionary from the 3 modules + local
TRANSLATIONS = {}

# Merge groups
for grp in [lang_data_1.DATA, lang_data_2.DATA, lang_data_3.DATA]:
    for lang, tr_map in grp.items():
        if lang not in TRANSLATIONS:
            TRANSLATIONS[lang] = {}
        TRANSLATIONS[lang].update(tr_map)

# Add es, de, fr, zh_CN, pt_br if not in grp
from populate_translations_base import BASE_DATA
for lang, tr_map in BASE_DATA.items():
    if lang not in TRANSLATIONS:
        TRANSLATIONS[lang] = {}
    TRANSLATIONS[lang].update(tr_map)

ADDITIONAL_KEYS = {
    'ar': {
        'Beam Relay Server': 'خادم ترحيل Beam',
        'Failed to inspect archive:\n%s': 'فشل فحص الأرشيف:\n%s',
        'Restart': 'إعادة التشغيل',
        'Restore failed: %s': 'فشلت الاستعادة: %s',
        'Undo failed: %s': 'فشل التراجع: %s',
        '%d backups found in this folder': 'تم العثور على %d نسخة احتياطية في هذا المجلد',
    },
    'de': {
        'Beam Relay Server': 'Beam-Relay-Server',
        'Failed to inspect archive:\n%s': 'Archivprüfung fehlgeschlagen:\n%s',
        'Restart': 'Neustart',
        'Restore failed: %s': 'Wiederherstellung fehlgeschlagen: %s',
        'Undo failed: %s': 'Rückgängigmachen fehlgeschlagen: %s',
        '%d backups found in this folder': '%d Sicherungen in diesem Ordner gefunden',
    },
    'es': {
        'Beam Relay Server': 'Servidor de retransmisión Beam',
        'Failed to inspect archive:\n%s': 'Error al inspeccionar el archivo:\n%s',
        'Restart': 'Reiniciar',
        'Restore failed: %s': 'Error al restaurar: %s',
        'Undo failed: %s': 'Error al deshacer: %s',
        '%d backups found in this folder': 'Se encontraron %d copias de seguridad en esta carpeta',
    },
    'fr': {
        'Beam Relay Server': 'Serveur relais Beam',
        'Failed to inspect archive:\n%s': "Échec de l'inspection de l'archive :\n%s",
        'Restart': 'Redémarrer',
        'Restore failed: %s': 'Échec de la restauration : %s',
        'Undo failed: %s': "Échec de l'annulation : %s",
        '%d backups found in this folder': '%d sauvegardes trouvées dans ce dossier',
    },
    'hu': {
        'Beam Relay Server': 'Beam továbbító szerver',
        'Failed to inspect archive:\n%s': 'Nem sikerült ellenőrizni az archívumot:\n%s',
        'Restart': 'Újraindítás',
        'Restore failed: %s': 'A visszaállítás sikertelen: %s',
        'Undo failed: %s': 'A visszavonás sikertelen: %s',
        '%d backups found in this folder': '%d biztonsági mentés található ebben a mappában',
    },
    'id': {
        'Beam Relay Server': 'Server Relai Beam',
        'Failed to inspect archive:\n%s': 'Gagal memeriksa arsip:\n%s',
        'Restart': 'Mulai Ulang',
        'Restore failed: %s': 'Pemulihan gagal: %s',
        'Undo failed: %s': 'Batal gagal: %s',
        '%d backups found in this folder': '%d cadangan ditemukan di folder ini',
    },
    'it': {
        'Beam Relay Server': 'Server relay Beam',
        'Failed to inspect archive:\n%s': "Impossibile ispezionare l'archivio:\n%s",
        'Restart': 'Riavvia',
        'Restore failed: %s': 'Ripristino non riuscito: %s',
        'Undo failed: %s': 'Annullamento non riuscito: %s',
        '%d backups found in this folder': '%d backup trovati in questa cartella',
    },
    'ja': {
        'Beam Relay Server': 'Beam リレーサーバー',
        'Failed to inspect archive:\n%s': 'アーカイブの検査に失敗しました:\n%s',
        'Restart': '再起動',
        'Restore failed: %s': '復元に失敗しました: %s',
        'Undo failed: %s': '元に戻せませんでした: %s',
        '%d backups found in this folder': 'このフォルダ内で %d 個のバックアップが見つかりました',
    },
    'ko': {
        'Beam Relay Server': 'Beam 릴레이 서버',
        'Failed to inspect archive:\n%s': '아카이브를 검사하지 못했습니다:\n%s',
        'Restart': '재시작',
        'Restore failed: %s': '복원 실패: %s',
        'Undo failed: %s': '실행 취소 실패: %s',
        '%d backups found in this folder': '이 폴더에서 백업 %d개를 찾았습니다',
    },
    'nl': {
        'Beam Relay Server': 'Beam-relayserver',
        'Failed to inspect archive:\n%s': 'Kan archief niet inspecteren:\n%s',
        'Restart': 'Herstarten',
        'Restore failed: %s': 'Herstellen mislukt: %s',
        'Undo failed: %s': 'Ongedaan maken mislukt: %s',
        '%d backups found in this folder': '%d reservekopieën gevonden in deze map',
    },
    'pl': {
        'Beam Relay Server': 'Serwer przekaźnikowy Beam',
        'Failed to inspect archive:\n%s': 'Nie udało się sprawdzić archiwum:\n%s',
        'Restart': 'Uruchom ponownie',
        'Restore failed: %s': 'Przywracanie nie powiodło się: %s',
        'Undo failed: %s': 'Cofnięcie nie powiodło się: %s',
        '%d backups found in this folder': 'Znaleziono %d kopii zapasowych w tym folderze',
    },
    'pt_br': {
        'Beam Relay Server': 'Servidor de retransmissão Beam',
        'Failed to inspect archive:\n%s': 'Falha ao inspecionar o arquivo:\n%s',
        'Restart': 'Reiniciar',
        'Restore failed: %s': 'Falha na restauração: %s',
        'Undo failed: %s': 'Falha ao desfazer: %s',
        '%d backups found in this folder': '%d backups encontrados nesta pasta',
    },
    'ru': {
        'Beam Relay Server': 'Сервер ретрансляции Beam',
        'Failed to inspect archive:\n%s': 'Не удалось проверить архив:\n%s',
        'Restart': 'Перезагрузить',
        'Restore failed: %s': 'Сбой восстановления: %s',
        'Undo failed: %s': 'Сбой отмены: %s',
        '%d backups found in this folder': 'В этой папке найдено резервных копий: %d',
    },
    'sk': {
        'Beam Relay Server': 'Relay server Beam',
        'Failed to inspect archive:\n%s': 'Nepodarilo sa skontrolovať archív:\n%s',
        'Restart': 'Reštartovať',
        'Restore failed: %s': 'Obnovenie zlyhalo: %s',
        'Undo failed: %s': 'Vrátenie späť zlyhalo: %s',
        '%d backups found in this folder': '%d záloh v tomto priečinku',
    },
    'sr': {
        'Beam Relay Server': 'Beam релејни сервер',
        'Failed to inspect archive:\n%s': 'Неуспела провера архиве:\n%s',
        'Restart': 'Поново покрени',
        'Restore failed: %s': 'Враћање није успело: %s',
        'Undo failed: %s': 'Опозивање није успело: %s',
        '%d backups found in this folder': 'Пронађено је %d резервних копија у овој фасцикли',
    },
    'tr': {
        'Beam Relay Server': 'Beam Aktarım Sunucusu',
        'Failed to inspect archive:\n%s': 'Arşiv denetlenemedi:\n%s',
        'Restart': 'Yeniden Başlat',
        'Restore failed: %s': 'Geri yükleme başarısız: %s',
        'Undo failed: %s': 'Geri alma başarısız: %s',
        '%d backups found in this folder': 'Bu klasörde %d yedek bulundu',
    },
    'uk': {
        'Beam Relay Server': 'Сервер ретрансляції Beam',
        'Failed to inspect archive:\n%s': 'Не вдалося перевірити архів:\n%s',
        'Restart': 'Перезапустити',
        'Restore failed: %s': 'Помилка відновлення: %s',
        'Undo failed: %s': 'Помилка скасування: %s',
        '%d backups found in this folder': 'У цій папці знайдено %d резервних копій',
    },
    'zh_CN': {
        'Beam Relay Server': 'Beam 中继服务器',
        'Failed to inspect archive:\n%s': '检查归档失败：\n%s',
        'Restart': '重启',
        'Restore failed: %s': '恢复失败：%s',
        'Undo failed: %s': '撤消失败：%s',
        '%d backups found in this folder': '在此文件夹中找到 %d 个备份',
    },
}

for lang, tr_map in ADDITIONAL_KEYS.items():
    if lang not in TRANSLATIONS:
        TRANSLATIONS[lang] = {}
    TRANSLATIONS[lang].update(tr_map)

def main():
    print("--- Populating All 18 Target Language PO Catalogs ---")
    en_path = os.path.join(PLUGIN_DIR, 'languages', 'en.po')
    en_entries = sync_translations.parse_po(en_path)
    en_keys = [e['msgid'] for e in en_entries if e['msgid']]
    en_final = {e['msgid']: e['msgstr'] for e in en_entries if e['msgid']}
    fallback_map = {}

    print(f"Total Master English Keys: {len(en_keys)}")

    for lang_code, lang_name in sorted(sync_translations.LANG_NAMES.items()):
        if lang_code == 'en':
            continue

        target_po = os.path.join(PLUGIN_DIR, 'languages', f'{lang_code}.po')
        lang_dict = TRANSLATIONS.get(lang_code, {})
        sf_dict = sf_translations.get(lang_code, {})

        final_tr = {}
        for key in en_keys:
            # 1. Prefer curated translation
            val = lang_dict.get(key)
            # 2. Fall back to storefront common translation if missing
            if not val and key in sf_dict:
                val = sf_dict[key]
            # 3. Allowlist / fallback
            if not val and key in sync_translations.ALLOWLIST:
                val = key
            if not val:
                print(f"WARNING: Missing translation for [{lang_code}] '{key}'")
                val = ""
            final_tr[key] = val

        sync_translations.save_po(target_po, lang_name, lang_code, en_keys, final_tr, fallback_map, en_final)
        print(f"✅ Generated {lang_code}.po ({lang_name}): {len(final_tr)} keys")

    print("\n--- Running Audit to Verify 100% Parity ---")
    SPEC_AUDIT = importlib.util.spec_from_file_location("audit_translations", os.path.join(PLUGIN_DIR, 'tools', 'audit_translations.py'))
    audit_translations = importlib.util.module_from_spec(SPEC_AUDIT)
    SPEC_AUDIT.loader.exec_module(audit_translations)
    issues = audit_translations.run_audit()
    return issues

if __name__ == '__main__':
    sys.exit(main())
