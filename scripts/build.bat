@echo off
setlocal

rem ============================================================
rem  build.bat - all-in-one Vivado 2024.2 project script
rem
rem  Usage:
rem    build.bat fpga    create/restore the Vivado project
rem    build.bat         open the project in the Vivado GUI
rem                      (creates it first if missing)
rem    build.bat clean   delete all generated files (keeps build.bat)
rem    build.bat help    show this help
rem
rem  The Tcl restore script is embedded below the #__TCL__
rem  marker line at the end of this file.
rem ============================================================

set "VIVADO_HOME=%VIVADO_2024_2%"
if not defined VIVADO_HOME set "VIVADO_HOME=D:\tools\xilinx2024.2\Vivado\2024.2"
if not exist "%VIVADO_HOME%\bin\vivado.bat" set "VIVADO_HOME=C:\Xilinx\Vivado\2024.2"
set "VIVADO=%VIVADO_HOME%\bin\vivado.bat"

set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=open"
if /i "%TARGET%"=="fpga"    goto :create
if /i "%TARGET%"=="create"  goto :create
if /i "%TARGET%"=="open"    goto :open
if /i "%TARGET%"=="gui"     goto :open
if /i "%TARGET%"=="clean"   goto :clean
if /i "%TARGET%"=="clear"   goto :clean
if /i "%TARGET%"=="help"    goto :help
goto :help

rem ---- create -------------------------------------------------
:create
if not exist "%VIVADO%" (
    echo ERROR: Vivado 2024.2 was not found at "%VIVADO%".
    echo Set VIVADO_2024_2 to the Vivado 2024.2 installation directory.
    exit /b 1
)
rem Extract the embedded Tcl (everything after the marker line)
set "TCL_FILE=%TEMP%\fpga_build_%RANDOM%.tcl"
set "SKIP=0"
for /f "delims=:" %%N in ('findstr /n /c:"#__TCL__" "%~f0"') do set /a SKIP=%%N
more +%SKIP% "%~f0" > "%TCL_FILE%"

call "%VIVADO%" -mode batch -source "%TCL_FILE%" -tclargs "%~dp0"
set "EXIT_CODE=%ERRORLEVEL%"
del /f /q "%TCL_FILE%" >nul 2>&1
if not "%EXIT_CODE%"=="0" (
    echo ERROR: Vivado project restore failed with exit code %EXIT_CODE%.
)
exit /b %EXIT_CODE%

rem ---- open ---------------------------------------------------
:open
if not exist "%VIVADO%" (
    echo ERROR: Vivado 2024.2 was not found at "%VIVADO%".
    echo Set VIVADO_2024_2 to the Vivado 2024.2 installation directory.
    exit /b 1
)
if not exist "%~dp0fpga.xpr" (
    echo fpga.xpr not found - creating project first...
    call "%~f0" fpga || exit /b 1
)
rem Launches the Vivado GUI with the project; this console stays
rem open (and shows Vivado messages) until the GUI is closed.
call "%VIVADO%" "%~dp0fpga.xpr"
exit /b %ERRORLEVEL%

rem ---- clean --------------------------------------------------
:clean
cd /d "%~dp0"
for /f "delims=" %%F in ('dir /b /a') do (
    if /i not "%%F"=="build.bat" (
        echo Removing %%F
        if exist "%%F\" (rd /s /q "%%F") else (del /f /q /a "%%F")
    )
)
echo Done.
exit /b 0

rem ---- help ---------------------------------------------------
:help
echo Usage: build.bat [target]
echo   build.bat fpga    create/restore the Vivado project
echo   build.bat         open the project in the Vivado GUI (create first if missing)
echo   build.bat clean   delete all generated files (keeps build.bat)
echo   build.bat help    show this help
exit /b 0

#__TCL__
# Restore script for project fpga (xcvu5p-flvb2104-2-i), recorded from the
# original GUI session.

if {$argc < 1} {
    error "Usage: vivado -mode batch -source <script> -tclargs <fpga-project-directory>"
}

set project_dir [file normalize [lindex $argv 0]]
set repo_root   [file normalize [file join $project_dir .. .. ..]]

