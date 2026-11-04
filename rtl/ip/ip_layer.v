/****************************************************************************
 * @file    ip_layer.v
 * @brief  
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.0
 * @date    2025-01-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.0      |    zzhi          | udp stack              |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2026 zzhi
 * ***************************************************************************/

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ip_layer integrates the two halves of the IPv4 layer:
 *
 *   ip_rx: parses/validates the IPv4 header (checksum, destination-IP
 *          filter), strips it, realigns the payload to the transport
 *          boundary and exports src/dst address + protocol metadata
 *   ip_tx: builds the IPv4 header (length, id, checksum) around the
 *          transport payload and streams the complete IP packet
 *
 * The protocol demux (UDP / ICMP / TCP ...) lives above this module:
 * it switches on ip_type and drives ip_rx_axis_tready; the transport
 * arbiter feeding ip_tx_axis_* selects the sender via ip_send_type.
 */
module ip_layer#(
    parameter   IP_LAYER_TDATA_WIDTH     =   64,
    parameter   IP_LAYER_TKEEP_WIDTH     =   IP_LAYER_TDATA_WIDTH / 8
)(
    input   wire    clk,
    input   wire    rst,

    /* configuration (from the stack-level address registers) */
    input   wire [31:0]  local_ip_addr,       // rx destination-IP filter
    input   wire [31:0]  src_ip_addr,         // tx header source address
    input   wire [31:0]  dst_ip_addr,         // tx header destination address
    input   wire [7:0]   ip_send_type,        // tx protocol number (from the TX arbiter)

    /* IP packets from the ethertype demux (ethertype 0x0800) */
    input   wire [IP_LAYER_TDATA_WIDTH - 1 : 0]  frame_rx_axis_tdata,
    input   wire [IP_LAYER_TKEEP_WIDTH - 1 : 0]  frame_rx_axis_tkeep,
    input   wire                                     frame_rx_axis_tvalid,
    input   wire                                     frame_rx_axis_tlast,
    input   wire                                     frame_rx_axis_tuser,
    output  wire                                     frame_rx_axis_tready,

    /* transport payload + metadata to the protocol demux */
    output  wire [IP_LAYER_TDATA_WIDTH - 1 : 0]  ip_rx_axis_tdata,
    output  wire [IP_LAYER_TKEEP_WIDTH - 1 : 0]  ip_rx_axis_tkeep,
    output  wire                                     ip_rx_axis_tvalid,
    output  wire                                     ip_rx_axis_tlast,
    output  wire                                     ip_rx_axis_tuser,
    input   wire                                     ip_rx_axis_tready,
    output  wire [31:0]                             recv_src_ip_addr,   // source address of the current frame
    output  wire [31:0]                             recv_dst_ip_addr,   // destination address of the current frame
    output  wire [15:0]                             ip_type,            // protocol number of the current frame
    output  wire [15:0]                             ip_payload_len,     // total_length - IHL*4

    /* transport payload from the TX arbiter */
    input   wire [IP_LAYER_TDATA_WIDTH - 1 : 0]  ip_tx_axis_tdata,
    input   wire [IP_LAYER_TKEEP_WIDTH - 1 : 0]  ip_tx_axis_tkeep,
    input   wire                                     ip_tx_axis_tvalid,
    input   wire                                     ip_tx_axis_tlast,
    output  wire                                     ip_tx_axis_tready,

    /* complete IP packets to the ethernet TX arbiter */
    output  wire [IP_LAYER_TDATA_WIDTH - 1 : 0]  frame_tx_axis_tdata,
    output  wire [IP_LAYER_TKEEP_WIDTH - 1 : 0]  frame_tx_axis_tkeep,
    output  wire                                     frame_tx_axis_tvalid,
    output  wire                                     frame_tx_axis_tlast,
    input   wire                                     frame_tx_axis_tready
);

ip_rx ip_rx_inst(
    .clk       	(clk),
    .rst     	(rst),

    .frame_rx_axis_tdata    (frame_rx_axis_tdata ),
    .frame_rx_axis_tkeep    (frame_rx_axis_tkeep ),
    .frame_rx_axis_tvalid   (frame_rx_axis_tvalid),
    .frame_rx_axis_tlast    (frame_rx_axis_tlast ),
    .frame_rx_axis_tuser    (frame_rx_axis_tuser ),
    .frame_rx_axis_tready   (frame_rx_axis_tready),

    .ip_rx_axis_tdata     	(ip_rx_axis_tdata    ),
    .ip_rx_axis_tkeep     	(ip_rx_axis_tkeep    ),
    .ip_rx_axis_tvalid    	(ip_rx_axis_tvalid   ),
    .ip_rx_axis_tlast     	(ip_rx_axis_tlast    ),
    .ip_rx_axis_tuser     	(ip_rx_axis_tuser    ),
    .ip_rx_axis_tready   	(ip_rx_axis_tready   ),

    .local_ip_addr        	(local_ip_addr       ),
    .recv_dst_ip_addr     	(recv_dst_ip_addr    ),
    .recv_src_ip_addr     	(recv_src_ip_addr    ),
    .ip_type              	(ip_type             ),
    .ip_payload_len       	(ip_payload_len      )
);

ip_tx ip_tx_inst(
    .ip_send_type  (ip_send_type),
    .src_ip_addr   (src_ip_addr ),
    .dst_ip_addr   (dst_ip_addr ),

    .clk  (clk),
    .rst  (rst),

    .ip_tx_axis_tdata     	(ip_tx_axis_tdata    ),
    .ip_tx_axis_tkeep     	(ip_tx_axis_tkeep    ),
    .ip_tx_axis_tvalid    	(ip_tx_axis_tvalid   ),
    .ip_tx_axis_tlast     	(ip_tx_axis_tlast    ),
    .ip_tx_axis_tready    	(ip_tx_axis_tready   ),

    .frame_tx_axis_tdata  	(frame_tx_axis_tdata ),
    .frame_tx_axis_tkeep  	(frame_tx_axis_tkeep ),
    .frame_tx_axis_tvalid 	(frame_tx_axis_tvalid),
    .frame_tx_axis_tlast  	(frame_tx_axis_tlast ),
    .frame_tx_axis_tready 	(frame_tx_axis_tready)
);

endmodule

`resetall