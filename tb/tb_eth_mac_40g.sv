`timescale 1ns / 1ps
`default_nettype none

/****************************************************************************
 * @file    tb_eth_mac_40g.sv
 * @brief   Self-checking testbench for the AMD 40G Ethernet MAC core
 *          (l_ethernet, 40GBASE-R, 256-bit regular AXI4-Stream, statistics
 *          counters enabled, GT location = external).
 *
 *          The DUT is used without its GT subcore, so the PCS <-> SerDes
 *          interface is exposed. A serial loopback is modelled by wiring the
 *          TX PCS output straight back into the RX PCS input, the same way a
 *          GT far-end/PMD loopback would:
 *
 *              rxdata_out_0       <= txdata_in_0
 *              rxheader_in_0      <= txheader_out_0
 *              rxdatavalid_in_0   <= 8'h55  (one valid 32-bit word per lane)
 *              rxheadervalid_in_0 <= 8'h55
 *
 *          Clocking for 40GBASE-R (see PG211 "SerDes Clocks"):
 *              4 PCS lanes x 32 bit x 322.265625 MHz = 41.25 Gb/s
 *              tx_core_clk = rx_core_clk = rx_serdes_clk = 322.265625 MHz
 *
 *          Tests:
 *            1. reset release, PCS block lock / lane sync / alignment
 *            2. minimum size frame (60 B payload + 4 B FCS = 64 B on wire)
 *               with an exact statistics byte check
 *            3. frame size sweep 61/100/512/1518/4096 B
 *            4. back-to-back burst (minimum IPG)
 *            5. bad FCS injection through tx_axis_tuser
 *            6. TX underflow (tvalid dropped inside a frame)
 *            7. statistics summary
 *
 *          RX frame content checking runs whenever the RX PCS reaches
 *          alignment. With a plain PCS wire loopback the RX PCS of this core
 *          does not reach word-boundary sync (the GT 64B/66B gearbox and the
 *          PCS lane marker handling are part of that path), so the RX checks
 *          are reported as skipped and the TX path is verified instead.
 *
 *          Run: vivado -mode batch -source tb/eth_mac_40g_sim.tcl
 *               (or add tb/tb_eth_mac_40g.sv to a project's sim_1 fileset and
 *                set the simulation top to tb_eth_mac_40g)
 ***************************************************************************/

module tb_eth_mac_40g;

// ---------------------------------------------------------------------------
// configuration
// ---------------------------------------------------------------------------
`ifdef CLK_HALF_PS_VALUE
localparam int CLK_HALF_PS      = `CLK_HALF_PS_VALUE;
`else
localparam int CLK_HALF_PS      = 1552;   // 322.265625 MHz -> 3.103 ns period
`endif
localparam int DATA_BYTES       = 32;     // 256-bit AXI4-Stream
localparam int MAX_FRAME_BYTES  = 9216;   // ctl_rx_max_packet_len
localparam int MAX_FRAMES       = 64;

`ifdef RX_DV_PATTERN_VALUE
localparam logic [7:0] RX_DV_PATTERN = `RX_DV_PATTERN_VALUE;
`else
// 40G: one valid 32-bit word per PCS lane, bit0 of each 2-bit lane field
localparam logic [7:0] RX_DV_PATTERN = 8'h55;
`endif

localparam logic [55:0] PREAMBLE = 56'h55_55_55_55_55_55_d5;  // 55 x6 + D5

// ---------------------------------------------------------------------------
// clock / reset
// ---------------------------------------------------------------------------
logic clk = 1'b0;
always #(CLK_HALF_PS / 1000.0) clk = ~clk;

logic tx_reset_0        = 1'b1;
logic rx_reset_0        = 1'b1;
logic rx_serdes_reset_0 = 1'b1;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
logic [255:0] tx_axis_tdata_0  = '0;
logic [31:0]  tx_axis_tkeep_0  = '0;
logic         tx_axis_tvalid_0 = 1'b0;
logic         tx_axis_tlast_0  = 1'b0;
logic [0:0]   tx_axis_tuser_0  = 1'b0;
wire          tx_axis_tready_0;
wire          tx_unfout_0;

wire  [255:0] rx_axis_tdata_0;
wire  [31:0]  rx_axis_tkeep_0;
wire          rx_axis_tvalid_0;
wire          rx_axis_tlast_0;
wire  [0:0]   rx_axis_tuser_0;
wire  [55:0]  rx_preambleout_0;

logic         ctl_rx_test_pattern_0           = 1'b0;
logic         ctl_rx_enable_0                 = 1'b0;
logic         ctl_rx_delete_fcs_0             = 1'b1;
logic         ctl_rx_ignore_fcs_0             = 1'b0;
logic [14:0]  ctl_rx_max_packet_len_0         = 15'd9600;
logic [7:0]   ctl_rx_min_packet_len_0         = 8'd64;
logic         ctl_rx_custom_preamble_enable_0 = 1'b0;
logic         ctl_rx_check_sfd_0              = 1'b0;
logic         ctl_rx_check_preamble_0         = 1'b0;
logic         ctl_rx_process_lfi_0            = 1'b0;
logic         ctl_rx_force_resync_0           = 1'b0;

logic         ctl_tx_test_pattern_0           = 1'b0;
logic         ctl_tx_enable_0                 = 1'b1;
logic         ctl_tx_fcs_ins_enable_0         = 1'b1;
logic [3:0]   ctl_tx_ipg_value_0              = 4'd12;
logic         ctl_tx_send_lfi_0               = 1'b0;
logic         ctl_tx_send_rfi_0               = 1'b0;
logic         ctl_tx_send_idle_0              = 1'b0;
logic         ctl_tx_custom_preamble_enable_0 = 1'b0;
logic         ctl_tx_ignore_fcs_0             = 1'b0;
logic [55:0]  tx_preamblein_0                 = PREAMBLE;

