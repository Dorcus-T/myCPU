@echo off
chcp 65001 >nul
setlocal

set CHIPLAB_HOME=Z:\home\dorcus_t\chiplab
set WSL_CHIPLAB=/home/dorcus_t/chiplab
set WSL_TOOL=%WSL_CHIPLAB%/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin
set WSL_RANDOM=%WSL_CHIPLAB%/sims/verilator/run_random
set WSL_RES=%WSL_CHIPLAB%/software/examples/random_res
set DUMP_WAVE=
set LIGHTSSS=0
set CASE=
set SHOW_NOTE=

:parse_args
if /i "%1"=="-w" set DUMP_WAVE=1
if /i "%1"=="-l" set LIGHTSSS=1
if /i "%1"=="-v" set SHOW_NOTE=1
if /i "%1"=="-d" set SHOW_NOTE=1
if not "%1"=="-w" if not "%1"=="-l" if not "%1"=="-v" if not "%1"=="-d" if not "%1"=="" set CASE=%1
shift
if not "%1"=="" goto parse_args
if "%SHOW_NOTE%"=="1" (
    echo NOTE: random 测试必须 difftest NEMU 比对，-d 无效
    echo       -v 逐指令打印会爆慢；PC 记录在 log\case名\simu_trace.txt 中
)

echo ===============================================================
echo   Random Test (Verilator difftest)
echo ===============================================================
echo.

REM wsl.exe 无法从 Z: 盘目录启动，先切到 C:\ 再调用（所有命令均用绝对路径）
pushd C:\

REM [0/3] 检查测试用例
wsl -d Ubuntu-22.04 -e bash -c "d=%WSL_RES%; [ -d $d ] && ls -A $d | grep -q . && echo OK || echo NO_RES" > "%TEMP%\res_check.txt"
set /p RES_CHECK=<"%TEMP%\res_check.txt"
del "%TEMP%\res_check.txt"
if "%RES_CHECK%"=="NO_RES" (
    echo ERROR: random_res 目录为空或不存在！
    echo    %WSL_RES%
    echo   请先下载 random_res_*.tar.bz2 提取码 sHJS，解压后把 RES_cluster_* / RES_jump_* 文件夹放入该目录
    pause
    exit /b 1
)
echo    random_res: OK
echo.

if "%CASE%"=="" goto run_all
goto run_one

:run_one
echo ===============================================================
echo   单跑测试用例: %CASE%
if "%DUMP_WAVE%"=="1" echo   (waveform: vcd enabled)
if "%LIGHTSSS%"=="1" echo   (lightSSS waveform: fork_simu_trace)
echo ===============================================================
echo.
echo [1/3] Preparing test case...
wsl -d Ubuntu-22.04 -e bash -c "export PATH=%WSL_TOOL%:$PATH && export CHIPLAB_HOME=%WSL_CHIPLAB% && cd %WSL_RANDOM% && if [ ! -f obj_dir/Vsimu_top.mk ] || find %WSL_CHIPLAB%/IP/myCPU -name '*.v' -newer obj_dir/Vsimu_top.mk 2>/dev/null | grep -q .; then echo '  CPU 源码已修改，重新编译模型...' && make link verilator testbench || exit 1; else echo '  模型已最新'; fi && make all -C ../../../software/examples/random_boot/ ./Makefile >/dev/null 2>&1 && cd run_random && if [ ! -d %CASE% ]; then make prepare -f ./Makefile; fi && cd %CASE% && make simulation_run_random -f ../../Makefile_run CASENAME=%CASE% DUMP_WAVEFORM=%DUMP_WAVE% FORK_CHILD=%LIGHTSSS%"
if errorlevel 1 (
    echo ERROR: Test failed!
    pause
    exit /b 1
)
echo.
echo ===============================================================
echo   Test finished.
echo   Log: %CHIPLAB_HOME%\sims\verilator\run_random\log\%CASE%\run.log
if "%DUMP_WAVE%"=="1" echo   Waveform: %CHIPLAB_HOME%\sims\verilator\run_random\log\%CASE%\simu_trace.vcd (gtkwave)
if "%LIGHTSSS%"=="1" echo   LightSSS waveform: %CHIPLAB_HOME%\sims\verilator\run_random\log\%CASE%\fork_simu_trace.fst
echo ===============================================================
pause
goto :eof

:run_all
echo [1/3] Compiling Verilator model + testbench + rand_boot...
if "%DUMP_WAVE%"=="1" echo   (waveform: vcd enabled for all cases)
if "%LIGHTSSS%"=="1" echo   (lightSSS waveform enabled for all cases)
wsl -d Ubuntu-22.04 -e bash -c "export PATH=%WSL_TOOL%:$PATH && export CHIPLAB_HOME=%WSL_CHIPLAB% && cd %WSL_RANDOM% && make random DUMP_WAVEFORM=%DUMP_WAVE% FORK_CHILD=%LIGHTSSS%"
if errorlevel 1 (
    echo ERROR: Random test failed!
    pause
    exit /b 1
)
echo.
echo ===============================================================
echo   All tests finished.
echo ===============================================================
echo   Result summary:
wsl -d Ubuntu-22.04 -e bash -c "cd %WSL_RANDOM% && echo PASS: $(grep -l PASS log/*/run.log 2>/dev/null | wc -l) cases && echo FAIL: $(grep -l wrong log/*/run.log 2>/dev/null | wc -l) cases && echo --- && grep -Hs wrong log/*/run.log 2>/dev/null | head -10"
echo.
echo   Logs: %CHIPLAB_HOME%\sims\verilator\run_random\log\
echo   Single case log: log\case名\run.log, PC trace: log\case名\simu_trace.txt
echo   Re-run one case: run_random.bat case名 [-w] [-l]
echo   Options: -w (vcd waveform)  -l (lightSSS fork waveform)
echo           -v/-d 无效（random 必须 difftest，PC 见 simu_trace.txt）
pause
