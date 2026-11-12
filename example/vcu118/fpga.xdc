#----------------------constraints for vcu118------------------
#
#
#

###################################################################################
# General configuration for vcu118
###################################################################################

set_property CFGBVS GND [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 63.8 [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR NO [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE NO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]


set_property -dict {LOC E12 IOSTANDARD LVDS} [get_ports clk_250mhz_p]
set_property -dict {LOC D12 IOSTANDARD LVDS} [get_ports clk_250mhz_n]
create_clock -period 4 -name clk_250mhz_p [get_ports clk_250mhz_p]

set_property -dict {LOC AD11} [get_ports gt_refclk_p]
set_property -dict {LOC AD10} [get_ports gt_refclk_n]
create_clock -period 6.400 -name gt_refclk_p [get_ports gt_refclk_p]

set_property -dict {LOC V7} [get_ports gt_txp_out]
set_property -dict {LOC V6} [get_ports gt_txn_out]
set_property -dict {LOC Y2} [get_ports gt_rxp_in]
set_property -dict {LOC Y1} [get_ports gt_rxn_in]

set_property -dict {LOC AM21 IOSTANDARD LVCMOS33} [get_ports qsfp0_modsell_ls]
set_property -dict {LOC BA22 IOSTANDARD LVCMOS33} [get_ports qsfp0_resetl_ls]
set_property -dict {LOC AN21 IOSTANDARD LVCMOS33} [get_ports qsfp0_lpmode]

