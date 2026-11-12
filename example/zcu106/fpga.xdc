#----------------------constraints for zcu106------------------
#
#
#

###################################################################################
# General configuration for zcu106
###################################################################################

# set_property CFGBVS GND [current_design]
# set_property CONFIG_VOLTAGE 1.8 [current_design]
# set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
# set_property BITSTREAM.CONFIG.CONFIGRATE 63.8 [current_design]
# set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR NO [current_design]
# set_property BITSTREAM.CONFIG.SPI_FALL_EDGE NO [current_design]
# set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]


set_property -dict {LOC AH12 IOSTANDARD LVDS} [get_ports clk_300mhz_p]
set_property -dict {LOC AJ12 IOSTANDARD LVDS} [get_ports clk_300mhz_n]
create_clock -period 3.333 -name clk_300mhz_p [get_ports clk_300mhz_p]

set_property -dict {LOC W10} [get_ports gt_refclk_p]
set_property -dict {LOC W9} [get_ports gt_refclk_n]
create_clock -period 6.400 -name gt_refclk_p [get_ports gt_refclk_p]

set_property -dict {LOC Y4} [get_ports gt_txp_out]
set_property -dict {LOC Y3} [get_ports gt_txn_out]
set_property -dict {LOC AA2} [get_ports gt_rxp_in]
set_property -dict {LOC AA1} [get_ports gt_rxn_in]

set_property -dict {LOC AE22 IOSTANDARD LVCMOS12} [get_ports sfp_disable]