# Deterministic rebuild: drop any previous project artifacts
foreach item {fpga.xpr fpga.srcs fpga.gen fpga.runs fpga.cache fpga.hw fpga.ip_user_files fpga.sim} {
    set p [file join $project_dir $item]
    if {[file exists $p]} { file delete -force $p }
}

create_project fpga $project_dir -part xcvu5p-flvb2104-2-i -force

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
    rtl/tcp/tcp_stack_top.v
    rtl/tcp/tcp_ctrl.v
} {
    lappend rtl_files [file join $repo_root $f]
}
add_files -norecurse $rtl_files
update_compile_order -fileset sources_1

# ---- Board-level RTL (example/xcvu5p/rtl/) ----------------------------------
set board_dir [file normalize [file join $project_dir .. rtl]]
add_files -norecurse [list \
    [file join $board_dir eth_xcvr_phy_wrapper.v] \
    [file join $board_dir fpga.sv] \
    [file join $board_dir eth_xcvr_phy_quad_wrapper.v]]
update_compile_order -fileset sources_1
set_property top fpga [current_fileset]
update_compile_order -fileset sources_1

# ---- GT transceiver wizard: full (channel 0 + common) -----------------------
# GTY preset, per the recorded GUI session; qpll0lock_out is additionally
# enabled because eth_xcvr_phy_wrapper connects it.
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -version 1.7 -module_name eth_xcvr_gt_full
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
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -version 1.7 -module_name eth_xcvr_gt_channel
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
create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name vio_ip_cfg
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

create_ip -name xxv_ethernet -vendor xilinx.com -library ip -version 4.1 -module_name eth_xcvr_mac_wrapper
set_property -dict [list \
  CONFIG.BASE_R_KR {BASE-R} \
  CONFIG.GT_DRP_CLK {125.00} \
  CONFIG.GT_GROUP_SELECT {Quad_X1Y5} \
  CONFIG.LINE_RATE {10} \
] [get_ips eth_xcvr_mac_wrapper]
generate_target all [get_files eth_xcvr_mac_wrapper.xci]
set_property GENERATE_SYNTH_CHECKPOINT 0 [get_files eth_xcvr_mac_wrapper.xci]
update_compile_order -fileset sources_1

create_ip -name axis_data_fifo -vendor xilinx.com -library ip -version 2.0 -module_name axis_data_fifo_0
set_property -dict [list \
  CONFIG.FIFO_DEPTH {1024} \
  CONFIG.FIFO_MODE {2} \
  CONFIG.HAS_TKEEP {1} \
  CONFIG.TDATA_NUM_BYTES {8} \
] [get_ips axis_data_fifo_0]
generate_target all [get_files axis_data_fifo_0.xci]
set_property GENERATE_SYNTH_CHECKPOINT 0 [get_files axis_data_fifo_0.xci]
update_compile_order -fileset sources_1

create_ip -name axis_data_fifo -vendor xilinx.com -library ip -version 2.0 -module_name axis_mac_fifo
set_property -dict [list \
  CONFIG.FIFO_DEPTH {1024} \
  CONFIG.FIFO_MODE {2} \
  CONFIG.HAS_TKEEP {1} \
  CONFIG.IS_ACLK_ASYNC {1} \
  CONFIG.TUSER_WIDTH {1} \
  CONFIG.TDATA_NUM_BYTES {8} \
] [get_ips axis_mac_fifo]
generate_target all [get_files axis_mac_fifo.xci]
set_property GENERATE_SYNTH_CHECKPOINT 0 [get_files axis_mac_fifo.xci]
update_compile_order -fileset sources_1

# ---- Constraint fileset (example/xcvu5p/) -----------------------------------
# fpga.xdc is the top-level XDC; the three timing-constraint scripts apply
# CDC constraints to sync_reset / axis_async_fifo / eth_mac_*_fifo instances
# (same fileset contents as the original recorded project).
set example_dir [file normalize [file join $project_dir ..]]
add_files -fileset constrs_1 -norecurse [list \
    [file join $example_dir fpga.xdc] \
    [file join $example_dir sync_reset.tcl] \
    [file join $example_dir axis_async_fifo.tcl] \
    [file join $example_dir eth_mac_fifo.tcl]]
set_property target_constrs_file [get_files fpga.xdc] [get_filesets constrs_1]

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
