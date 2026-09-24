#!/usr/bin/env python3
import sys
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import audit_translations

if __name__ == '__main__':
    issues = audit_translations.run_audit()
    sys.exit(0 if issues == 0 else 1)
