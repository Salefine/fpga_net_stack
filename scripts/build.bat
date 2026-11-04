@echo off
setlocal EnableDelayedExpansion

rem ============================================================
rem  build.bat - integrated FPGA build script (all boards)
rem
rem  Single Windows entry point for every example design. Pick a
rem  board from the menu; the Vivado project is created/restored
rem  directly in example\BOARD\fpga by the parameterized Tcl
rem  embedded at the end of this file: the network-stack RTL list
rem  is shared, the part number comes from the board table in the
rem  :board_cfg subroutine below.
rem
rem  Adding a new board:
rem    1. create example\BOARD\fpga and example\BOARD\rtl
rem    2. add board sources (rtl\*.v / *.sv, top module "fpga")
rem       and constraints (example\BOARD\*.xdc, *.tcl)
rem    3. add the board's part number to :board_cfg below
rem
rem  Usage:
rem    build.bat                    board menu, then open project (GUI)
rem    build.bat TARGET             board menu, then run with TARGET
rem    build.bat BOARD              run BOARD directly (default target: open)
rem    build.bat BOARD TARGET       run BOARD directly, non-interactive
rem    build.bat list               list boards
rem    build.bat help               show this help
rem
rem  Targets:
rem    fpga    create/restore the Vivado project (Vivado batch mode)
rem    open    open the project in the Vivado GUI (default)
rem    clean   delete generated Vivado files (keeps all sources)
rem    help    show this help
rem
rem  Linux: use the Makefile in example\BOARD\fpga instead.
rem ============================================================

for %%R in ("%~dp0..") do set "REPO_ROOT=%%~fR"

rem ---- Vivado installation ------------------------------------
set "VIVADO_HOME=%VIVADO_2024_2%"
if not defined VIVADO_HOME set "VIVADO_HOME=D:\tools\xilinx2024.2\Vivado\2024.2"
if not exist "%VIVADO_HOME%\bin\vivado.bat" set "VIVADO_HOME=C:\Xilinx\Vivado\2024.2"
set "VIVADO=%VIVADO_HOME%\bin\vivado.bat"

rem ---- discover boards (any example\NAME\fpga directory) ------
set "COUNT=0"
for /d %%D in ("%REPO_ROOT%\example\*") do (
    if exist "%%D\fpga\" (
        set /a COUNT+=1
        set "DEV_!COUNT!=%%~nxD"
    )
)
if %COUNT%==0 (
    echo ERROR: no boards found under "%REPO_ROOT%\example".
    exit /b 1
)

rem ---- parse arguments ----------------------------------------
set "ARG1=%~1"
set "ARG2=%~2"
set "DEVICE="
set "TARGET="

if not defined ARG1 goto :parsed
if /i "%ARG1%"=="list"     goto :list
if /i "%ARG1%"=="help"     goto :help
if /i "%ARG1%"=="-h"       goto :help
if /i "%ARG1%"=="--help"   goto :help
if /i "%ARG1%"=="/?"       goto :help

for /l %%I in (1,1,%COUNT%) do if /i "!DEV_%%I!"=="%ARG1%" set "DEVICE=%ARG1%"
if defined DEVICE (set "TARGET=%ARG2%") else set "TARGET=%ARG1%"
:parsed
if not defined TARGET set "TARGET=open"

if defined DEVICE goto :run

rem ---- interactive board menu ---------------------------------
:menu
echo.
echo ============================================================
echo  Select an FPGA board:
echo ============================================================
for /l %%I in (1,1,%COUNT%) do (
    set "NAME=!DEV_%%I!"
    call :check_impl "!NAME!"
    if "!IMPL!"=="1" (set "STAT=") else set "STAT=    [not implemented yet]"
    echo    [%%I] !NAME!!STAT!
)
echo ------------------------------------------------------------

:ask
set "CHOICE="
set /p "CHOICE=Select board [1-%COUNT%] or name (q=quit): "
if not defined CHOICE goto :cancelled
if /i "%CHOICE%"=="q" goto :cancelled

set "DEVICE="
for /l %%I in (1,1,%COUNT%) do if /i "%CHOICE%"=="%%I" set "DEVICE=!DEV_%%I!"
if not defined DEVICE (
    for /l %%I in (1,1,%COUNT%) do if /i "!DEV_%%I!"=="%CHOICE%" set "DEVICE=!DEV_%%I!"
)
if not defined DEVICE (
    echo Invalid choice: %CHOICE%
    echo.
    goto :ask
)

