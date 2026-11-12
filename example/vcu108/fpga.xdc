#----------------------constraints for vcu108------------------
#
#
#

###################################################################################
# General configuration for vcu108
###################################################################################

set_property CFGBVS GND [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 63.8 [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR NO [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE NO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]


set_property -dict {LOC G31 IOSTANDARD LVDS} [get_ports clk_300mhz_p]
set_property -dict {LOC F31 IOSTANDARD LVDS} [get_ports clk_300mhz_n]
create_clock -period 3.333 -name clk_300mhz_p [get_ports clk_300mhz_p]

set_property -dict {LOC AF38} [get_ports gt_refclk_p]
set_property -dict {LOC AF39} [get_ports gt_refclk_n]
create_clock -period 6.400 -name gt_refclk_p [get_ports gt_refclk_p]

set_property -dict {LOC AK42} [get_ports gt_txp_out]
set_property -dict {LOC AK43} [get_ports gt_txn_out]
set_property -dict {LOC AG45} [get_ports gt_rxp_in]
set_property -dict {LOC AG46} [get_ports gt_rxn_in]

set_property -dict {LOC AL24 IOSTANDARD LVCMOS18} [get_ports qsfp0_modsell_ls]
set_property -dict {LOC AM24 IOSTANDARD LVCMOS18} [get_ports qsfp0_resetl_ls]
set_property -dict {LOC AM21 IOSTANDARD LVCMOS18} [get_ports qsfp0_lpmode]

