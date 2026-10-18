@echo off
REM ---------------------------------------------------------------------------
REM sim.cmd - run one of the testbenches
REM ---------------------------------------------------------------------------
REM   scripts\sim.cmd readout    moe_proto_top: 256-lane comparison + checksum
REM   scripts\sim.cmd board      board top: checksum + LED verdict
REM   scripts\sim.cmd engine     gemv_engine only, via run_sim.tcl (with waveform)
REM   scripts\sim.cmd gl         gate level on the ROUTED netlist
REM
REM Working directory: the whole flow runs from the repository root, because the
REM memories are loaded with RELATIVE paths (sim/data/input.mem, and
REM mem_init/expert0/gate_r*.mem) and $readmemh resolves at RUNTIME.  Running
REM xsim from a build directory silently produces an empty memory instead of an
REM error, which is much worse than a dirty directory.
REM
REM Consequence: xsim and xelab drop xsim.dir, xsim.log, xelab.log, webtalk.*,
REM xvlog.log and .wdb files into the repository root.  At one point there were
REM 30+ of them.  So every mode ends with a sweep that moves them into
REM build\logs\<mode>\, leaving the root clean.
REM
REM Vivado is installed on D: on this machine, not C:.
REM ---------------------------------------------------------------------------
setlocal

set "MODE=%~1"
set "XIL=D:\Xilinx\Vivado\2019.1\bin"
set "GLBL=D:\Xilinx\Vivado\2019.1\data\verilog\src\glbl.v"

for %%I in ("%~dp0..") do set "ROOT=%%~fI"
cd /d "%ROOT%"

if "%MODE%"=="" goto usage

set "INC=-i "%ROOT%\rtl\include""

set "RTL=%ROOT%\rtl\core\fp4_select.v %ROOT%\rtl\core\fp4_product_gen.v %ROOT%\rtl\core\mac_lane.v %ROOT%\rtl\core\mac_region.v %ROOT%\rtl\mem\wbank_region.v %ROOT%\rtl\mem\act_buffer.v %ROOT%\rtl\mem\vec_buffer.v %ROOT%\rtl\core\gemv_engine.v %ROOT%\rtl\core\expert_engine.v %ROOT%\rtl\core\result_readout.v %ROOT%\rtl\top\moe_proto_top.v"

set "WORK=%ROOT%\build\logs\%MODE%"
if not exist "%WORK%" mkdir "%WORK%"

if /I "%MODE%"=="readout" goto readout
if /I "%MODE%"=="board"   goto board
if /I "%MODE%"=="engine"  goto engine
if /I "%MODE%"=="gl"      goto gl
goto usage

REM ===========================================================================
:readout
REM -timescale is mandatory: the testbenches carry timescale directives but the
REM RTL files do not, and xelab refuses to mix the two.
call "%XIL%\xvlog.bat" %INC% %RTL% "%ROOT%\sim\tb\tb_result_readout.v"
if errorlevel 1 goto fail
call "%XIL%\xelab.bat" tb_result_readout -debug typical -timescale 1ns/1ps -s tb_rd
if errorlevel 1 goto fail
call "%XIL%\xsim.bat" tb_rd -R
set "RC=%ERRORLEVEL%"
goto sweep

REM ===========================================================================
:board
REM ibufds_stub supplies IBUFDS and BUFG, which live in unisims and are unknown
REM to plain RTL elaboration.
call "%XIL%\xvlog.bat" %INC% %RTL% "%ROOT%\rtl\top\moe_proto_board.v" "%ROOT%\sim\tb\ibufds_stub.v" "%ROOT%\sim\tb\tb_moe_board.v"
if errorlevel 1 goto fail
call "%XIL%\xelab.bat" tb_moe_board -debug typical -timescale 1ns/1ps -s tb_board
if errorlevel 1 goto fail
call "%XIL%\xsim.bat" tb_board -R
set "RC=%ERRORLEVEL%"
goto sweep

REM ===========================================================================
:engine
REM Delegated to Tcl because that flow also writes a waveform database.
call "%XIL%\vivado.bat" -mode batch -nolog -nojournal -notrace -source "%ROOT%\scripts\run_sim.tcl"
set "RC=%ERRORLEVEL%"
goto sweep

REM ===========================================================================
:gl
echo ==== gate level: this simulates the ROUTED netlist, not the RTL.
if not exist "%ROOT%\build\moe\netsim\moe_netlist.v" (
    echo ==== ERROR: build\moe\netsim\moe_netlist.v is missing.
    echo ====        Export it first:  vivado -mode batch -source scripts\netlist_sim.tcl
    exit /b 4
)
REM unisims supplies the real RAMB/FDRE/LUT primitives; glbl supplies GSR.
call "%XIL%\xvlog.bat" "%ROOT%\build\moe\netsim\moe_netlist.v" "%ROOT%\sim\tb\tb_moe_board_gl.v" "%GLBL%"
if errorlevel 1 goto fail
call "%XIL%\xelab.bat" tb_moe_board_gl glbl -L unisims_ver -L secureip -s tb_gl
if errorlevel 1 goto fail
call "%XIL%\xsim.bat" tb_gl -R
set "RC=%ERRORLEVEL%"
goto sweep

REM ===========================================================================
:sweep
REM Move everything xsim/xelab/xvlog left in the repository root into the work
REM directory, so a run does not litter the tree.
REM
REM The destination must be cleared first.  "move /y" does not overwrite a
REM DIRECTORY, it fails - and with stderr redirected to nul that failure was
REM invisible, so on the second and later runs of a mode xsim.dir stayed in the
REM repository root.  That is how a 5 MB xsim.dir reappeared after the tree had
REM been cleaned.
for %%F in (xsim.dir .Xil) do (
    if exist "%WORK%\%%F" rmdir /s /q "%WORK%\%%F" >nul 2>&1
)
for %%F in (xsim.dir xsim.jou xsim.log xelab.log xelab.pb xvlog.log xvlog.pb webtalk.jou webtalk.log .Xil) do (
    if exist "%ROOT%\%%F" move /y "%ROOT%\%%F" "%WORK%\" >nul 2>&1
)
for %%F in ("%ROOT%\*.wdb" "%ROOT%\webtalk_*.jou" "%ROOT%\webtalk_*.log" "%ROOT%\xsim_*.jou" "%ROOT%\xsim_*.log") do (
    if exist "%%~fF" move /y "%%~fF" "%WORK%\" >nul 2>&1
)
REM A silent move is indistinguishable from a working one.  Check.
set "LEFT=0"
for %%F in (xsim.dir .Xil xsim.log xelab.log xvlog.log webtalk.log) do (
    if exist "%ROOT%\%%F" set "LEFT=1"
)
if "%LEFT%"=="1" (
    echo ==== WARNING: some artefacts are still in the repository root ^(see above^)
) else (
    echo ==== artefacts moved to build\logs\%MODE%
)
exit /b %RC%

REM ===========================================================================
:fail
set "RC=%ERRORLEVEL%"
goto sweep

REM ===========================================================================
:usage
echo usage: %~nx0 ^<readout^|board^|engine^|gl^>
echo.
echo   readout   moe_proto_top:   256-lane comparison + checksum
echo   board     moe_proto_board: checksum and the LED PASS/FAIL verdict
echo   engine    gemv_engine only, via run_sim.tcl (also dumps a waveform)
echo   gl        gate level on the routed netlist (export it first)
exit /b 2