rem ---- run the selected board ---------------------------------
:run
call :board_cfg "%DEVICE%"
if not defined PART goto :no_part
call :check_impl "%DEVICE%"
if "%IMPL%"=="0" goto :not_implemented

set "PROJ_DIR=%REPO_ROOT%\example\%DEVICE%\fpga"
echo.
echo ============================================================
echo  [%DEVICE%] part %PART%  target %TARGET%
echo  %PROJ_DIR%
echo ============================================================

if /i "%TARGET%"=="fpga"    goto :create
if /i "%TARGET%"=="create"  goto :create
if /i "%TARGET%"=="open"    goto :open
if /i "%TARGET%"=="gui"     goto :open
if /i "%TARGET%"=="clean"   goto :clean
if /i "%TARGET%"=="clear"   goto :clean
goto :help

rem ---- create/restore the project ------------------------------
:create
if not exist "%VIVADO%" (
    echo ERROR: Vivado 2024.2 was not found at "%VIVADO%".
    echo Set VIVADO_2024_2 to the Vivado 2024.2 installation directory.
    exit /b 1
)
rem Extract the embedded Tcl (everything after the marker line)
set "TCL_FILE=%TEMP%\fpga_build_%DEVICE%_%RANDOM%.tcl"
set "SKIP=0"
for /f "delims=:" %%N in ('findstr /n /c:"#__TCL__" "%~f0"') do set /a SKIP=%%N
if "%SKIP%"=="0" (
    echo ERROR: embedded Tcl marker not found.
    exit /b 1
)
more +%SKIP% "%~f0" > "%TCL_FILE%"
if defined GT_QUAD (
    call "%VIVADO%" -mode batch -source "%TCL_FILE%" -tclargs "%PROJ_DIR%" "%PART%" "%GT_QUAD%"
) else (
    call "%VIVADO%" -mode batch -source "%TCL_FILE%" -tclargs "%PROJ_DIR%" "%PART%"
)
set "EXIT_CODE=%ERRORLEVEL%"
del /f /q "%TCL_FILE%" >nul 2>&1
if not "%EXIT_CODE%"=="0" (
    echo ERROR: Vivado project restore failed with exit code %EXIT_CODE%.
    exit /b %EXIT_CODE%
)
echo Project restored: %PROJ_DIR%\fpga.xpr
exit /b 0

rem ---- open the project in the GUI ------------------------------
:open
if not exist "%VIVADO%" (
    echo ERROR: Vivado 2024.2 was not found at "%VIVADO%".
    echo Set VIVADO_2024_2 to the Vivado 2024.2 installation directory.
    exit /b 1
)
if not exist "%PROJ_DIR%\fpga.xpr" (
    echo fpga.xpr not found - creating project first...
    call :create || exit /b 1
)
rem This console stays open (and shows Vivado messages) until the
rem GUI is closed.
call "%VIVADO%" "%PROJ_DIR%\fpga.xpr"
exit /b %ERRORLEVEL%

rem ---- clean generated files ------------------------------------
:clean
echo Cleaning %PROJ_DIR%
for %%F in (fpga.xpr fpga.srcs fpga.gen fpga.runs fpga.cache fpga.hw fpga.ip_user_files fpga.sim) do (
    if exist "%PROJ_DIR%\%%F\" (
        echo Removing %%F
        rd /s /q "%PROJ_DIR%\%%F"
    ) else if exist "%PROJ_DIR%\%%F" (
        echo Removing %%F
        del /f /q "%PROJ_DIR%\%%F"
    )
)
if exist "%PROJ_DIR%\.Xil" rd /s /q "%PROJ_DIR%\.Xil"
del /f /q "%PROJ_DIR%\vivado*.jou" >nul 2>&1
del /f /q "%PROJ_DIR%\vivado*.log" >nul 2>&1
echo Done.
exit /b 0

rem ---- list ------------------------------------------------------
:list
echo.
echo Available FPGA boards under %REPO_ROOT%\example:
for /l %%I in (1,1,%COUNT%) do (
    set "NAME=!DEV_%%I!"
    call :check_impl "!NAME!"
    if "!IMPL!"=="1" (set "STAT=") else set "STAT=  [not implemented yet]"
    echo   !NAME!!STAT!
)
echo.
echo Use: build.bat BOARD [fpga^|open^|clean]
exit /b 0

