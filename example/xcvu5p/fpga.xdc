#----------------------constraints for xcvu5p------------------
#
#
#

###################################################################################
# General configuration for xcvu13p
###################################################################################

set_property CFGBVS GND [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 63.8 [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR NO [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE NO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]


set_property -dict {LOC C36 IOSTANDARD LVDS} [get_ports clk_300mhz_p]
set_property -dict {LOC C37 IOSTANDARD LVDS} [get_ports clk_300mhz_n]
create_clock -period 3.333 -name clk_300mhz_p [get_ports clk_300mhz_p]

set_property -dict {LOC AD11} [get_ports gt_refclk_p]
set_property -dict {LOC AD10} [get_ports gt_refclk_n]
create_clock -period 6.400 -name gt_refclk_p [get_ports gt_refclk_p]

set_property -dict {LOC AE9} [get_ports gt_txp_out]
set_property -dict {LOC AE8} [get_ports gt_txn_out]
set_property -dict {LOC AE4} [get_ports gt_rxp_in]
set_property -dict {LOC AE3} [get_ports gt_rxn_in]

set_property IOSTANDARD LVCMOS18 [get_ports qsfp0_lpmode]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp0_modsell_ls]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp0_resetl_ls]
set_property PACKAGE_PIN AL21 [get_ports qsfp0_modsell_ls]
set_property PACKAGE_PIN AM21 [get_ports qsfp0_resetl_ls]
set_property PACKAGE_PIN AM22 [get_ports qsfp0_lpmode]

