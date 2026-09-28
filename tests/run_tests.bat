@echo off
wsl bash -c "cd /mnt/c/Users/jpautz/Documents/backup/backup.koplugin && ./tests/run_tests.sh %*"