rem ---- per-board configuration ----------------------------------
:board_cfg
rem Sets PART (Vivado part number, required) and GT_QUAD (the
rem xxv_ethernet CONFIG.GT_GROUP_SELECT value; empty = IP default).
set "PART="
set "GT_QUAD="
if /i "%~1"=="xcvu5p" (
    set "PART=xcvu5p-flvb2104-2-i"
    set "GT_QUAD=Quad_X1Y5"
)
rem Alveo U200: set GT_QUAD to the quad wired to your QSFP/SFP cage
if /i "%~1"=="Alveo_U200" (
    set "PART=xcu200-fsgd2104-2-e"
)
goto :eof

rem ---- is the board implemented? --------------------------------
:check_impl
rem A board is implemented when its board files exist and are
rem non-empty: example\BOARD\fpga.xdc plus at least one non-empty
rem example\BOARD\rtl\*.v or *.sv file.
set "IMPL=1"
set "B_DIR=%REPO_ROOT%\example\%~1"
if not exist "%B_DIR%\fpga.xdc" set "IMPL=0" & goto :eof
for %%A in ("%B_DIR%\fpga.xdc") do if %%~zA EQU 0 set "IMPL=0"
if "%IMPL%"=="0" goto :eof
set "B_RTL=0"
for %%A in ("%B_DIR%\rtl\*.v" "%B_DIR%\rtl\*.sv") do if %%~zA GTR 0 set "B_RTL=1"
if "%B_RTL%"=="0" set "IMPL=0"
goto :eof

:no_part
echo.
echo ERROR: no part number configured for "%DEVICE%".
echo        Add it to :board_cfg inside scripts\build.bat.
exit /b 1

:not_implemented
echo.
echo ERROR: "%DEVICE%" is not implemented yet.
echo        Fill in the board files and try again:
echo          %REPO_ROOT%\example\%DEVICE%\fpga.xdc
echo          %REPO_ROOT%\example\%DEVICE%\rtl\fpga.sv
echo        You can start from a copy of example\xcvu5p.
exit /b 1

:cancelled
echo Cancelled.
exit /b 1

rem ---- help ------------------------------------------------------
:help
echo Usage: build.bat [board] [target]  ^|  list  ^|  help
echo.
echo   build.bat                    show board menu, then open project (GUI)
echo   build.bat ^<target^>           show board menu, then run with target
echo   build.bat ^<board^>           run board directly (default target: open)
echo   build.bat ^<board^> ^<target^>  run board directly, non-interactive
echo   build.bat list               list available boards
echo   build.bat help               show this help
echo.
echo Targets:
echo   fpga    create/restore the Vivado project (Vivado batch mode)
echo   open    open the project in the Vivado GUI (default)
echo   clean   delete generated Vivado files (keeps all sources)
echo   help    show this help
echo.
echo Boards currently available:
for /l %%I in (1,1,%COUNT%) do echo   !DEV_%%I!
echo.
echo Linux: use the Makefile in example^<board^>\fpga instead.
exit /b 0

#__TCL__
# Parameterized project restore script for example/BOARD/fpga, based on
# the recorded xcvu5p GUI session. The board part number (and optionally
# the xxv_ethernet GT quad) come from the command line.

if {$argc < 2} {
    error "Usage: vivado -mode batch -source <script> -tclargs <project-dir> <part> [gt-quad]"
}

set project_dir [file normalize [lindex $argv 0]]
set part        [lindex $argv 1]
set gt_quad     ""
if {$argc >= 3} { set gt_quad [lindex $argv 2] }
set repo_root   [file normalize [file join $project_dir .. .. ..]]

# Deterministic rebuild: drop any previous project artifacts
foreach item {fpga.xpr fpga.srcs fpga.gen fpga.runs fpga.cache fpga.hw fpga.ip_user_files fpga.sim} {
    set p [file join $project_dir $item]
    if {[file exists $p]} { file delete -force $p }
}

create_project fpga $project_dir -part $part -force

