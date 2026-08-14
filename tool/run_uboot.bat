@echo off
chcp 65001 >nul
setlocal

set CHIPLAB_HOME=Z:\home\dorcus_t\chiplab
set WSL_CHIPLAB=/home/dorcus_t/chiplab
set WSL_TOOL=%WSL_CHIPLAB%/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin
set RUN_DIR=%WSL_CHIPLAB%/sims/verilator/run_prog
set UBOOT_DIR=%WSL_CHIPLAB%/software/examples/uboot
set TIME_OUT=1800
set DUMP_WAVE=
set LIGHTSSS=
set PC_TRACE=
set DIFFTEST=

:parse_args
if /i "%1"=="-w" set DUMP_WAVE=--dump-waveform 1
if /i "%1"=="-l" set LIGHTSSS=--fork-child 1
if /i "%1"=="-v" set PC_TRACE=--show-pc-info
if /i "%1"=="-n" set DIFFTEST=--disable-trace-comp
if /i "%1"=="-t" set TIME_OUT=%2
if /i "%1"=="-t" shift
shift
if not "%1"=="" goto parse_args

echo ===============================================================
echo   U-Boot Simulation (Verilator)
echo   (difftest: NEMU compare enabled - default)
if "%DIFFTEST%"=="--disable-trace-comp" echo   (difftest: disabled -n)
if "%PC_TRACE%"=="--show-pc-info" echo   (verbose: per-cycle PC)
if "%DUMP_WAVE%"=="--dump-waveform 1" echo   (waveform: fst, 注意波形巨大)
if "%LIGHTSSS%"=="--fork-child 1" echo   (lightSSS waveform)
echo   timeout: %TIME_OUT% s  (默认 1800，可 -t 秒数)
echo ===============================================================
echo.

REM wsl.exe 无法从 Z: 盘目录启动，先切到 C:\ 再调用（所有命令均用绝对路径）
pushd C:\

echo [1/4] Configuring simulation (--run linux 配置)...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && cd %RUN_DIR% && rm -f config-software.mak && bash ./configure.sh --run linux %DIFFTEST% --disable-simu-trace --output-uart-info"
if errorlevel 1 (
    echo ERROR: Configure failed!
    pause
    exit /b 1
)
echo    Configure OK.
echo.

echo [2/4] Compiling Verilator model + testbench...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && cd %RUN_DIR% && make compile"
if errorlevel 1 (
    echo ERROR: Compile failed!
    pause
    exit /b 1
)
echo    Compile OK.
echo.

echo [3/4] Building u-boot image (start_uboot + u-boot.bin -^> rom.vlog)...
wsl -d Ubuntu-22.04 -e bash -c "export PATH=%WSL_TOOL%:$PATH && cd %UBOOT_DIR% && bash script.sh"
if errorlevel 1 (
    echo ERROR: u-boot image build failed!
    pause
    exit /b 1
)
echo    U-Boot image OK.
echo.

echo [4/4] Running U-Boot simulation (timeout %TIME_OUT% s)...
echo   u-boot 不会自动结束，timeout 后自动停止；串口输出实时显示
echo.
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && cd %RUN_DIR% && rm -rf tmp && mkdir -p tmp && cp %UBOOT_DIR%/rom.vlog tmp/ && cat tmp/rom.vlog > tmp/ram.dat && cd tmp && ln -sf ../Makefile_run . && timeout %TIME_OUT% ../output --dump-delay 0 %DUMP_WAVE% --time-limit 0 %PC_TRACE% %LIGHTSSS% --end-pc 1c000010 2>&1 | tee uboot_run.log"
echo.
echo ===============================================================
echo   Simulation finished (timeout %TIME_OUT% s).
echo   Full log: %CHIPLAB_HOME%\sims\verilator\run_prog\tmp\uboot_run.log
echo   UART    : %CHIPLAB_HOME%\sims\verilator\run_prog\tmp\uart_output.txt
echo ===============================================================
pause
