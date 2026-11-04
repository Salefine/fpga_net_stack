/****************************************************************************
 * @file    udp_layer.v
 * @brief  
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.0
 * @date    2026-10-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.0      |    zzhi          | udp layer              |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2026 zzhi
 * @date    2026-10-22
 * ***************************************************************************/

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * udp_layer integrates the two halves of the UDP layer:
 *
 *   udp_rx: verifies the UDP checksum (pseudo-header from recv_*_ip_addr),
 *           filters datagrams by destination port (local_udp_port =
 *           udp_src_port) and source port (dst_udp_port = udp_dst_port),
 *           strips padding down to the UDP length and hands the payload
 *           to the application
 *   udp_tx: frames the application payload into UDP datagrams (ports,
 *           length, checksum) once configure_done is asserted
 *
 * Receive metadata (recv_src_ip_addr / recv_dst_ip_addr) comes from the
 * IP layer (ip_layer) of the frame currently being demultiplexed; the
 * datagram itself arrives through the protocol demux on udp_rx_axis_*.
 */
module udp_layer#(
    parameter   UDP_LAYER_TDATA_WIDTH     =   64,
    parameter   UDP_LAYER_TKEEP_WIDTH     =   UDP_LAYER_TDATA_WIDTH / 8
)(
    input   wire    clk,
    input   wire    rst,

    /* configuration (from the stack-level / VIO registers) */
    input   wire [31:0]  src_ip_addr,         // local address (pseudo-header, tx)
    input   wire [31:0]  dst_ip_addr,         // remote address (pseudo-header, tx)
    input   wire [15:0]  udp_src_port,        // local port (tx source / rx filter)
    input   wire [15:0]  udp_dst_port,        // remote port (tx destination / rx filter)
    input   wire         configure_done,      // ARP resolution completed, tx enabled

    /* receive metadata from the IP layer */
    input   wire [31:0]  recv_dst_ip_addr,    // destination address of the current frame
    input   wire [31:0]  recv_src_ip_addr,    // source address of the current frame

    /* UDP datagrams from the IP protocol demux (protocol 0x11) */
    input   wire [UDP_LAYER_TDATA_WIDTH - 1 : 0]  udp_rx_axis_tdata,
    input   wire [UDP_LAYER_TKEEP_WIDTH - 1 : 0]  udp_rx_axis_tkeep,
    input   wire                                     udp_rx_axis_tvalid,
    input   wire                                     udp_rx_axis_tlast,
    output  wire                                     udp_rx_axis_tready,
    input   wire                                     udp_rx_axis_tuser,

    /* payload to the application */
    output  wire [UDP_LAYER_TDATA_WIDTH - 1 : 0]  app_rx_axis_tdata,
    output  wire [UDP_LAYER_TKEEP_WIDTH - 1 : 0]  app_rx_axis_tkeep,
    output  wire                                     app_rx_axis_tvalid,
    output  wire                                     app_rx_axis_tlast,
    output  wire                                     app_rx_axis_tuser,
    input   wire                                     app_rx_axis_tready,

    /* payload from the application */
    input   wire [UDP_LAYER_TDATA_WIDTH - 1 : 0]  app_tx_axis_tdata,
    input   wire [UDP_LAYER_TKEEP_WIDTH - 1 : 0]  app_tx_axis_tkeep,
    input   wire                                     app_tx_axis_tvalid,
    input   wire                                     app_tx_axis_tlast,
    output  wire                                     app_tx_axis_tready,

    /* UDP datagrams to the IP layer (via the TX arbiter) */
    output  wire [UDP_LAYER_TDATA_WIDTH - 1 : 0]  ip_tx_axis_tdata,
    output  wire [UDP_LAYER_TKEEP_WIDTH - 1 : 0]  ip_tx_axis_tkeep,
    output  wire                                     ip_tx_axis_tvalid,
    output  wire                                     ip_tx_axis_tlast,
    input   wire                                     ip_tx_axis_tready
);

udp_rx udp_rx_inst(
    .clk       	(clk),
    .rst    	(rst),

    .recv_dst_ip_addr   	(recv_dst_ip_addr),
    .recv_src_ip_addr   	(recv_src_ip_addr),
    .local_udp_port     	(udp_src_port    ),
    .dst_udp_port       	(udp_dst_port    ),

    .udp_rx_axis_tdata   	(udp_rx_axis_tdata ),
    .udp_rx_axis_tkeep   	(udp_rx_axis_tkeep ),
    .udp_rx_axis_tvalid  	(udp_rx_axis_tvalid),
    .udp_rx_axis_tlast   	(udp_rx_axis_tlast ),
    .udp_rx_axis_tready  	(udp_rx_axis_tready),
    .udp_rx_axis_tuser   	(udp_rx_axis_tuser ),

    .app_rx_axis_tdata  	(app_rx_axis_tdata ),
    .app_rx_axis_tkeep  	(app_rx_axis_tkeep ),
    .app_rx_axis_tvalid 	(app_rx_axis_tvalid),
    .app_rx_axis_tlast  	(app_rx_axis_tlast ),
    .app_rx_axis_tuser     (app_rx_axis_tuser),
    .app_rx_axis_tready 	(app_rx_axis_tready)
);

udp_tx udp_tx_inst(
    .clk       	(clk),
    .rst    	(rst),

    .src_ip_addr   (src_ip_addr     ),
    .dst_ip_addr   (dst_ip_addr     ),
    .udp_src_port  (udp_src_port    ),
    .udp_dst_port  (udp_dst_port    ),
    .configure_done(configure_done  ),

    .udp_tx_axis_tdata   (app_tx_axis_tdata   ),
    .udp_tx_axis_tkeep   (app_tx_axis_tkeep   ),
    .udp_tx_axis_tvalid  (app_tx_axis_tvalid  ),
    .udp_tx_axis_tlast   (app_tx_axis_tlast   ),
    .udp_tx_axis_tready  (app_tx_axis_tready  ),

    .ip_tx_axis_tdata    (ip_tx_axis_tdata    ),
    .ip_tx_axis_tkeep    (ip_tx_axis_tkeep    ),
    .ip_tx_axis_tvalid   (ip_tx_axis_tvalid   ),
    .ip_tx_axis_tlast    (ip_tx_axis_tlast    ),
    .ip_tx_axis_tready   (ip_tx_axis_tready   )
);

endmodule

`resetall