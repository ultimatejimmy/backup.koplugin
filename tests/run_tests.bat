@echo off
for /f "tokens=*" %%i in ('wsl wslpath -u "%~dp0.."') do set WSL_DIR=%%i
wsl bash -c "cd '%WSL_DIR%' && ./tests/run_tests.sh %*"