create_debug_core u_ila_0 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_0]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk [get_nets [list {sfp_phy_inst/phy1.eth_xcvr_phy_1/xcvr.eth_xcvr_gt_full_inst/inst/gen_gtwizard_gtye4_top.eth_xcvr_gt_full_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_tx_user_clocking_internal.gen_single_instance.gtwiz_userclk_tx_inst/gtwiz_userclk_tx_usrclk2_out[0]}]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe0]
set_property port_width 8 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets [list {mac_fifo_tx_axis_tkeep[0]} {mac_fifo_tx_axis_tkeep[1]} {mac_fifo_tx_axis_tkeep[2]} {mac_fifo_tx_axis_tkeep[3]} {mac_fifo_tx_axis_tkeep[4]} {mac_fifo_tx_axis_tkeep[5]} {mac_fifo_tx_axis_tkeep[6]} {mac_fifo_tx_axis_tkeep[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe1]
set_property port_width 8 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets [list {mac_fifo_rx_axis_tkeep[0]} {mac_fifo_rx_axis_tkeep[1]} {mac_fifo_rx_axis_tkeep[2]} {mac_fifo_rx_axis_tkeep[3]} {mac_fifo_rx_axis_tkeep[4]} {mac_fifo_rx_axis_tkeep[5]} {mac_fifo_rx_axis_tkeep[6]} {mac_fifo_rx_axis_tkeep[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe2]
set_property port_width 8 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets [list {app_tx_axis_tkeep[0]} {app_tx_axis_tkeep[1]} {app_tx_axis_tkeep[2]} {app_tx_axis_tkeep[3]} {app_tx_axis_tkeep[4]} {app_tx_axis_tkeep[5]} {app_tx_axis_tkeep[6]} {app_tx_axis_tkeep[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe3]
set_property port_width 64 [get_debug_ports u_ila_0/probe3]
connect_debug_port u_ila_0/probe3 [get_nets [list {mac_fifo_tx_axis_tdata[0]} {mac_fifo_tx_axis_tdata[1]} {mac_fifo_tx_axis_tdata[2]} {mac_fifo_tx_axis_tdata[3]} {mac_fifo_tx_axis_tdata[4]} {mac_fifo_tx_axis_tdata[5]} {mac_fifo_tx_axis_tdata[6]} {mac_fifo_tx_axis_tdata[7]} {mac_fifo_tx_axis_tdata[8]} {mac_fifo_tx_axis_tdata[9]} {mac_fifo_tx_axis_tdata[10]} {mac_fifo_tx_axis_tdata[11]} {mac_fifo_tx_axis_tdata[12]} {mac_fifo_tx_axis_tdata[13]} {mac_fifo_tx_axis_tdata[14]} {mac_fifo_tx_axis_tdata[15]} {mac_fifo_tx_axis_tdata[16]} {mac_fifo_tx_axis_tdata[17]} {mac_fifo_tx_axis_tdata[18]} {mac_fifo_tx_axis_tdata[19]} {mac_fifo_tx_axis_tdata[20]} {mac_fifo_tx_axis_tdata[21]} {mac_fifo_tx_axis_tdata[22]} {mac_fifo_tx_axis_tdata[23]} {mac_fifo_tx_axis_tdata[24]} {mac_fifo_tx_axis_tdata[25]} {mac_fifo_tx_axis_tdata[26]} {mac_fifo_tx_axis_tdata[27]} {mac_fifo_tx_axis_tdata[28]} {mac_fifo_tx_axis_tdata[29]} {mac_fifo_tx_axis_tdata[30]} {mac_fifo_tx_axis_tdata[31]} {mac_fifo_tx_axis_tdata[32]} {mac_fifo_tx_axis_tdata[33]} {mac_fifo_tx_axis_tdata[34]} {mac_fifo_tx_axis_tdata[35]} {mac_fifo_tx_axis_tdata[36]} {mac_fifo_tx_axis_tdata[37]} {mac_fifo_tx_axis_tdata[38]} {mac_fifo_tx_axis_tdata[39]} {mac_fifo_tx_axis_tdata[40]} {mac_fifo_tx_axis_tdata[41]} {mac_fifo_tx_axis_tdata[42]} {mac_fifo_tx_axis_tdata[43]} {mac_fifo_tx_axis_tdata[44]} {mac_fifo_tx_axis_tdata[45]} {mac_fifo_tx_axis_tdata[46]} {mac_fifo_tx_axis_tdata[47]} {mac_fifo_tx_axis_tdata[48]} {mac_fifo_tx_axis_tdata[49]} {mac_fifo_tx_axis_tdata[50]} {mac_fifo_tx_axis_tdata[51]} {mac_fifo_tx_axis_tdata[52]} {mac_fifo_tx_axis_tdata[53]} {mac_fifo_tx_axis_tdata[54]} {mac_fifo_tx_axis_tdata[55]} {mac_fifo_tx_axis_tdata[56]} {mac_fifo_tx_axis_tdata[57]} {mac_fifo_tx_axis_tdata[58]} {mac_fifo_tx_axis_tdata[59]} {mac_fifo_tx_axis_tdata[60]} {mac_fifo_tx_axis_tdata[61]} {mac_fifo_tx_axis_tdata[62]} {mac_fifo_tx_axis_tdata[63]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe4]
set_property port_width 64 [get_debug_ports u_ila_0/probe4]
connect_debug_port u_ila_0/probe4 [get_nets [list {app_tx_axis_tdata[0]} {app_tx_axis_tdata[1]} {app_tx_axis_tdata[2]} {app_tx_axis_tdata[3]} {app_tx_axis_tdata[4]} {app_tx_axis_tdata[5]} {app_tx_axis_tdata[6]} {app_tx_axis_tdata[7]} {app_tx_axis_tdata[8]} {app_tx_axis_tdata[9]} {app_tx_axis_tdata[10]} {app_tx_axis_tdata[11]} {app_tx_axis_tdata[12]} {app_tx_axis_tdata[13]} {app_tx_axis_tdata[14]} {app_tx_axis_tdata[15]} {app_tx_axis_tdata[16]} {app_tx_axis_tdata[17]} {app_tx_axis_tdata[18]} {app_tx_axis_tdata[19]} {app_tx_axis_tdata[20]} {app_tx_axis_tdata[21]} {app_tx_axis_tdata[22]} {app_tx_axis_tdata[23]} {app_tx_axis_tdata[24]} {app_tx_axis_tdata[25]} {app_tx_axis_tdata[26]} {app_tx_axis_tdata[27]} {app_tx_axis_tdata[28]} {app_tx_axis_tdata[29]} {app_tx_axis_tdata[30]} {app_tx_axis_tdata[31]} {app_tx_axis_tdata[32]} {app_tx_axis_tdata[33]} {app_tx_axis_tdata[34]} {app_tx_axis_tdata[35]} {app_tx_axis_tdata[36]} {app_tx_axis_tdata[37]} {app_tx_axis_tdata[38]} {app_tx_axis_tdata[39]} {app_tx_axis_tdata[40]} {app_tx_axis_tdata[41]} {app_tx_axis_tdata[42]} {app_tx_axis_tdata[43]} {app_tx_axis_tdata[44]} {app_tx_axis_tdata[45]} {app_tx_axis_tdata[46]} {app_tx_axis_tdata[47]} {app_tx_axis_tdata[48]} {app_tx_axis_tdata[49]} {app_tx_axis_tdata[50]} {app_tx_axis_tdata[51]} {app_tx_axis_tdata[52]} {app_tx_axis_tdata[53]} {app_tx_axis_tdata[54]} {app_tx_axis_tdata[55]} {app_tx_axis_tdata[56]} {app_tx_axis_tdata[57]} {app_tx_axis_tdata[58]} {app_tx_axis_tdata[59]} {app_tx_axis_tdata[60]} {app_tx_axis_tdata[61]} {app_tx_axis_tdata[62]} {app_tx_axis_tdata[63]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe5]
set_property port_width 64 [get_debug_ports u_ila_0/probe5]
connect_debug_port u_ila_0/probe5 [get_nets [list {app_rx_axis_tdata[0]} {app_rx_axis_tdata[1]} {app_rx_axis_tdata[2]} {app_rx_axis_tdata[3]} {app_rx_axis_tdata[4]} {app_rx_axis_tdata[5]} {app_rx_axis_tdata[6]} {app_rx_axis_tdata[7]} {app_rx_axis_tdata[8]} {app_rx_axis_tdata[9]} {app_rx_axis_tdata[10]} {app_rx_axis_tdata[11]} {app_rx_axis_tdata[12]} {app_rx_axis_tdata[13]} {app_rx_axis_tdata[14]} {app_rx_axis_tdata[15]} {app_rx_axis_tdata[16]} {app_rx_axis_tdata[17]} {app_rx_axis_tdata[18]} {app_rx_axis_tdata[19]} {app_rx_axis_tdata[20]} {app_rx_axis_tdata[21]} {app_rx_axis_tdata[22]} {app_rx_axis_tdata[23]} {app_rx_axis_tdata[24]} {app_rx_axis_tdata[25]} {app_rx_axis_tdata[26]} {app_rx_axis_tdata[27]} {app_rx_axis_tdata[28]} {app_rx_axis_tdata[29]} {app_rx_axis_tdata[30]} {app_rx_axis_tdata[31]} {app_rx_axis_tdata[32]} {app_rx_axis_tdata[33]} {app_rx_axis_tdata[34]} {app_rx_axis_tdata[35]} {app_rx_axis_tdata[36]} {app_rx_axis_tdata[37]} {app_rx_axis_tdata[38]} {app_rx_axis_tdata[39]} {app_rx_axis_tdata[40]} {app_rx_axis_tdata[41]} {app_rx_axis_tdata[42]} {app_rx_axis_tdata[43]} {app_rx_axis_tdata[44]} {app_rx_axis_tdata[45]} {app_rx_axis_tdata[46]} {app_rx_axis_tdata[47]} {app_rx_axis_tdata[48]} {app_rx_axis_tdata[49]} {app_rx_axis_tdata[50]} {app_rx_axis_tdata[51]} {app_rx_axis_tdata[52]} {app_rx_axis_tdata[53]} {app_rx_axis_tdata[54]} {app_rx_axis_tdata[55]} {app_rx_axis_tdata[56]} {app_rx_axis_tdata[57]} {app_rx_axis_tdata[58]} {app_rx_axis_tdata[59]} {app_rx_axis_tdata[60]} {app_rx_axis_tdata[61]} {app_rx_axis_tdata[62]} {app_rx_axis_tdata[63]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe6]
set_property port_width 8 [get_debug_ports u_ila_0/probe6]
connect_debug_port u_ila_0/probe6 [get_nets [list {app_rx_axis_tkeep[0]} {app_rx_axis_tkeep[1]} {app_rx_axis_tkeep[2]} {app_rx_axis_tkeep[3]} {app_rx_axis_tkeep[4]} {app_rx_axis_tkeep[5]} {app_rx_axis_tkeep[6]} {app_rx_axis_tkeep[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe7]
set_property port_width 64 [get_debug_ports u_ila_0/probe7]
connect_debug_port u_ila_0/probe7 [get_nets [list {mac_fifo_rx_axis_tdata[0]} {mac_fifo_rx_axis_tdata[1]} {mac_fifo_rx_axis_tdata[2]} {mac_fifo_rx_axis_tdata[3]} {mac_fifo_rx_axis_tdata[4]} {mac_fifo_rx_axis_tdata[5]} {mac_fifo_rx_axis_tdata[6]} {mac_fifo_rx_axis_tdata[7]} {mac_fifo_rx_axis_tdata[8]} {mac_fifo_rx_axis_tdata[9]} {mac_fifo_rx_axis_tdata[10]} {mac_fifo_rx_axis_tdata[11]} {mac_fifo_rx_axis_tdata[12]} {mac_fifo_rx_axis_tdata[13]} {mac_fifo_rx_axis_tdata[14]} {mac_fifo_rx_axis_tdata[15]} {mac_fifo_rx_axis_tdata[16]} {mac_fifo_rx_axis_tdata[17]} {mac_fifo_rx_axis_tdata[18]} {mac_fifo_rx_axis_tdata[19]} {mac_fifo_rx_axis_tdata[20]} {mac_fifo_rx_axis_tdata[21]} {mac_fifo_rx_axis_tdata[22]} {mac_fifo_rx_axis_tdata[23]} {mac_fifo_rx_axis_tdata[24]} {mac_fifo_rx_axis_tdata[25]} {mac_fifo_rx_axis_tdata[26]} {mac_fifo_rx_axis_tdata[27]} {mac_fifo_rx_axis_tdata[28]} {mac_fifo_rx_axis_tdata[29]} {mac_fifo_rx_axis_tdata[30]} {mac_fifo_rx_axis_tdata[31]} {mac_fifo_rx_axis_tdata[32]} {mac_fifo_rx_axis_tdata[33]} {mac_fifo_rx_axis_tdata[34]} {mac_fifo_rx_axis_tdata[35]} {mac_fifo_rx_axis_tdata[36]} {mac_fifo_rx_axis_tdata[37]} {mac_fifo_rx_axis_tdata[38]} {mac_fifo_rx_axis_tdata[39]} {mac_fifo_rx_axis_tdata[40]} {mac_fifo_rx_axis_tdata[41]} {mac_fifo_rx_axis_tdata[42]} {mac_fifo_rx_axis_tdata[43]} {mac_fifo_rx_axis_tdata[44]} {mac_fifo_rx_axis_tdata[45]} {mac_fifo_rx_axis_tdata[46]} {mac_fifo_rx_axis_tdata[47]} {mac_fifo_rx_axis_tdata[48]} {mac_fifo_rx_axis_tdata[49]} {mac_fifo_rx_axis_tdata[50]} {mac_fifo_rx_axis_tdata[51]} {mac_fifo_rx_axis_tdata[52]} {mac_fifo_rx_axis_tdata[53]} {mac_fifo_rx_axis_tdata[54]} {mac_fifo_rx_axis_tdata[55]} {mac_fifo_rx_axis_tdata[56]} {mac_fifo_rx_axis_tdata[57]} {mac_fifo_rx_axis_tdata[58]} {mac_fifo_rx_axis_tdata[59]} {mac_fifo_rx_axis_tdata[60]} {mac_fifo_rx_axis_tdata[61]} {mac_fifo_rx_axis_tdata[62]} {mac_fifo_rx_axis_tdata[63]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe8]
set_property port_width 12 [get_debug_ports u_ila_0/probe8]
connect_debug_port u_ila_0/probe8 [get_nets [list {tcp_stack.tcp_stack_inst/icmp_layer_inst/icmp_tx_inst/send_count[0]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/icmp_tx_inst/send_count[1]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/icmp_tx_inst/send_count[2]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/icmp_tx_inst/send_count[3]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/icmp_tx_inst/send_count[4]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/icmp_tx_inst/send_count[5]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/icmp_tx_inst/send_count[6]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/icmp_tx_inst/send_count[7]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/icmp_tx_inst/send_count[8]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/icmp_tx_inst/send_count[9]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/icmp_tx_inst/send_count[10]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/icmp_tx_inst/send_count[11]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe9]
set_property port_width 64 [get_debug_ports u_ila_0/probe9]
connect_debug_port u_ila_0/probe9 [get_nets [list {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[0]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[1]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[2]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[3]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[4]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[5]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[6]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[7]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[8]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[9]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[10]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[11]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[12]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[13]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[14]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[15]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[16]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[17]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[18]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[19]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[20]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[21]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[22]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[23]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[24]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[25]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[26]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[27]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[28]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[29]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[30]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[31]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[32]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[33]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[34]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[35]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[36]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[37]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[38]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[39]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[40]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[41]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[42]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[43]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[44]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[45]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[46]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[47]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[48]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[49]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[50]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[51]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[52]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[53]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[54]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[55]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[56]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[57]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[58]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[59]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[60]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[61]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[62]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tdata[63]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe10]
set_property port_width 8 [get_debug_ports u_ila_0/probe10]
connect_debug_port u_ila_0/probe10 [get_nets [list {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tkeep[0]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tkeep[1]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tkeep[2]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tkeep[3]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tkeep[4]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tkeep[5]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tkeep[6]} {tcp_stack.tcp_stack_inst/icmp_layer_inst/int_axis_tkeep[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe11]
set_property port_width 16 [get_debug_ports u_ila_0/probe11]
connect_debug_port u_ila_0/probe11 [get_nets [list {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[0]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[1]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[2]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[3]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[4]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[5]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[6]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[7]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[8]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[9]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[10]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[11]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[12]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[13]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[14]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_reg[15]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe12]
set_property port_width 16 [get_debug_ports u_ila_0/probe12]
connect_debug_port u_ila_0/probe12 [get_nets [list {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[0]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[1]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[2]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[3]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[4]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[5]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[6]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[7]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[8]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[9]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[10]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[11]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[12]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[13]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[14]} {tcp_stack.tcp_stack_inst/tcp_layer_inst/tcp_ctrl_inst/tcp_state_next[15]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe13]
set_property port_width 64 [get_debug_ports u_ila_0/probe13]
connect_debug_port u_ila_0/probe13 [get_nets [list {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[0]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[1]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[2]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[3]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[4]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[5]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[6]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[7]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[8]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[9]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[10]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[11]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[12]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[13]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[14]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[15]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[16]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[17]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[18]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[19]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[20]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[21]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[22]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[23]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[24]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[25]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[26]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[27]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[28]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[29]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[30]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[31]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[32]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[33]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[34]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[35]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[36]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[37]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[38]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[39]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[40]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[41]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[42]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[43]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[44]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[45]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[46]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[47]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[48]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[49]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[50]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[51]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[52]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[53]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[54]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[55]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[56]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[57]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[58]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[59]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[60]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[61]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[62]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tdata[63]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe14]
set_property port_width 8 [get_debug_ports u_ila_0/probe14]
connect_debug_port u_ila_0/probe14 [get_nets [list {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tkeep[0]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tkeep[1]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tkeep[2]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tkeep[3]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tkeep[4]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tkeep[5]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tkeep[6]} {tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tkeep[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe15]
set_property port_width 64 [get_debug_ports u_ila_0/probe15]
connect_debug_port u_ila_0/probe15 [get_nets [list {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[0]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[1]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[2]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[3]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[4]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[5]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[6]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[7]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[8]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[9]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[10]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[11]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[12]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[13]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[14]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[15]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[16]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[17]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[18]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[19]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[20]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[21]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[22]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[23]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[24]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[25]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[26]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[27]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[28]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[29]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[30]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[31]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[32]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[33]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[34]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[35]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[36]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[37]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[38]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[39]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[40]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[41]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[42]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[43]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[44]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[45]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[46]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[47]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[48]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[49]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[50]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[51]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[52]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[53]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[54]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[55]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[56]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[57]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[58]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[59]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[60]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[61]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[62]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tdata[63]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe16]
set_property port_width 8 [get_debug_ports u_ila_0/probe16]
connect_debug_port u_ila_0/probe16 [get_nets [list {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tkeep[0]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tkeep[1]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tkeep[2]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tkeep[3]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tkeep[4]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tkeep[5]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tkeep[6]} {tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tkeep[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe17]
set_property port_width 1 [get_debug_ports u_ila_0/probe17]
connect_debug_port u_ila_0/probe17 [get_nets [list app_rx_axis_tlast]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe18]
set_property port_width 1 [get_debug_ports u_ila_0/probe18]
connect_debug_port u_ila_0/probe18 [get_nets [list app_rx_axis_tready]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe19]
set_property port_width 1 [get_debug_ports u_ila_0/probe19]
connect_debug_port u_ila_0/probe19 [get_nets [list app_rx_axis_tvalid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe20]
set_property port_width 1 [get_debug_ports u_ila_0/probe20]
connect_debug_port u_ila_0/probe20 [get_nets [list app_tx_axis_tlast]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe21]
set_property port_width 1 [get_debug_ports u_ila_0/probe21]
connect_debug_port u_ila_0/probe21 [get_nets [list app_tx_axis_tready]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe22]
set_property port_width 1 [get_debug_ports u_ila_0/probe22]
connect_debug_port u_ila_0/probe22 [get_nets [list app_tx_axis_tvalid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe23]
set_property port_width 1 [get_debug_ports u_ila_0/probe23]
connect_debug_port u_ila_0/probe23 [get_nets [list tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tlast]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe24]
set_property port_width 1 [get_debug_ports u_ila_0/probe24]
connect_debug_port u_ila_0/probe24 [get_nets [list tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tready]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe25]
set_property port_width 1 [get_debug_ports u_ila_0/probe25]
connect_debug_port u_ila_0/probe25 [get_nets [list tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tuser]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe26]
set_property port_width 1 [get_debug_ports u_ila_0/probe26]
connect_debug_port u_ila_0/probe26 [get_nets [list tcp_stack.tcp_stack_inst/ip2tcp_rx_axis_tvalid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe27]
set_property port_width 1 [get_debug_ports u_ila_0/probe27]
connect_debug_port u_ila_0/probe27 [get_nets [list mac_fifo_rx_axis_tlast]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe28]
set_property port_width 1 [get_debug_ports u_ila_0/probe28]
connect_debug_port u_ila_0/probe28 [get_nets [list mac_fifo_rx_axis_tready]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe29]
set_property port_width 1 [get_debug_ports u_ila_0/probe29]
connect_debug_port u_ila_0/probe29 [get_nets [list mac_fifo_rx_axis_tuser]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe30]
set_property port_width 1 [get_debug_ports u_ila_0/probe30]
connect_debug_port u_ila_0/probe30 [get_nets [list mac_fifo_rx_axis_tvalid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe31]
set_property port_width 1 [get_debug_ports u_ila_0/probe31]
connect_debug_port u_ila_0/probe31 [get_nets [list mac_fifo_tx_axis_tlast]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe32]
set_property port_width 1 [get_debug_ports u_ila_0/probe32]
connect_debug_port u_ila_0/probe32 [get_nets [list mac_fifo_tx_axis_tready]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe33]
set_property port_width 1 [get_debug_ports u_ila_0/probe33]
connect_debug_port u_ila_0/probe33 [get_nets [list mac_fifo_tx_axis_tuser]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe34]
set_property port_width 1 [get_debug_ports u_ila_0/probe34]
connect_debug_port u_ila_0/probe34 [get_nets [list mac_fifo_tx_axis_tvalid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe35]
set_property port_width 1 [get_debug_ports u_ila_0/probe35]
connect_debug_port u_ila_0/probe35 [get_nets [list tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tlast]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe36]
set_property port_width 1 [get_debug_ports u_ila_0/probe36]
connect_debug_port u_ila_0/probe36 [get_nets [list tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tready]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe37]
set_property port_width 1 [get_debug_ports u_ila_0/probe37]
connect_debug_port u_ila_0/probe37 [get_nets [list tcp_stack.tcp_stack_inst/tcp2ip_tx_axis_tvalid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe38]
set_property port_width 1 [get_debug_ports u_ila_0/probe38]
connect_debug_port u_ila_0/probe38 [get_nets [list tcp_linkup]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets clk_156mhz_int]