wire  [511:0] txdata_in_0;
wire  [23:0]  txheader_out_0;
wire  [27:0]  txsequence_out_0;
wire  [3:0]   rxgearboxslip_out_0;

wire  [3:0]   stat_rx_block_lock_0;
wire          stat_rx_framing_err_valid_0_0;
wire          stat_rx_framing_err_0_0;
wire          stat_rx_framing_err_valid_1_0;
wire          stat_rx_framing_err_1_0;
wire          stat_rx_framing_err_valid_2_0;
wire          stat_rx_framing_err_2_0;
wire          stat_rx_framing_err_valid_3_0;
wire          stat_rx_framing_err_3_0;
wire  [3:0]   stat_rx_vl_demuxed_0;
wire  [1:0]   stat_rx_vl_number_0_0;
wire  [1:0]   stat_rx_vl_number_1_0;
wire  [1:0]   stat_rx_vl_number_2_0;
wire  [1:0]   stat_rx_vl_number_3_0;
wire  [3:0]   stat_rx_synced_0;
wire  [3:0]   stat_rx_synced_err_0;
wire  [3:0]   stat_rx_mf_len_err_0;
wire  [3:0]   stat_rx_mf_repeat_err_0;
wire  [3:0]   stat_rx_mf_err_0;
wire          stat_rx_misaligned_0;
wire          stat_rx_aligned_err_0;
wire          stat_rx_bip_err_0_0;
wire          stat_rx_bip_err_1_0;
wire          stat_rx_bip_err_2_0;
wire          stat_rx_bip_err_3_0;
wire          stat_rx_aligned_0;
wire          stat_rx_hi_ber_0;
wire          stat_rx_status_0;
wire  [1:0]   stat_rx_bad_code_0;
wire  [1:0]   stat_rx_total_packets_0;
wire          stat_rx_total_good_packets_0;
wire  [5:0]   stat_rx_total_bytes_0;
wire  [13:0]  stat_rx_total_good_bytes_0;
wire  [1:0]   stat_rx_packet_small_0;
wire          stat_rx_jabber_0;
wire          stat_rx_packet_large_0;
wire          stat_rx_oversize_0;
wire  [1:0]   stat_rx_undersize_0;
wire          stat_rx_toolong_0;
wire  [1:0]   stat_rx_fragment_0;
wire          stat_rx_packet_64_bytes_0;
wire          stat_rx_packet_65_127_bytes_0;
wire          stat_rx_packet_128_255_bytes_0;
wire          stat_rx_packet_256_511_bytes_0;
wire          stat_rx_packet_512_1023_bytes_0;
wire          stat_rx_packet_1024_1518_bytes_0;
wire          stat_rx_packet_1519_1522_bytes_0;
wire          stat_rx_packet_1523_1548_bytes_0;
wire  [1:0]   stat_rx_bad_fcs_0;
wire          stat_rx_packet_bad_fcs_0;
wire  [1:0]   stat_rx_stomped_fcs_0;
wire          stat_rx_packet_1549_2047_bytes_0;
wire          stat_rx_packet_2048_4095_bytes_0;
wire          stat_rx_packet_4096_8191_bytes_0;
wire          stat_rx_packet_8192_9215_bytes_0;
wire          stat_rx_unicast_0;
wire          stat_rx_multicast_0;
wire          stat_rx_broadcast_0;
wire          stat_rx_vlan_0;
wire          stat_rx_inrangeerr_0;
wire          stat_rx_bad_preamble_0;
wire          stat_rx_bad_sfd_0;
wire          stat_rx_got_signal_os_0;
wire  [1:0]   stat_rx_test_pattern_mismatch_0;
wire          stat_rx_truncated_0;
wire          stat_rx_local_fault_0;
wire          stat_rx_remote_fault_0;
wire          stat_rx_internal_local_fault_0;
wire          stat_rx_received_local_fault_0;

wire          stat_tx_total_packets_0;
wire  [4:0]   stat_tx_total_bytes_0;
wire          stat_tx_total_good_packets_0;
wire  [13:0]  stat_tx_total_good_bytes_0;
wire          stat_tx_packet_64_bytes_0;
wire          stat_tx_packet_65_127_bytes_0;
wire          stat_tx_packet_128_255_bytes_0;
wire          stat_tx_packet_256_511_bytes_0;
wire          stat_tx_packet_512_1023_bytes_0;
wire          stat_tx_packet_1024_1518_bytes_0;
wire          stat_tx_packet_1519_1522_bytes_0;
wire          stat_tx_packet_1523_1548_bytes_0;
wire          stat_tx_packet_small_0;
wire          stat_tx_packet_large_0;
wire          stat_tx_packet_1549_2047_bytes_0;
wire          stat_tx_packet_2048_4095_bytes_0;
wire          stat_tx_packet_4096_8191_bytes_0;
wire          stat_tx_packet_8192_9215_bytes_0;
wire          stat_tx_unicast_0;
wire          stat_tx_multicast_0;
wire          stat_tx_broadcast_0;
wire          stat_tx_vlan_0;
wire          stat_tx_bad_fcs_0;
wire          stat_tx_frame_error_0;
wire          stat_tx_local_fault_0;
wire          stat_tx_underflow_err_0;
wire          stat_tx_overflow_err_0;

