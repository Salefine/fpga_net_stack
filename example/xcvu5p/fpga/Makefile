# ============================================================
# Vivado 2024.2 Linux Makefile
#
# Usage:
#   make          Open Vivado GUI
#   make fpga     Create/restore project
#   make create   Create/restore project
#   make open     Open Vivado GUI
#   make clean    Clean generated files
#   make help     Show help
# ============================================================

SHELL := /bin/bash

VIVADO_SETTINGS := /tools/xilinx24_2/Vivado/2024.2/settings64.sh

PROJECT_NAME := fpga
PROJECT_FILE := $(PROJECT_NAME).xpr
PROJECT_DIR  := $(CURDIR)

TCL_FILE := /tmp/vivado_restore_$(PROJECT_NAME)_$(shell id -u).tcl

.PHONY: all fpga create open gui clean help check-env

all: open

# ============================================================
# Embedded Tcl script
# ============================================================

define TCL_SCRIPT

if {$$argc < 1} {
    error "Usage: vivado -mode batch -source restore.tcl -tclargs <project_dir>"
}

set project_dir [file normalize [lindex $$argv 0]]
set repo_root [file normalize [file join $$project_dir .. .. ..]]

# Clean previous project
foreach item {
    fpga.xpr fpga.srcs fpga.gen fpga.runs
    fpga.cache fpga.hw fpga.ip_user_files fpga.sim
} {
    set p [file join $$project_dir $$item]
    if {[file exists $$p]} {
        file delete -force $$p
    }
}

# Create project
create_project fpga $$project_dir -part xcvu5p-flvb2104-2-i -force

# ------------------------------------------------------------
# Network stack RTL
# ------------------------------------------------------------

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
    lappend rtl_files [file join $$repo_root $$f]
}

add_files -norecurse $$rtl_files
update_compile_order -fileset sources_1

# ------------------------------------------------------------
# Board-level RTL
# ------------------------------------------------------------

set board_dir [file normalize [file join $$project_dir .. rtl]]

set board_files [list \
    [file join $$board_dir eth_xcvr_phy_wrapper.v] \
    [file join $$board_dir fpga.sv] \
    [file join $$board_dir eth_xcvr_phy_quad_wrapper.v] \
]

add_files -norecurse $$board_files

update_compile_order -fileset sources_1

set_property top fpga [current_fileset]

update_compile_order -fileset sources_1

# ------------------------------------------------------------
# GT Wizard Full
# ------------------------------------------------------------

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
set_property GENERATE_SYNTH_CHECKPOINT 0 [get_files eth_xcvr_gt_full.xci]
update_compile_order -fileset sources_1

# ------------------------------------------------------------
# GT Wizard Channel
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# VIO IP
# ------------------------------------------------------------

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


# ------------------------------------------------------------
# AXIS Data FIFO
# ------------------------------------------------------------

create_ip -name axis_data_fifo -vendor xilinx.com -library ip -version 2.0 -module_name tcp_echo_fifo

set_property -dict [list \
    CONFIG.FIFO_DEPTH {1024} \
    CONFIG.FIFO_MODE {2} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.TDATA_NUM_BYTES {8} \
] [get_ips tcp_echo_fifo]

generate_target all [get_files tcp_echo_fifo.xci]
set_property GENERATE_SYNTH_CHECKPOINT 0 [get_files tcp_echo_fifo.xci]
update_compile_order -fileset sources_1



# ------------------------------------------------------------
# Constraints
# ------------------------------------------------------------

set example_dir [file normalize [file join $$project_dir ..]]

add_files -fileset constrs_1 -norecurse [list \
    [file join $$example_dir fpga.xdc] \
    [file join $$example_dir sync_reset.tcl] \
    [file join $$example_dir axis_async_fifo.tcl] \
    [file join $$example_dir eth_mac_fifo.tcl]]

set_property target_constrs_file [get_files fpga.xdc] [get_filesets constrs_1]

# ------------------------------------------------------------
# Simulation
# ------------------------------------------------------------

set_property SOURCE_SET sources_1 [get_filesets sim_1]

set tb_dir [file join $$repo_root tb]

add_files -fileset sim_1 -norecurse [list \
    [file join $$tb_dir tb_icmp_reply.sv] \
    [file join $$tb_dir tb_udp_stack_top.sv] \
    [file join $$tb_dir tb_eth_axis_tx.sv] \
    [file join $$tb_dir tb_arp_v1.sv] \
    [file join $$tb_dir tb_axis_arb_mux.sv] \
    [file join $$tb_dir tb_eth_axis_rx.sv]]

update_compile_order -fileset sim_1
set_property top tb_udp_stack_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sim_1

puts "Project restored: [file join $$project_dir fpga.xpr]"
puts "PART: [get_property PART [current_project]]"
puts "TOP : [get_property top [get_filesets sources_1]]"
puts "SIM TOP: [get_property top [get_filesets sim_1]]"
puts "CONSTRS: [llength [get_files -of_objects [get_filesets constrs_1]]] files in constrs_1"

endef

# ============================================================
# Generate temporary Tcl and run Vivado
# ============================================================

check-env:
	@test -f "$(VIVADO_SETTINGS)" || \
		(echo "ERROR: Vivado settings not found"; exit 1)

create: check-env
	@echo "Generating Tcl script..."
	@printf '%s\n' "$$TCL_CONTENT" > "$(TCL_FILE)"
	@source "$(VIVADO_SETTINGS)" && \
		vivado -mode batch -source "$(TCL_FILE)" \
		-tclargs "$(PROJECT_DIR)"; \
		ret=$$?; \
		rm -f "$(TCL_FILE)"; \
		exit $$ret

	@echo "Project creation completed."

fpga: create

# ============================================================
# Open GUI
# ============================================================

open: check-env
	@if [ ! -f "$(PROJECT_FILE)" ]; then \
		echo "Project not found, creating..."; \
		$(MAKE) create || exit 1; \
	fi
	@source "$(VIVADO_SETTINGS)" && \
		vivado "$(PROJECT_DIR)/$(PROJECT_FILE)"

gui: open

# ============================================================
# Clean
# ============================================================

clean:
	@echo "Cleaning..."
	@rm -rf fpga.xpr fpga.srcs fpga.gen fpga.runs \
		fpga.cache fpga.hw fpga.ip_user_files fpga.sim
	@echo "Clean completed."

# ============================================================
# Help
# ============================================================

help:
	@echo "Usage: make [target]"
	@echo "  make         Open Vivado GUI"
	@echo "  make fpga    Create project"
	@echo "  make create  Create project"
	@echo "  make open    Open GUI"
	@echo "  make clean   Clean generated files"
	@echo "  make help    Show help"

# Export embedded Tcl to shell environment for recipe.
export TCL_CONTENT := $(TCL_SCRIPT)
