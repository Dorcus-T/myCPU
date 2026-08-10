@echo off
chcp 65001 >nul
setlocal

set CHIPLAB_HOME=Z:\home\dorcus_t\chiplab
set WSL_CHIPLAB=/home/dorcus_t/chiplab
set WSL_TOOL=%WSL_CHIPLAB%/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin
set RUN_DIR=%WSL_CHIPLAB%/sims/verilator/run_prog
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
echo   Linux Boot Simulation (Verilator)
echo   (difftest: NEMU compare enabled - default)
if "%DIFFTEST%"=="--disable-trace-comp" echo   (difftest: disabled -n)
if "%PC_TRACE%"=="--show-pc-info" echo   (verbose: per-cycle PC)
if "%DUMP_WAVE%"=="--dump-waveform 1" echo   (waveform: fst, 注意内核仿真波形巨大)
if "%LIGHTSSS%"=="--fork-child 1" echo   (lightSSS waveform)
echo   timeout: %TIME_OUT% s  (默认 1800，可 -t 秒数)
echo ===============================================================
echo.

REM wsl.exe 无法从 Z: 盘目录启动，先切到 C:\ 再调用（所有命令均用绝对路径）
pushd C:\

echo [1/4] Configuring simulation (--run linux)...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && cd %RUN_DIR% && rm -f config-software.mak && bash ./configure.sh --run linux %DIFFTEST% --output-uart-info"
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

echo [3/4] Building linux image (vmlinux -^> rom.vlog)...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && export PATH=%WSL_TOOL%:$PATH && cd %RUN_DIR% && make soft"
if errorlevel 1 (
    echo ERROR: linux image build failed!
    pause
    exit /b 1
)
echo    Linux image OK.
echo.

echo [4/4] Running Linux boot simulation (timeout %TIME_OUT% s)...
echo   内核不会自动结束，timeout 后自动停止；串口输出实时显示
echo.
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && cd %RUN_DIR% && rm -rf tmp && mkdir -p tmp && cp obj/linux_obj/obj/rom.vlog tmp/ && cat tmp/rom.vlog > tmp/ram.dat && cd tmp && ln -sf ../Makefile_run . && timeout %TIME_OUT% ../output --dump-delay 0 %DUMP_WAVE% --time-limit 0 %PC_TRACE% %LIGHTSSS% --end-pc 1c000010 2>&1 | tee linux_run.log"
echo.
echo ===============================================================
echo   Simulation finished (timeout %TIME_OUT% s).
echo   Full log: %CHIPLAB_HOME%\sims\verilator\run_prog\tmp\linux_run.log
echo   UART    : %CHIPLAB_HOME%\sims\verilator\run_prog\tmp\uart_output.txt
echo   看内核启动进度: 搜索 linux_run.log 里的 [    0.000000] 行
echo ===============================================================
pause