# ---- Network stack RTL (repo root rtl/) ------------------------------------
set rtl_files [list]
foreach f {
    rtl/phy/lfsr.v
    rtl/mac/axis_adapter.v
    rtl/icmp/icmp_tx.v
    rtl/icmp/icmp_layer.v
    rtl/udp_stack_top.v
    rtl/phy/eth_phy_10g_tx_if.v
    rtl/phy/sync_reset.v
    rtl/mac/mac_ctrl_tx.v
    rtl/phy/eth_phy_10g_tx.v
    rtl/phy/eth_phy_10g_rx.v
    rtl/mac/axis_xgmii_rx_64.v
    rtl/mac/mac_ctrl_rx.v
    rtl/icmp/icmp_rx.v
    rtl/arp/arp_cache.v
    rtl/mac/eth_mac_10g.v
    rtl/send_axis.v
    rtl/mac/axis_async_fifo_adapter.v
    rtl/arp/arp_layer.v
    rtl/ip/ip_tx.v
    rtl/ip/ip_layer.v
    rtl/phy/xgmii_baser_dec_64.v
    rtl/ip/ip_rx.v
    rtl/arbiter.v
    rtl/mac/axis_xgmii_tx_32.v
    rtl/mac/mac_pause_ctrl_tx.v
    rtl/mac/eth_mac_10g_fifo.v
    rtl/mac/mac_pause_ctrl_rx.v
    rtl/mac/axis_async_fifo.v
    rtl/xpm_sync_fifo.v
    rtl/udp/udp_tx.v
    rtl/udp/udp_layer.v
    rtl/udp/udp_rx.v
    rtl/mac/ptp_clock_cdc.v
    rtl/phy/eth_phy_10g_rx_frame_sync.v
    rtl/mac/axis_xgmii_rx_32.v
    rtl/priority_encoder.v
    rtl/phy/eth_phy_10g_rx_watchdog.v
    rtl/eth_arb_mux_v1.v
    rtl/eth_axis/eth_axis_layer.v
    rtl/eth_axis/eth_axis_tx_v1.v
    rtl/phy/eth_phy_10g.v
    rtl/phy/eth_phy_10g_rx_if.v
    rtl/phy/eth_phy_10g_rx_ber_mon.v
    rtl/phy/xgmii_baser_enc_64.v
    rtl/eth_axis/eth_axis_rx_v1.v
    rtl/mac/axis_xgmii_tx_64.v
    rtl/tcp/tcp_tx.v
    rtl/tcp/tcp_layer.v
    rtl/tcp/tcp_rx.v
    rtl/tcp_stack_top.v
    rtl/tcp/tcp_ctrl.v
} {
    lappend rtl_files [file join $repo_root $f]
}
add_files -norecurse $rtl_files
update_compile_order -fileset sources_1

# ---- Board-level RTL (example/xcvu5p/rtl/) ----------------------------------
set board_dir [file normalize [file join $project_dir .. rtl]]
set board_files [glob -nocomplain -directory $board_dir *.v *.sv]
if {[llength $board_files] > 0} {
    add_files -norecurse $board_files
}
update_compile_order -fileset sources_1
set_property top fpga [current_fileset]
update_compile_order -fileset sources_1

# ---- GT transceiver wizard: full (channel 0 + common) -----------------------
# GTY preset, per the recorded GUI session; qpll0lock_out is additionally
# enabled because eth_xcvr_phy_wrapper connects it.
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name eth_xcvr_gt_full
set_property CONFIG.preset {GTY-10GBASE-R} [get_ips eth_xcvr_gt_full]
set_property -dict [list \
    CONFIG.FREERUN_FREQUENCY {125} \
    CONFIG.LOCATE_RX_USER_CLOCKING {CORE} \
    CONFIG.LOCATE_TX_USER_CLOCKING {CORE} \
    CONFIG.RX_USER_DATA_WIDTH {64} \
    CONFIG.TX_USER_DATA_WIDTH {64} \
    CONFIG.ENABLE_OPTIONAL_PORTS {qpll0lock_out} \
] [get_ips eth_xcvr_gt_full]
generate_target all [get_files eth_xcvr_gt_full.xci]
# Inline synthesis for the wizard (OOC checkpoint breaks top-level elaboration)
set_property GENERATE_SYNTH_CHECKPOINT 0 [get_files eth_xcvr_gt_full.xci]
update_compile_order -fileset sources_1

# ---- GT transceiver wizard: channel only ------------------------------------
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name eth_xcvr_gt_channel
set_property CONFIG.preset {GTY-10GBASE-R} [get_ips eth_xcvr_gt_channel]
set_property -dict [list \
    CONFIG.FREERUN_FREQUENCY {125} \
    CONFIG.LOCATE_COMMON {EXAMPLE_DESIGN} \
    CONFIG.LOCATE_RX_USER_CLOCKING {CORE} \
    CONFIG.LOCATE_TX_USER_CLOCKING {CORE} \
    CONFIG.RX_USER_DATA_WIDTH {64} \
    CONFIG.TX_USER_DATA_WIDTH {64} \
] [get_ips eth_xcvr_gt_channel]
generate_target all [get_files eth_xcvr_gt_channel.xci]
set_property GENERATE_SYNTH_CHECKPOINT 0 [get_files eth_xcvr_gt_channel.xci]
update_compile_order -fileset sources_1

