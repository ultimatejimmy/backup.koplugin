#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
busted tests -p _test "$@"