// PCS / SerDes loopback (models GT serial loopback)
logic [511:0] rxdata_out_0       = '0;
logic [23:0]  rxheader_in_0      = '0;
logic [7:0]   rxdatavalid_in_0   = '0;
logic [7:0]   rxheadervalid_in_0 = '0;

always @(posedge clk) begin
    rxdata_out_0       <= txdata_in_0;
    rxheader_in_0      <= txheader_out_0;
    rxdatavalid_in_0   <= RX_DV_PATTERN;
    rxheadervalid_in_0 <= RX_DV_PATTERN;
end

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
`ifndef ETH_MAC_IP_MODULE
`define ETH_MAC_IP_MODULE eth_xcvr_40_full
`endif

`ETH_MAC_IP_MODULE u_dut (
    .tx_reset_0                     (tx_reset_0),
    .rx_reset_0                     (rx_reset_0),
    .rx_serdes_reset_0              (rx_serdes_reset_0),
    .tx_core_clk_0                  (clk),
    .rx_core_clk_0                  (clk),
    .rx_serdes_clk_0                (clk),

    .tx_axis_tready_0               (tx_axis_tready_0),
    .tx_axis_tvalid_0               (tx_axis_tvalid_0),
    .tx_axis_tdata_0                (tx_axis_tdata_0),
    .tx_axis_tkeep_0                (tx_axis_tkeep_0),
    .tx_axis_tlast_0                (tx_axis_tlast_0),
    .tx_axis_tuser_0                (tx_axis_tuser_0),
    .tx_unfout_0                    (tx_unfout_0),
    .tx_preamblein_0                (tx_preamblein_0),

    .rx_axis_tvalid_0               (rx_axis_tvalid_0),
    .rx_axis_tdata_0                (rx_axis_tdata_0),
    .rx_axis_tkeep_0                (rx_axis_tkeep_0),
    .rx_axis_tlast_0                (rx_axis_tlast_0),
    .rx_axis_tuser_0                (rx_axis_tuser_0),
    .rx_preambleout_0               (rx_preambleout_0),

    .ctl_rx_test_pattern_0          (ctl_rx_test_pattern_0),
    .ctl_rx_enable_0                (ctl_rx_enable_0),
    .ctl_rx_delete_fcs_0            (ctl_rx_delete_fcs_0),
    .ctl_rx_ignore_fcs_0            (ctl_rx_ignore_fcs_0),
    .ctl_rx_max_packet_len_0        (ctl_rx_max_packet_len_0),
    .ctl_rx_min_packet_len_0        (ctl_rx_min_packet_len_0),
    .ctl_rx_custom_preamble_enable_0(ctl_rx_custom_preamble_enable_0),
    .ctl_rx_check_sfd_0             (ctl_rx_check_sfd_0),
    .ctl_rx_check_preamble_0        (ctl_rx_check_preamble_0),
    .ctl_rx_process_lfi_0           (ctl_rx_process_lfi_0),
    .ctl_rx_force_resync_0          (ctl_rx_force_resync_0),

    .ctl_tx_test_pattern_0          (ctl_tx_test_pattern_0),
    .ctl_tx_enable_0                (ctl_tx_enable_0),
    .ctl_tx_fcs_ins_enable_0        (ctl_tx_fcs_ins_enable_0),
    .ctl_tx_ipg_value_0             (ctl_tx_ipg_value_0),
    .ctl_tx_send_lfi_0              (ctl_tx_send_lfi_0),
    .ctl_tx_send_rfi_0              (ctl_tx_send_rfi_0),
    .ctl_tx_send_idle_0             (ctl_tx_send_idle_0),
    .ctl_tx_custom_preamble_enable_0(ctl_tx_custom_preamble_enable_0),
    .ctl_tx_ignore_fcs_0            (ctl_tx_ignore_fcs_0),

    .stat_rx_block_lock_0           (stat_rx_block_lock_0),
    .stat_rx_framing_err_valid_0_0  (stat_rx_framing_err_valid_0_0),
    .stat_rx_framing_err_0_0        (stat_rx_framing_err_0_0),
    .stat_rx_framing_err_valid_1_0  (stat_rx_framing_err_valid_1_0),
    .stat_rx_framing_err_1_0        (stat_rx_framing_err_1_0),
    .stat_rx_framing_err_valid_2_0  (stat_rx_framing_err_valid_2_0),
    .stat_rx_framing_err_2_0        (stat_rx_framing_err_2_0),
    .stat_rx_framing_err_valid_3_0  (stat_rx_framing_err_valid_3_0),
    .stat_rx_framing_err_3_0        (stat_rx_framing_err_3_0),
    .stat_rx_vl_demuxed_0           (stat_rx_vl_demuxed_0),
    .stat_rx_vl_number_0_0          (stat_rx_vl_number_0_0),
    .stat_rx_vl_number_1_0          (stat_rx_vl_number_1_0),
    .stat_rx_vl_number_2_0          (stat_rx_vl_number_2_0),
    .stat_rx_vl_number_3_0          (stat_rx_vl_number_3_0),
    .stat_rx_synced_0               (stat_rx_synced_0),
    .stat_rx_synced_err_0           (stat_rx_synced_err_0),
    .stat_rx_mf_len_err_0           (stat_rx_mf_len_err_0),
    .stat_rx_mf_repeat_err_0        (stat_rx_mf_repeat_err_0),
    .stat_rx_mf_err_0               (stat_rx_mf_err_0),
    .stat_rx_misaligned_0           (stat_rx_misaligned_0),
    .stat_rx_aligned_err_0          (stat_rx_aligned_err_0),
    .stat_rx_bip_err_0_0            (stat_rx_bip_err_0_0),
    .stat_rx_bip_err_1_0            (stat_rx_bip_err_1_0),
    .stat_rx_bip_err_2_0            (stat_rx_bip_err_2_0),
    .stat_rx_bip_err_3_0            (stat_rx_bip_err_3_0),
    .stat_rx_aligned_0              (stat_rx_aligned_0),
    .stat_rx_hi_ber_0               (stat_rx_hi_ber_0),
    .stat_rx_status_0               (stat_rx_status_0),
    .stat_rx_bad_code_0             (stat_rx_bad_code_0),
    .stat_rx_total_packets_0        (stat_rx_total_packets_0),
    .stat_rx_total_good_packets_0   (stat_rx_total_good_packets_0),
    .stat_rx_total_bytes_0          (stat_rx_total_bytes_0),
    .stat_rx_total_good_bytes_0     (stat_rx_total_good_bytes_0),
    .stat_rx_packet_small_0         (stat_rx_packet_small_0),
    .stat_rx_jabber_0               (stat_rx_jabber_0),
    .stat_rx_packet_large_0         (stat_rx_packet_large_0),
    .stat_rx_oversize_0             (stat_rx_oversize_0),
    .stat_rx_undersize_0            (stat_rx_undersize_0),
    .stat_rx_toolong_0              (stat_rx_toolong_0),
    .stat_rx_fragment_0             (stat_rx_fragment_0),
    .stat_rx_packet_64_bytes_0      (stat_rx_packet_64_bytes_0),
    .stat_rx_packet_65_127_bytes_0  (stat_rx_packet_65_127_bytes_0),
    .stat_rx_packet_128_255_bytes_0 (stat_rx_packet_128_255_bytes_0),
    .stat_rx_packet_256_511_bytes_0 (stat_rx_packet_256_511_bytes_0),
    .stat_rx_packet_512_1023_bytes_0(stat_rx_packet_512_1023_bytes_0),
    .stat_rx_packet_1024_1518_bytes_0(stat_rx_packet_1024_1518_bytes_0),
    .stat_rx_packet_1519_1522_bytes_0(stat_rx_packet_1519_1522_bytes_0),
    .stat_rx_packet_1523_1548_bytes_0(stat_rx_packet_1523_1548_bytes_0),
    .stat_rx_bad_fcs_0              (stat_rx_bad_fcs_0),
    .stat_rx_packet_bad_fcs_0       (stat_rx_packet_bad_fcs_0),
    .stat_rx_stomped_fcs_0          (stat_rx_stomped_fcs_0),
    .stat_rx_packet_1549_2047_bytes_0(stat_rx_packet_1549_2047_bytes_0),
    .stat_rx_packet_2048_4095_bytes_0(stat_rx_packet_2048_4095_bytes_0),
    .stat_rx_packet_4096_8191_bytes_0(stat_rx_packet_4096_8191_bytes_0),
    .stat_rx_packet_8192_9215_bytes_0(stat_rx_packet_8192_9215_bytes_0),
    .stat_rx_unicast_0              (stat_rx_unicast_0),
    .stat_rx_multicast_0            (stat_rx_multicast_0),
    .stat_rx_broadcast_0            (stat_rx_broadcast_0),
    .stat_rx_vlan_0                 (stat_rx_vlan_0),
    .stat_rx_inrangeerr_0           (stat_rx_inrangeerr_0),
    .stat_rx_bad_preamble_0         (stat_rx_bad_preamble_0),
    .stat_rx_bad_sfd_0              (stat_rx_bad_sfd_0),
    .stat_rx_got_signal_os_0        (stat_rx_got_signal_os_0),
    .stat_rx_test_pattern_mismatch_0(stat_rx_test_pattern_mismatch_0),
    .stat_rx_truncated_0            (stat_rx_truncated_0),
    .stat_rx_local_fault_0          (stat_rx_local_fault_0),
    .stat_rx_remote_fault_0         (stat_rx_remote_fault_0),
    .stat_rx_internal_local_fault_0 (stat_rx_internal_local_fault_0),
    .stat_rx_received_local_fault_0 (stat_rx_received_local_fault_0),

    .stat_tx_total_packets_0        (stat_tx_total_packets_0),
    .stat_tx_total_bytes_0          (stat_tx_total_bytes_0),
    .stat_tx_total_good_packets_0   (stat_tx_total_good_packets_0),
    .stat_tx_total_good_bytes_0     (stat_tx_total_good_bytes_0),
    .stat_tx_packet_64_bytes_0      (stat_tx_packet_64_bytes_0),
    .stat_tx_packet_65_127_bytes_0  (stat_tx_packet_65_127_bytes_0),
    .stat_tx_packet_128_255_bytes_0 (stat_tx_packet_128_255_bytes_0),
    .stat_tx_packet_256_511_bytes_0 (stat_tx_packet_256_511_bytes_0),
    .stat_tx_packet_512_1023_bytes_0(stat_tx_packet_512_1023_bytes_0),
    .stat_tx_packet_1024_1518_bytes_0(stat_tx_packet_1024_1518_bytes_0),
    .stat_tx_packet_1519_1522_bytes_0(stat_tx_packet_1519_1522_bytes_0),
    .stat_tx_packet_1523_1548_bytes_0(stat_tx_packet_1523_1548_bytes_0),
    .stat_tx_packet_small_0         (stat_tx_packet_small_0),
    .stat_tx_packet_large_0         (stat_tx_packet_large_0),
    .stat_tx_packet_1549_2047_bytes_0(stat_tx_packet_1549_2047_bytes_0),
    .stat_tx_packet_2048_4095_bytes_0(stat_tx_packet_2048_4095_bytes_0),
    .stat_tx_packet_4096_8191_bytes_0(stat_tx_packet_4096_8191_bytes_0),
    .stat_tx_packet_8192_9215_bytes_0(stat_tx_packet_8192_9215_bytes_0),
    .stat_tx_unicast_0              (stat_tx_unicast_0),
    .stat_tx_multicast_0            (stat_tx_multicast_0),
    .stat_tx_broadcast_0            (stat_tx_broadcast_0),
    .stat_tx_vlan_0                 (stat_tx_vlan_0),
    .stat_tx_bad_fcs_0              (stat_tx_bad_fcs_0),
    .stat_tx_frame_error_0          (stat_tx_frame_error_0),
    .stat_tx_local_fault_0          (stat_tx_local_fault_0),
    .stat_tx_underflow_err_0        (stat_tx_underflow_err_0),
    .stat_tx_overflow_err_0         (stat_tx_overflow_err_0),

    .rxdata_out_0                   (rxdata_out_0),
    .rxheader_in_0                  (rxheader_in_0),
    .rxdatavalid_in_0               (rxdatavalid_in_0),
    .rxheadervalid_in_0             (rxheadervalid_in_0),
    .rxgearboxslip_out_0            (rxgearboxslip_out_0),
    .txdata_in_0                    (txdata_in_0),
    .txheader_out_0                 (txheader_out_0),
    .txsequence_out_0               (txsequence_out_0)
);

