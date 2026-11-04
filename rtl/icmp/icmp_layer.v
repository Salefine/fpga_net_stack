/****************************************************************************
 * @file    icmp_layer.v
 * @brief  
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.0
 * @date    2025-01-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.0      |    zzhi          | icmp layer             |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2025 zzhi
 * ***************************************************************************/

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * icmp_layer integrates the two halves of the ICMP echo responder:
 *
 *   icmp_rx: parses and checksum-verifies echo requests, stores them in a
 *            payload FIFO and replays them (bad frames are drained)
 *   icmp_tx: rebuilds the reply (type 0, adjusted checksum) and streams it
 *            back to the IP layer
 *
 * Both halves run in one clock domain; the internal icmp_rx -> icmp_tx link
 * is a plain AXI4-Stream with valid/ready flow control, so the module is
 * safe to drop into any streaming pipeline.
 *
 * Boundary behaviour:
 *   - requests are accepted (icmp_rx_axis_tready) only while a frame is
 *     being parsed and the internal FIFO has room
 *   - replies are held on the output while icmp_tx_axis_tready is low
 *   - one echo request is processed at a time
 */
module icmp_layer#(
    parameter   ICMP_LAYER_TDATA_WIDTH     =   64,
    parameter   ICMP_LAYER_TKEEP_WIDTH     =   ICMP_LAYER_TDATA_WIDTH / 8
)(
    input   wire    clk,
    input   wire    rst,

    output  wire    icmp_not_empty,

    /* echo requests from the IP layer (IPv4 protocol 1) */
    input   wire    [ICMP_LAYER_TDATA_WIDTH - 1 : 0]     icmp_rx_axis_tdata  ,
    input   wire    [ICMP_LAYER_TKEEP_WIDTH - 1 : 0]     icmp_rx_axis_tkeep  ,
    input   wire                                       icmp_rx_axis_tvalid ,
    input   wire                                       icmp_rx_axis_tlast  ,
    input   wire                                       icmp_rx_axis_tuser  ,
    output  wire                                       icmp_rx_axis_tready,

    /* echo replies to the IP layer */
    output  wire    [ICMP_LAYER_TDATA_WIDTH - 1 : 0]     icmp_tx_axis_tdata  ,
    output  wire    [ICMP_LAYER_TKEEP_WIDTH - 1 : 0]     icmp_tx_axis_tkeep  ,
    output  wire                                       icmp_tx_axis_tvalid ,
    output  wire                                       icmp_tx_axis_tlast  ,
    input   wire                                       icmp_tx_axis_tready
);

/* internal icmp_rx -> icmp_tx link (plain AXI4-Stream, same clock domain) */
(* MARK_DEBUG="true" *)wire [ICMP_LAYER_TDATA_WIDTH - 1 : 0] int_axis_tdata;
(* MARK_DEBUG="true" *)wire [ICMP_LAYER_TKEEP_WIDTH - 1 : 0] int_axis_tkeep;
(* MARK_DEBUG="true" *)wire                                  int_axis_tvalid;
(* MARK_DEBUG="true" *)wire                                  int_axis_tlast;
(* MARK_DEBUG="true" *)wire                                  int_axis_tuser;
(* MARK_DEBUG="true" *)wire                                  int_axis_tready;

icmp_rx #(
    .ICMP_RX_TDATA_WIDTH     (ICMP_LAYER_TDATA_WIDTH),
    .ICMP_RX_TKEEP_WIDTH     (ICMP_LAYER_TKEEP_WIDTH)
)
icmp_rx_inst (
    .rx_axis_aclk            (clk                 ),
    .rx_axis_aresetn         (~rst                ),

    .ip_rx_axis_tdata        (icmp_rx_axis_tdata  ),
    .ip_rx_axis_tkeep        (icmp_rx_axis_tkeep  ),
    .ip_rx_axis_tvalid       (icmp_rx_axis_tvalid ),
    .ip_rx_axis_tlast        (icmp_rx_axis_tlast  ),
    .ip_rx_axis_tuser        (icmp_rx_axis_tuser  ),
    .ip_rx_axis_tready       (icmp_rx_axis_tready),

    .icmp_rx_axis_tdata      (int_axis_tdata      ),
    .icmp_rx_axis_tkeep      (int_axis_tkeep      ),
    .icmp_rx_axis_tvalid     (int_axis_tvalid     ),
    .icmp_rx_axis_tlast      (int_axis_tlast      ),
    .icmp_rx_axis_tuser      (int_axis_tuser      ),
    .icmp_rx_axis_tready     (int_axis_tready     )
);

icmp_tx #(
    .ICMP_TX_TDATA_WIDTH     (ICMP_LAYER_TDATA_WIDTH),
    .ICMP_TX_TKEEP_WIDTH     (ICMP_LAYER_TKEEP_WIDTH)
)
icmp_tx_inst (
    .tx_axis_aclk            (clk                 ),
    .tx_axis_aresetn         (~rst                ),

    .icmp_not_empty          (icmp_not_empty      ),

    .icmp_rx_axis_tdata      (int_axis_tdata      ),
    .icmp_rx_axis_tkeep      (int_axis_tkeep      ),
    .icmp_rx_axis_tvalid     (int_axis_tvalid     ),
    .icmp_rx_axis_tlast      (int_axis_tlast      ),
    .icmp_rx_axis_tuser      (int_axis_tuser      ),
    .icmp_rx_axis_tready     (int_axis_tready     ),

    .icmp_tx_axis_tdata      (icmp_tx_axis_tdata  ),
    .icmp_tx_axis_tkeep      (icmp_tx_axis_tkeep  ),
    .icmp_tx_axis_tvalid     (icmp_tx_axis_tvalid ),
    .icmp_tx_axis_tlast      (icmp_tx_axis_tlast  ),
    .icmp_tx_axis_tready     (icmp_tx_axis_tready )
);

endmodule
`resetall