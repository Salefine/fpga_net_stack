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
set_property LOC GTYE4_CHANNEL_X1Y16 [get_cells {eth_xcvr_mac/inst/i_eth_xcvr_mac_wrapper_gt/inst/gen_gtwizard_gtye4_top.eth_xcvr_mac_wrapper_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[29].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]
set_property LOC GTYE4_CHANNEL_X1Y16 [get_cells {sfp_phy_inst/phy1.eth_xcvr_phy_1/xcvr.eth_xcvr_gt_full_inst/inst/gen_gtwizard_gtye4_top.eth_xcvr_gt_full_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[1].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]
set_property -dict {LOC AE3} [get_ports gt_rxn_in]

set_property IOSTANDARD LVCMOS18 [get_ports qsfp0_lpmode]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp0_modsell_ls]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp0_resetl_ls]
set_property PACKAGE_PIN AL21 [get_ports qsfp0_modsell_ls]
set_property PACKAGE_PIN AM21 [get_ports qsfp0_resetl_ls]
set_property PACKAGE_PIN AM22 [get_ports qsfp0_lpmode]