#-------------------------VIO IP------------------------------------------------------
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_ip_cfg
set_property -dict [list \
  CONFIG.C_NUM_PROBE_IN {2} \
  CONFIG.C_NUM_PROBE_OUT {10} \
  CONFIG.C_PROBE_OUT0_INIT_VAL {0xc0a80223} \
  CONFIG.C_PROBE_OUT0_WIDTH {32} \
  CONFIG.C_PROBE_OUT1_INIT_VAL {0xc0a8020a} \
  CONFIG.C_PROBE_OUT1_WIDTH {32} \
  CONFIG.C_PROBE_OUT2_INIT_VAL {0x5000} \
  CONFIG.C_PROBE_OUT2_WIDTH {16} \
  CONFIG.C_PROBE_OUT3_INIT_VAL {0x5001} \
  CONFIG.C_PROBE_OUT3_WIDTH {16} \
  CONFIG.C_PROBE_OUT4_INIT_VAL {0x000a3504ec02} \
  CONFIG.C_PROBE_OUT4_WIDTH {48} \
  CONFIG.C_PROBE_OUT6_INIT_VAL {0xc0a80201} \
  CONFIG.C_PROBE_OUT6_WIDTH {32} \
  CONFIG.C_PROBE_OUT7_INIT_VAL {0xffffff00} \
  CONFIG.C_PROBE_OUT7_WIDTH {32} \
  CONFIG.C_PROBE_OUT8_INIT_VAL {0x80} \
  CONFIG.C_PROBE_OUT8_WIDTH {32} \
] [get_ips vio_ip_cfg]
generate_target all [get_files vio_ip_cfg.xci]
set_property GENERATE_SYNTH_CHECKPOINT 0 [get_files vio_ip_cfg.xci]
update_compile_order -fileset sources_1

create_ip -name axis_data_fifo -vendor xilinx.com -library ip -module_name axis_data_fifo_0
set_property -dict [list \
  CONFIG.FIFO_DEPTH {1024} \
  CONFIG.FIFO_MODE {2} \
  CONFIG.HAS_TKEEP {1} \
  CONFIG.TDATA_NUM_BYTES {8} \
] [get_ips axis_data_fifo_0]
generate_target all [get_files axis_data_fifo_0.xci]
set_property GENERATE_SYNTH_CHECKPOINT 0 [get_files axis_data_fifo_0.xci]
update_compile_order -fileset sources_1


# ---- Constraint fileset (example/xcvu5p/) -----------------------------------
# fpga.xdc is the top-level XDC; the three timing-constraint scripts apply
# CDC constraints to sync_reset / axis_async_fifo / eth_mac_*_fifo instances
# (same fileset contents as the original recorded project).
set example_dir [file normalize [file join $project_dir ..]]
set constr_files [glob -nocomplain -directory $example_dir *.xdc *.tcl]
if {[llength $constr_files] > 0} {
    add_files -fileset constrs_1 -norecurse $constr_files
}
set xdc_file [get_files -quiet fpga.xdc -of_objects [get_filesets constrs_1]]
if {$xdc_file ne ""} {
    set_property target_constrs_file $xdc_file [get_filesets constrs_1]
}

# ---- Simulation fileset ------------------------------------------------------
set_property SOURCE_SET sources_1 [get_filesets sim_1]
set tb_dir [file join $repo_root tb]
add_files -fileset sim_1 -norecurse [list \
    [file join $tb_dir tb_icmp_reply.sv] \
    [file join $tb_dir tb_udp_stack_top.sv] \
    [file join $tb_dir tb_eth_axis_tx.sv] \
    [file join $tb_dir tb_arp_v1.sv] \
    [file join $tb_dir tb_axis_arb_mux.sv] \
    [file join $tb_dir tb_eth_axis_rx.sv]]
update_compile_order -fileset sim_1
set_property top tb_udp_stack_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sim_1

puts "Project restored: [file join $project_dir fpga.xpr]"
puts "PART: [get_property PART [current_project]]"
puts "TOP : [get_property top [get_filesets sources_1]]"
puts "SIM TOP: [get_property top [get_filesets sim_1]]"
puts "CONSTRS: [llength [get_files -of_objects [get_filesets constrs_1]]] files in constrs_1"