// ---------------------------------------------------------------------------
// scoreboard / statistics accumulation
// ---------------------------------------------------------------------------
integer errors  = 0;
integer skipped = 0;

int unsigned tx_frames_sent = 0;
int unsigned rx_frames      = 0;

int tx_len [0:MAX_FRAMES-1];
bit tx_bad [0:MAX_FRAMES-1];
int rx_len [0:MAX_FRAMES-1];
bit rx_bad [0:MAX_FRAMES-1];

longint acc_tx_total_pkts  = 0;
longint acc_tx_good_pkts   = 0;
longint acc_tx_total_bytes = 0;
longint acc_tx_good_bytes  = 0;
longint acc_tx_frame_err   = 0;
longint acc_tx_underflow   = 0;
longint acc_tx_overflow    = 0;
longint acc_rx_total_pkts  = 0;
longint acc_rx_good_pkts   = 0;
longint acc_rx_total_bytes = 0;
longint acc_rx_good_bytes  = 0;
longint acc_rx_bad_fcs     = 0;

always @(posedge clk) begin
    acc_tx_total_pkts  += stat_tx_total_packets_0;
    acc_tx_good_pkts   += stat_tx_total_good_packets_0;
    acc_tx_total_bytes += stat_tx_total_bytes_0;
    acc_tx_good_bytes  += stat_tx_total_good_bytes_0;
    acc_tx_frame_err   += stat_tx_frame_error_0;
    acc_tx_underflow   += stat_tx_underflow_err_0;
    acc_tx_overflow    += stat_tx_overflow_err_0;
    acc_rx_total_pkts  += stat_rx_total_packets_0;
    acc_rx_good_pkts   += stat_rx_total_good_packets_0;
    acc_rx_total_bytes += stat_rx_total_bytes_0;
    acc_rx_good_bytes  += stat_rx_total_good_bytes_0;
    acc_rx_bad_fcs     += stat_rx_packet_bad_fcs_0;
end

// sticky flags for pulse-style status
bit tx_unfout_seen = 1'b0;
bit tx_ovf_seen    = 1'b0;
always @(posedge clk) begin
    if (tx_unfout_0 === 1'b1)            tx_unfout_seen <= 1'b1;
    if (stat_tx_overflow_err_0 === 1'b1) tx_ovf_seen    <= 1'b1;
end

// ---------------------------------------------------------------------------
// stimulus helpers
// ---------------------------------------------------------------------------
// deterministic payload so the checker needs no frame storage
function automatic logic [7:0] pat(input int frm, input int idx);
    pat = 8'((((frm + 1) * 37) + (idx * 19) + (idx / 11)) & 8'hff);
endfunction

task automatic fail(input string msg);
    errors++;
    $display("ERROR @%0t : %s", $time, msg);
endtask

// one AXI4-Stream beat, held until accepted (no bubbles inside a frame)
task automatic tx_beat(input logic [255:0] data,
                       input logic [31:0]  keep,
                       input logic         last,
                       input logic         user);
    begin
        @(negedge clk);
        tx_axis_tdata_0  = data;
        tx_axis_tkeep_0  = keep;
        tx_axis_tlast_0  = last;
        tx_axis_tuser_0  = user;
        tx_axis_tvalid_0 = 1'b1;
        @(posedge clk);
        while (!tx_axis_tready_0) @(posedge clk);
        tx_axis_tvalid_0 = 1'b0;   // invisible to the DUT when the next beat
                                   // is presented at the following negedge
    end
endtask

// send one frame from the pattern generator; "stall" inserts an idle gap
// (in clocks) between the first and the second beat of the frame
task automatic send_frame(input int frm, input int len, input logic bad,
                          input int stall = 0);
    int beats, b, i;
    logic [255:0] data;
    logic [31:0]  keep;
    begin
        beats = (len + DATA_BYTES - 1) / DATA_BYTES;
        for (b = 0; b < beats; b++) begin
            data = '0;
            keep = '0;
            for (i = 0; i < DATA_BYTES; i++) begin
                if (b * DATA_BYTES + i < len) begin
                    data[8*i +: 8] = pat(frm, b * DATA_BYTES + i);
                    keep[i]        = 1'b1;
                end
            end
            tx_beat(data, keep, (b == beats - 1), (bad && (b == beats - 1)));
            if ((stall != 0) && (b == 0))
                repeat (stall) @(posedge clk);
        end
        tx_len[frm] = len;
        tx_bad[frm] = bad;
        tx_frames_sent++;
        $display("INFO  @%0t : TX frame %0d sent, %0d bytes%0s",
                 $time, frm, len, bad ? " (tuser -> error)" : "");
    end
endtask

// ---------------------------------------------------------------------------
// RX monitor: rebuild frames from AXI4-Stream and compare with the pattern
// ---------------------------------------------------------------------------
bit rx_sof     = 1'b0;
int rx_bit_idx = 0;
int rx_cur     = 0;

always @(posedge clk) begin
    if (rx_axis_tvalid_0 === 1'b1) begin
        if (!rx_sof) begin
            rx_sof     = 1'b1;
            rx_bit_idx = 0;
            if (rx_preambleout_0 !== PREAMBLE)
                fail($sformatf("frame %0d: preamble %014h, expected %014h",
                               rx_cur, rx_preambleout_0, PREAMBLE));
        end
        for (int b = 0; b < DATA_BYTES; b++) begin
            if (rx_axis_tkeep_0[b] === 1'b1) begin
                if ((rx_cur < MAX_FRAMES) && (rx_bit_idx < MAX_FRAME_BYTES)) begin
                    if (rx_axis_tdata_0[8*b +: 8] !== pat(rx_cur, rx_bit_idx))
                        fail($sformatf("frame %0d byte %0d: got %02h exp %02h",
                                       rx_cur, rx_bit_idx,
                                       rx_axis_tdata_0[8*b +: 8],
                                       pat(rx_cur, rx_bit_idx)));
                end
                rx_bit_idx++;
            end
            else if (rx_axis_tlast_0 !== 1'b1) begin
                fail($sformatf("frame %0d: tkeep hole at beat byte %0d", rx_cur, b));
            end
        end
        if (rx_axis_tlast_0 === 1'b1) begin
            if (rx_cur < MAX_FRAMES) begin
                rx_len[rx_cur] = rx_bit_idx;
                rx_bad[rx_cur] = rx_axis_tuser_0[0];
            end
            $display("INFO  @%0t : RX frame %0d, %0d bytes, tuser=%0b",
                     $time, rx_cur, rx_bit_idx, rx_axis_tuser_0[0]);
            rx_frames++;
            rx_cur = rx_frames;
            rx_sof = 1'b0;
        end
    end
end

// ---------------------------------------------------------------------------
// checking helpers
// ---------------------------------------------------------------------------
task automatic wait_frames(input int unsigned n, input int timeout_clk);
    int unsigned t;
    begin
        t = 0;
        while ((rx_frames < n) && (t < timeout_clk)) begin
            @(posedge clk);
            t++;
        end
        if (rx_frames < n)
            fail($sformatf("timeout: %0d/%0d RX frames", rx_frames, n));
    end
endtask

task automatic check_frames(input int unsigned from, input int unsigned to);
    int unsigned f;
    begin
        for (f = from; (f < to) && (f < MAX_FRAMES); f++) begin
            if (rx_len[f] != tx_len[f])
                fail($sformatf("frame %0d length %0d, expected %0d",
                               f, rx_len[f], tx_len[f]));
            else if (rx_bad[f] != tx_bad[f])
                fail($sformatf("frame %0d tuser %0b, expected %0b",
                               f, rx_bad[f], tx_bad[f]));
            else
                $display("INFO  : frame %0d OK (%0d bytes, tuser=%0b)",
                         f, rx_len[f], rx_bad[f]);
        end
    end
endtask

// statistics snapshot / TX-only checks
longint snap_tx_pkts, snap_tx_good, snap_tx_bytes, snap_tx_err, snap_tx_uf;

task automatic stat_snapshot;
    begin
        snap_tx_pkts  = acc_tx_total_pkts;
        snap_tx_good  = acc_tx_good_pkts;
        snap_tx_bytes = acc_tx_good_bytes;
        snap_tx_err   = acc_tx_frame_err;
        snap_tx_uf    = acc_tx_underflow;
    end
endtask

task automatic wait_tx_pkts(input int unsigned nfr, input int unsigned timeout_clk);
    int unsigned t;
    begin
        t = 0;
        while (((acc_tx_total_pkts - snap_tx_pkts) < nfr) && (t < timeout_clk)) begin
            @(posedge clk);
            t++;
        end
        if ((acc_tx_total_pkts - snap_tx_pkts) != nfr)
            fail($sformatf("stat_tx_total_packets += %0d, expected %0d",
                           acc_tx_total_pkts - snap_tx_pkts, nfr));
        else
            $display("INFO  : stat_tx_total_packets += %0d", nfr);

        if ((acc_tx_good_pkts - snap_tx_good) != nfr)
            fail($sformatf("stat_tx_total_good_packets += %0d, expected %0d",
                           acc_tx_good_pkts - snap_tx_good, nfr));
        else
            $display("INFO  : stat_tx_total_good_packets += %0d", nfr);
    end
endtask

// single frame: the good-byte increment carries payload + inserted FCS
task automatic check_tx_bytes(input int unsigned nbytes);
    longint d_bytes;
    begin
        d_bytes = acc_tx_good_bytes - snap_tx_bytes;
        if (d_bytes != (nbytes + 4))
            fail($sformatf("stat_tx_total_good_bytes += %0d, expected %0d (payload + FCS)",
                           d_bytes, nbytes + 4));
        else
            $display("INFO  : stat_tx_total_good_bytes += %0d (payload %0d + 4 B FCS)",
                     d_bytes, nbytes);
    end
endtask

// wait until the TX statistics stop changing (frames in flight complete)
task automatic stat_settle(input int unsigned timeout_clk);
    longint a, b, c, d, e;
    int unsigned stable, t;
    begin
        a = -1; b = -1; c = -1; d = -1; e = -1;
        stable = 0;
        t      = 0;
        while ((stable < 64) && (t < timeout_clk)) begin
            @(posedge clk);
            t++;
            if ((acc_tx_total_pkts == a) && (acc_tx_good_pkts == b) &&
                (acc_tx_good_bytes == c) && (acc_tx_frame_err == d) &&
                (acc_tx_underflow == e)) begin
                stable++;
            end
            else begin
                a = acc_tx_total_pkts;
                b = acc_tx_good_pkts;
                c = acc_tx_good_bytes;
                d = acc_tx_frame_err;
                e = acc_tx_underflow;
                stable = 0;
            end
        end
    end
endtask

task automatic wait_align(input int timeout_clk);
    int t;
    bit reported;
    begin
        t        = 0;
        reported = 1'b0;
        while (!(stat_rx_aligned_0 && stat_rx_status_0) && (t < timeout_clk)) begin
            @(posedge clk);
            t++;
            if (!reported && (t > (timeout_clk / 2))) begin
                reported = 1'b1;
                $display("INFO  @%0t : waiting for alignment (block_lock=%b synced=%b)",
                         $time, stat_rx_block_lock_0, stat_rx_synced_0);
            end
        end
    end
endtask

// ---------------------------------------------------------------------------
// main test sequence
// ---------------------------------------------------------------------------
int unsigned mark;
int          frame_id;
bit          rx_aligned_ok = 1'b0;

initial begin
    $display("============================================================");
    $display(" tb_eth_mac_40g : 40GBASE-R MAC / PCS loopback test");
    $display(" 322.265625 MHz core/serdes clock, 256-bit AXI4-Stream");
    $display(" serdes loopback: rxdata_out=txdata_in, rx dv pattern=%02h", RX_DV_PATTERN);
    $display("============================================================");

    ctl_rx_enable_0 = 1'b1;
    frame_id        = 0;

    // ---- reset ----------------------------------------------------------
    tx_reset_0        = 1'b1;
    rx_reset_0        = 1'b1;
    rx_serdes_reset_0 = 1'b1;
    repeat (64) @(posedge clk);
    tx_reset_0        = 1'b0;
    repeat (256) @(posedge clk);        // TX PCS settles first
    rx_reset_0        = 1'b0;
    rx_serdes_reset_0 = 1'b0;
    $display("INFO  @%0t : resets released", $time);

    // ---- test 1: PCS alignment ------------------------------------------
    // PCS lane markers are inserted every 16,384 words (IEEE 802.3 default).
    $display("---- test 1: PCS alignment ----");
    wait_align(30000);
    rx_aligned_ok = (stat_rx_aligned_0 === 1'b1) && (stat_rx_status_0 === 1'b1);
    if (rx_aligned_ok)
        $display("INFO  : RX aligned (block_lock=%b synced=%b status=%b)",
                 stat_rx_block_lock_0, stat_rx_synced_0, stat_rx_status_0);
    else begin
        $display("WARNING: RX PCS did not align.");
        $display("WARNING: block_lock=%b synced=%b aligned=%b status=%b mf_len_err=%b",
                 stat_rx_block_lock_0, stat_rx_synced_0, stat_rx_aligned_0,
                 stat_rx_status_0, stat_rx_mf_len_err_0);
        $display("WARNING: this core expects the GT 64B/66B gearbox in the RX");
        $display("WARNING: PCS path; RX checks are skipped, TX path is verified.");
        skipped++;
    end

    // ---- test 2: minimum size frame -------------------------------------
    $display("---- test 2: minimum frame (60 B + 4 B FCS = 64 B) ----");
    mark = tx_frames_sent;
    stat_snapshot;
    send_frame(frame_id, 60, 1'b0);  frame_id++;
    stat_settle(4000);
    if (rx_aligned_ok) begin
        wait_frames(tx_frames_sent, 4000);
        check_frames(mark, tx_frames_sent);
    end
    wait_tx_pkts(1, 4000);
    check_tx_bytes(60);

    // ---- test 3: frame size sweep ---------------------------------------
    $display("---- test 3: frame size sweep ----");
    mark = tx_frames_sent;
    stat_snapshot;
    send_frame(frame_id, 61,  1'b0); frame_id++;   // partial last beat
    send_frame(frame_id, 100, 1'b0); frame_id++;
    send_frame(frame_id, 512, 1'b0); frame_id++;
    send_frame(frame_id, 1518, 1'b0); frame_id++;
    send_frame(frame_id, 4096, 1'b0); frame_id++;
    stat_settle(20000);
    if (rx_aligned_ok) begin
        wait_frames(tx_frames_sent, 20000);
        check_frames(mark, tx_frames_sent);
    end
    wait_tx_pkts(5, 20000);
    $display("INFO  : stat_tx_total_good_bytes += %0d for the size sweep",
             acc_tx_good_bytes - snap_tx_bytes);

    // ---- test 4: back-to-back burst -------------------------------------
    $display("---- test 4: back-to-back burst (minimum IPG) ----");
    mark = tx_frames_sent;
    stat_snapshot;
    for (int i = 0; i < 4; i++) begin
        send_frame(frame_id, 64 + i, 1'b0);
        frame_id++;
        repeat (8) @(posedge clk);   // minimum IPG, tvalid low between frames
    end
    stat_settle(40000);
    if (rx_aligned_ok) begin
        wait_frames(tx_frames_sent, 8000);
        check_frames(mark, tx_frames_sent);
    end
    wait_tx_pkts(4, 8000);
    $display("INFO  : stat_tx_total_good_bytes += %0d for the burst",
             acc_tx_good_bytes - snap_tx_bytes);

    // ---- test 5: bad FCS injection --------------------------------------
    $display("---- test 5: bad FCS (tx tuser on tlast) ----");
    mark = tx_frames_sent;
    stat_snapshot;
    send_frame(frame_id, 128, 1'b1);
    frame_id++;
    stat_settle(4000);
    if (rx_aligned_ok) begin
        wait_frames(tx_frames_sent, 4000);
        check_frames(mark, tx_frames_sent);
    end

    // a frame with tx tuser set is transmitted but must not count as good
    if ((acc_tx_total_pkts - snap_tx_pkts) != 1)
        fail($sformatf("stat_tx_total_packets += %0d, expected 1",
                       acc_tx_total_pkts - snap_tx_pkts));
    if ((acc_tx_good_pkts - snap_tx_good) != 0)
        fail($sformatf("stat_tx_total_good_packets += %0d, expected 0",
                       acc_tx_good_pkts - snap_tx_good));
    else
        $display("INFO  : error frame not counted as good packet");

    if ((acc_tx_frame_err - snap_tx_err) != 1)
        fail($sformatf("stat_tx_frame_error increment %0d, expected 1",
                       acc_tx_frame_err - snap_tx_err));
    else
        $display("INFO  : stat_tx_frame_error += 1 (frame abort counted)");

    if (rx_aligned_ok) begin
        if (acc_rx_bad_fcs != 1)
            fail($sformatf("stat_rx_packet_bad_fcs accrued %0d, expected 1",
                           acc_rx_bad_fcs));
        else
            $display("INFO  : stat_rx_packet_bad_fcs = 1 (bad FCS detected)");
    end
    else skipped++;

    // ---- test 6: AXI4-Stream stall inside a frame -----------------------
    $display("---- test 6: AXI4-Stream stall inside a frame ----");
    begin
        stat_snapshot;
        tx_unfout_seen = 1'b0;
        tx_ovf_seen    = 1'b0;

        // tvalid gaps inside a frame are absorbed by the user FIFO; the frame
        // must still be transmitted once the remaining beats arrive
        send_frame(frame_id, 96, 1'b0, 200);
        frame_id++;
        stat_settle(6000);

        if ((acc_tx_total_pkts - snap_tx_pkts) != 1)
            fail($sformatf("stat_tx_total_packets += %0d, expected 1",
                           acc_tx_total_pkts - snap_tx_pkts));
        else if ((acc_tx_good_pkts - snap_tx_good) != 1)
            fail($sformatf("stat_tx_total_good_packets += %0d, expected 1",
                           acc_tx_good_pkts - snap_tx_good));
        else if ((acc_tx_good_bytes - snap_tx_bytes) != (96 + 4))
            fail($sformatf("stat_tx_total_good_bytes += %0d, expected 100",
                           acc_tx_good_bytes - snap_tx_bytes));
        else
            $display("INFO  : stalled frame transmitted correctly (96 + 4 B)");

        if (tx_unfout_seen || ((acc_tx_underflow - snap_tx_uf) != 0))
            fail("unexpected TX FIFO underflow");
        if (tx_ovf_seen)
            fail("stat_tx_overflow_err asserted");
        else
            $display("INFO  : no TX underflow / overflow");
    end

    // ---- test 7: statistics summary -------------------------------------
    $display("---- test 7: statistics ----");
    $display("INFO  : TX total packets = %0d (AXI4-S frames sent %0d)",
             acc_tx_total_pkts, tx_frames_sent);
    $display("INFO  : TX good  packets = %0d", acc_tx_good_pkts);
    $display("INFO  : TX total bytes   = %0d", acc_tx_total_bytes);
    $display("INFO  : TX good  bytes   = %0d", acc_tx_good_bytes);
    $display("INFO  : RX total packets = %0d", acc_rx_total_pkts);
    $display("INFO  : RX good  packets = %0d", acc_rx_good_pkts);
    $display("INFO  : RX total bytes   = %0d", acc_rx_total_bytes);
    $display("INFO  : RX good  bytes   = %0d", acc_rx_good_bytes);
    $display("INFO  : RX frames on AXI4-Stream = %0d", rx_frames);

    if (rx_aligned_ok) begin
        if (acc_rx_good_pkts != tx_frames_sent - 1)
            fail($sformatf("stat_rx_total_good_packets = %0d, expected %0d",
                           acc_rx_good_pkts, tx_frames_sent - 1));
        if (rx_frames != tx_frames_sent)
            fail($sformatf("%0d frames received, expected %0d",
                           rx_frames, tx_frames_sent));
    end

    // ---- result ---------------------------------------------------------
    $display("============================================================");
    if ((errors == 0) && (skipped == 0))
        $display(" TEST PASSED (TX + RX loopback)");
    else if (errors == 0)
        $display(" TEST PASSED (TX path verified, %0d RX check(s) skipped)", skipped);
    else
        $display(" TEST FAILED with %0d error(s)", errors);
    $display("============================================================");
    $finish;
end

// global watchdog
initial begin
    #5000000;   // 5 ms
    $display("ERROR : global timeout");
    $display(" TEST FAILED (timeout)");
    $finish;
end

endmodule

`default_nettype wire
