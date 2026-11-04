/****************************************************************************
 * @file    udp_stack_top.v
 * @brief  
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.0
 * @date    2025-01-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.0      |    zzhi          | Support 100Gbps        |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2026 zzhi
 * ***************************************************************************/

`resetall
`timescale 1ns / 1ps
`default_nettype none

module udp_stack_top (
    input   wire    clk,
    input   wire    rst,

    input   wire    desc_axis_tvalid,
    output  wire    desc_axis_tready,
    output  wire    configuration_done,
    input   wire [31:0]  src_ip_addr ,
    input   wire [31:0]  gateway_ip_addr ,
    input   wire [31:0]  subnet_mask ,
    input   wire [31:0]  dst_ip_addr ,
    input   wire [47:0]  src_mac_addr,
    input   wire [15:0]  udp_src_port,
    input   wire [15:0]  udp_dst_port,

	/* udp tx axis interface */		  
    input   wire [63:0]  app_tx_axis_tdata ,
    input   wire [7:0]   app_tx_axis_tkeep ,
    input   wire         app_tx_axis_tvalid,		 
    input   wire         app_tx_axis_tlast ,
    output  wire         app_tx_axis_tready,

	output  wire [63:0]  app_rx_axis_tdata ,
    output  wire [7:0]   app_rx_axis_tkeep ,
    output  wire         app_rx_axis_tvalid,		 
    output  wire         app_rx_axis_tlast ,
    output  wire         app_rx_axis_tuser ,
    input   wire         app_rx_axis_tready,

    output  wire [63:0]  mac_tx_axis_tdata ,
    output  wire [7:0]   mac_tx_axis_tkeep ,
    output  wire         mac_tx_axis_tvalid,
    output  wire         mac_tx_axis_tlast ,
    output  wire         mac_tx_axis_tuser ,
    input   wire         mac_tx_axis_tready,

    input   wire[63:0]   mac_rx_axis_tdata   ,
    input   wire[7:0]    mac_rx_axis_tkeep   ,
    input   wire         mac_rx_axis_tvalid  ,
    input   wire         mac_rx_axis_tuser   ,
    output  wire         mac_rx_axis_tready  ,
    input   wire         mac_rx_axis_tlast       
);

localparam REQUEST_RETRY_COUNT    = 4;
localparam REQUEST_RETRY_INTERVAL = 125000000*2;
localparam REQUEST_TIMEOUT        = 125000000*30;

reg arp_request_start = 'b0;
reg desc_axis_tready_reg = 1'b0;
reg [31:0] src_ip_addr_reg = 'b0;
reg [31:0] dst_ip_addr_reg = 'b0;
reg [47:0] src_mac_addr_reg = 'b0;

reg  arp_request_valid = 'b0;
reg  [31:0] arp_request_ip = 'b0;
reg  configuration_done_reg = 1'b0;
reg  arp_response_ready = 'b0;
reg  [47:0] arp_resolved_mac_reg = 'b0;

wire arp_request_ready;
wire arp_response_valid;
wire arp_response_error;
wire [47:0] arp_response_mac;

assign desc_axis_tready = desc_axis_tready_reg;
assign configuration_done = configuration_done_reg;

always @(posedge clk) begin
    if (rst) begin
        desc_axis_tready_reg <= 1'b0;
        src_ip_addr_reg <= 'b0;
        dst_ip_addr_reg <= 'b0;
        src_mac_addr_reg <= 'b0;
        arp_request_start <= 'b0;
    end else if(desc_axis_tready & desc_axis_tvalid)begin
        desc_axis_tready_reg <= 'b0;
        arp_request_start <= 'b0;
    end else if (desc_axis_tvalid) begin
        desc_axis_tready_reg <= 1'b1;
        arp_request_start <= 1'b1;
        src_ip_addr_reg <= src_ip_addr;
        dst_ip_addr_reg <= dst_ip_addr;
        src_mac_addr_reg <= src_mac_addr;
    end
end

always @(posedge clk) begin
    if (rst) begin
        arp_request_valid <= 1'b0;
        arp_request_ip <= 'b0;
    end else if (arp_request_valid && arp_request_ready) begin
        arp_request_valid <= 1'b0;
        arp_request_ip <= 'b0;
    end else if (arp_request_start) begin
        arp_request_valid <= 1'b1;
        arp_request_ip <= dst_ip_addr;
    end
end

always @(posedge clk) begin
    if (rst) begin
        configuration_done_reg <= 1'b0;
    end else if(desc_axis_tready & desc_axis_tvalid)begin
        configuration_done_reg <= 1'b0;
    end else if (arp_response_valid && arp_response_ready) begin
        arp_response_ready <= 'b0;
        // a failed resolution (retries exhausted) must not report the
        // configuration as done — the UDP path has no valid target MAC
        if (!arp_response_error)
            configuration_done_reg <= 1'b1;
    end else if (arp_response_valid) begin
        arp_response_ready <= 1'b1;
    end
end

// arp_v1 holds arp_response_mac stable through the valid/ready handshake;
// capture it on the successful handshake and retain it until the next
// successful resolution — it is the destination MAC descriptor for the
// UDP/ICMP transmit path (eth_arb_mux_inst).
always @(posedge clk) begin
    if (rst) begin
        arp_resolved_mac_reg <= 'b0;
    end else if (arp_response_valid && arp_response_ready && !arp_response_error) begin
        arp_resolved_mac_reg <= arp_response_mac;
    end
end

/***************************************************************
 * ARP (arp_layer)
 *
 * arp_layer works on plain AXI streams that carry only the 28 byte ARP
 * packet; the ethernet header is stripped by eth_axis_rx_v1 on receive
 * and added by eth_axis_tx_v1 on transmit.  On the receive side the
 * traffic is split by ethertype after the ethernet header is removed
 * (see the demux below eth_axis_rx_inst): 0x0806 goes to arp_layer,
 * everything else goes to the IP receive path.  On the transmit side
 * the ARP packet enters the TX arbiter (eth_arb_mux_inst_ip) next to
 * the IP frames.
 *
 * The ARP request/response interface is not used yet, so the module
 * only learns from incoming ARP traffic and auto-replies to ARP
 * requests for local_ip.
 **************************************************************/
wire [47:0] eth_rx_dest_mac;
wire [47:0] eth_rx_src_mac;
wire [15:0] eth_rx_type;

wire [63:0] frame2arp_rx_axis_tdata;
wire [7:0]  frame2arp_rx_axis_tkeep;
wire        frame2arp_rx_axis_tvalid;
wire        frame2arp_rx_axis_tlast;
wire        frame2arp_rx_axis_tready;
wire        frame2arp_rx_axis_tuser;

wire [63:0] arp_tx_axis_tdata;
wire [7:0]  arp_tx_axis_tkeep;
wire        arp_tx_axis_tvalid;
wire        arp_tx_axis_tlast;
wire        arp_tx_axis_tready;
wire        arp_tx_axis_tuser;

wire [63:0] udp2ip_tx_axis_tdata;
wire [7:0]  udp2ip_tx_axis_tkeep;
wire        udp2ip_tx_axis_tvalid;
wire        udp2ip_tx_axis_tlast;
wire        udp2ip_tx_axis_tready;
wire        udp2ip_tx_axis_tuser;

(* MARK_DEBUG="true" *)wire [63:0] icmp2ip_tx_axis_tdata;
(* MARK_DEBUG="true" *)wire [7:0]  icmp2ip_tx_axis_tkeep;
(* MARK_DEBUG="true" *)wire        icmp2ip_tx_axis_tvalid;
(* MARK_DEBUG="true" *)wire        icmp2ip_tx_axis_tlast;
(* MARK_DEBUG="true" *)wire        icmp2ip_tx_axis_tready;
//wire        icmp2ip_tx_axis_tuser;

wire [63:0] ip_tx_axis_tdata;
wire [7:0]  ip_tx_axis_tkeep;
wire        ip_tx_axis_tvalid;
wire        ip_tx_axis_tlast;
wire        ip_tx_axis_tready;
wire        ip_tx_axis_tuser;

wire [63:0] frame_tx_axis_tdata;
wire [7:0]  frame_tx_axis_tkeep;
wire        frame_tx_axis_tvalid;
wire        frame_tx_axis_tlast;
wire        frame_tx_axis_tready;
//wire        frame_tx_axis_tuser;

wire [63:0] frame2mac_tx_axis_tdata;
wire [7:0]  frame2mac_tx_axis_tkeep;
wire        frame2mac_tx_axis_tvalid;
wire        frame2mac_tx_axis_tlast;
wire        frame2mac_tx_axis_tready;
wire        frame2mac_tx_axis_tuser;

wire [47:0] m_eth_dest_mac;
wire [47:0] m_eth_src_mac ;
wire [15:0] m_eth_type    ;
wire [47:0] eth_dest_mac  ;
wire [47:0] eth_src_mac   ;
wire [15:0] eth_type      ;


/***************************************************************
 * ARP TX ethernet header derivation
 *
 * eth_arb_mux_inst_ip samples the header descriptor of its ARP input
 * port in the cycle the first payload beat (HTYPE..OPER) is accepted.
 * The destination MAC is derived from the ARP packet itself:
 *   - OPER is in beat 0 (bytes 6-7, lanes 6-7), so requests are
 *     recognised combinationally and routed to the broadcast address
 *     (an ARP request is sent precisely because the target MAC is
 *     unknown);
 *   - a reply is routed to the requester whose MAC was latched while
 *     snooping the last incoming (IN)ARP request that arp_v1 answers.
 * arp_response_mac / arp_resolved_mac_reg are NOT usable here: they
 * hold the MAC resolved for the UDP destination, which is unrelated
 * to both cases.
 **************************************************************/
wire arp_rx_beat = frame2arp_rx_axis_tvalid && frame2arp_rx_axis_tready;

reg  [2:0]  arp_rx_ptr_reg = 3'd0;
reg  [15:0] arp_rx_htype_reg = 16'd0;
reg  [15:0] arp_rx_ptype_reg = 16'd0;
reg  [7:0]  arp_rx_hlen_reg = 8'd0;
reg  [7:0]  arp_rx_plen_reg = 8'd0;
reg  [15:0] arp_rx_oper_reg = 16'd0;
reg  [47:0] arp_rx_sha_reg = 48'd0;
reg  [47:0] arp_rx_tha_reg = 48'd0;
reg  [47:0] arp_reply_dest_mac_reg = 48'hffffffffffff;
reg         arp_rx_req_match_reg = 1'b0;         // (IN)ARP request: Ethernet/IPv4, 6/4, oper=request
reg         arp_rx_reply_tha_match_reg = 1'b0;   // ARP reply whose THA matches local_mac
reg  [31:0] arp_rx_tpa_reg = 32'd0;              // TPA (target protocol address) latched at beat 3
reg         arp_rx_last_reg = 1'b0;              // beat 3 accepted, final decision pending

always @(posedge clk) begin
    if (rst) begin
        arp_rx_ptr_reg <= 3'd0;
        arp_rx_htype_reg <= 16'd0;
        arp_rx_ptype_reg <= 16'd0;
        arp_rx_hlen_reg <= 8'd0;
        arp_rx_plen_reg <= 8'd0;
        arp_rx_oper_reg <= 16'd0;
        arp_rx_sha_reg <= 48'd0;
        arp_rx_tha_reg <= 48'd0;
        arp_rx_req_match_reg <= 1'b0;
        arp_rx_reply_tha_match_reg <= 1'b0;
        arp_rx_tpa_reg <= 32'd0;
        arp_rx_last_reg <= 1'b0;
    end else begin
        arp_rx_last_reg <= 1'b0;
        if (arp_rx_beat) begin
            case (arp_rx_ptr_reg)
                // beat 0: HTYPE, PTYPE, HLEN, PLEN, OPER (bytes 0-7, lanes 0-7)
                3'd0: begin
                    arp_rx_htype_reg <= {frame2arp_rx_axis_tdata[7:0],  frame2arp_rx_axis_tdata[15:8]};
                    arp_rx_ptype_reg <= {frame2arp_rx_axis_tdata[23:16], frame2arp_rx_axis_tdata[31:24]};
                    arp_rx_hlen_reg  <= frame2arp_rx_axis_tdata[39:32];
                    arp_rx_plen_reg  <= frame2arp_rx_axis_tdata[47:40];
                    arp_rx_oper_reg  <= {frame2arp_rx_axis_tdata[55:48], frame2arp_rx_axis_tdata[63:56]};
                end
                // beat 1: SHA (bytes 8-13, lanes 0-5); classify the request
                // header from the beat-0 registers to keep this path short
                3'd1: begin
                    arp_rx_sha_reg <= {frame2arp_rx_axis_tdata[7:0],  frame2arp_rx_axis_tdata[15:8],
                                       frame2arp_rx_axis_tdata[23:16], frame2arp_rx_axis_tdata[31:24],
                                       frame2arp_rx_axis_tdata[39:32], frame2arp_rx_axis_tdata[47:40]};
                    arp_rx_req_match_reg <= (arp_rx_htype_reg == 16'h0001)
                                         && (arp_rx_ptype_reg == 16'h0800)
                                         && (arp_rx_hlen_reg == 8'd6)
                                         && (arp_rx_plen_reg == 8'd4)
                                         && (arp_rx_oper_reg == 16'h0001);
                end
                // beat 2: THA (bytes 18-23, lanes 2-7)
                3'd2: begin
                    arp_rx_tha_reg <= {frame2arp_rx_axis_tdata[23:16], frame2arp_rx_axis_tdata[31:24],
                                       frame2arp_rx_axis_tdata[39:32], frame2arp_rx_axis_tdata[47:40],
                                       frame2arp_rx_axis_tdata[55:48], frame2arp_rx_axis_tdata[63:56]};
                end
                // beat 3: TPA (bytes 24-27, lanes 0-3); latch the remaining
                // decision inputs so the final update is a short register path.
                // The decision fires one cycle after beat 3 regardless of
                // tlast: real NICs pad ARP frames to the 60-byte minimum, so
                // the true tlast arrives on a later (padding) beat and the
                // padding bytes would otherwise overwrite TPA before the
                // match is evaluated, leaving the reply unicast latch stale.
                3'd3: begin
                    arp_rx_tpa_reg <= {frame2arp_rx_axis_tdata[7:0],  frame2arp_rx_axis_tdata[15:8],
                                       frame2arp_rx_axis_tdata[23:16], frame2arp_rx_axis_tdata[31:24]};
                    arp_rx_reply_tha_match_reg <= (arp_rx_oper_reg == 16'h0008)
                                               && (arp_rx_tha_reg == src_mac_addr);
                    arp_rx_last_reg <= 1'b1;
                end
                // padding beats: not decision inputs; the next frame
                // re-latches the header registers from its own beat 0
                default: ;
            endcase
            arp_rx_ptr_reg <= frame2arp_rx_axis_tlast ? 3'd0 : arp_rx_ptr_reg + 3'd1;
        end
    end
end

// Final learning decision, one cycle after beat 3, from registered inputs
// only. arp_v1 answers (IN)ARP requests for local_ip/local_mac; remember the
// requester to address the auto-reply to.  The window is beat3+1, before any
// padding beat can overwrite the latched SHA, and re-arms on every frame
// (with the 3-bit beat pointer, standard 46-byte padded frames can only
// ever hit the beat-3 branch once).
always @(posedge clk) begin
    if (rst) begin
        arp_reply_dest_mac_reg <= 48'hffffffffffff;
    end else if (arp_rx_last_reg
                 && ((arp_rx_req_match_reg && (arp_rx_tpa_reg == src_ip_addr))
                     || arp_rx_reply_tha_match_reg)) begin
        arp_reply_dest_mac_reg <= arp_rx_sha_reg;
    end
end

// OPER of the outgoing ARP packet sits in beat 0 (bytes 6-7, lanes 6-7):
// request/inarp-request -> broadcast, reply/inarp-reply -> requester
wire [15:0] arp_tx_oper = {arp_tx_axis_tdata[55:48], arp_tx_axis_tdata[63:56]};

wire [47:0] arp_tx_dest_mac = (arp_tx_oper == 16'h0002 || arp_tx_oper == 16'h0009)
                              ? arp_reply_dest_mac_reg
                              : 48'hffffffffffff;



/***************************************************************
 * Ethernet Frame Receive
 *
 * This module implements the Ethernet frame reception pipeline,
 * including Ethernet frame parsing, IP packet processing, UDP
 * packet extraction, and ARP packet handling.
 *
 * The data flow is as follows:
 *   Ethernet Frame -> IP -> UDP
 *                    |
 *                    +-> ARP
 *
 **************************************************************/

wire [63:0] mac2frame_rx_axis_tdata;
wire [7:0]  mac2frame_rx_axis_tkeep;
wire        mac2frame_rx_axis_tvalid;
wire        mac2frame_rx_axis_tlast;
wire        mac2frame_rx_axis_tready;
wire        mac2frame_rx_axis_tuser;

wire [63:0] frame2ip_rx_axis_tdata;
wire [7:0]  frame2ip_rx_axis_tkeep;
wire        frame2ip_rx_axis_tvalid;
wire        frame2ip_rx_axis_tlast;
wire        frame2ip_rx_axis_tready;
wire        frame2ip_rx_axis_tuser;

wire [15:0] ip_type;

wire [63:0] ip2frame_rx_axis_tdata;
wire [7:0]  ip2frame_rx_axis_tkeep;
wire        ip2frame_rx_axis_tvalid;
wire        ip2frame_rx_axis_tlast;
wire        ip2frame_rx_axis_tready;
wire        ip2frame_rx_axis_tuser;

(* MARK_DEBUG="true" *)wire [63:0] ip2icmp_rx_axis_tdata;
(* MARK_DEBUG="true" *)wire [7:0]  ip2icmp_rx_axis_tkeep;
(* MARK_DEBUG="true" *)wire        ip2icmp_rx_axis_tvalid;
(* MARK_DEBUG="true" *)wire        ip2icmp_rx_axis_tlast;
(* MARK_DEBUG="true" *)wire        ip2icmp_rx_axis_tready;
(* MARK_DEBUG="true" *)wire        ip2icmp_rx_axis_tuser;

wire [63:0] ip2udp_rx_axis_tdata;
wire [7:0]  ip2udp_rx_axis_tkeep;
wire        ip2udp_rx_axis_tvalid;
wire        ip2udp_rx_axis_tlast;
wire        ip2udp_rx_axis_tready;
wire        ip2udp_rx_axis_tuser;

wire [31:0] recv_dst_ip_addr;
wire [31:0] recv_src_ip_addr;
wire [47:0] recv_dst_mac_addr;

//----------------------------------------------------------------
assign frame2arp_rx_axis_tdata  = (eth_rx_type == 16'h0806) ? mac2frame_rx_axis_tdata : 64'h0;
assign frame2arp_rx_axis_tkeep  = (eth_rx_type == 16'h0806) ? mac2frame_rx_axis_tkeep : 8'h0;
assign frame2arp_rx_axis_tvalid = (eth_rx_type == 16'h0806) ? mac2frame_rx_axis_tvalid : 1'b0;
assign frame2arp_rx_axis_tlast  = (eth_rx_type == 16'h0806) ? mac2frame_rx_axis_tlast : 1'b0;
assign frame2arp_rx_axis_tuser  = (eth_rx_type == 16'h0806) ? mac2frame_rx_axis_tuser : 1'b0;

assign frame2ip_rx_axis_tdata  = (eth_rx_type == 16'h0800) ? mac2frame_rx_axis_tdata : 64'h0;
assign frame2ip_rx_axis_tkeep  = (eth_rx_type == 16'h0800) ? mac2frame_rx_axis_tkeep : 8'h0;
assign frame2ip_rx_axis_tvalid = (eth_rx_type == 16'h0800) ? mac2frame_rx_axis_tvalid : 1'b0;
assign frame2ip_rx_axis_tlast  = (eth_rx_type == 16'h0800) ? mac2frame_rx_axis_tlast : 1'b0;
assign frame2ip_rx_axis_tuser  = (eth_rx_type == 16'h0800) ? mac2frame_rx_axis_tuser : 1'b0;

// Any ethertype the stack does not terminate on (IPv6, LLDP, ...) must be
// drained: holding tready low leaves the frame stuck in eth_axis_rx and
// wedges the entire receive path permanently.  The payload is simply
// discarded (the muxes below gate tvalid by ethertype).
assign mac2frame_rx_axis_tready = (eth_rx_type == 16'h0806) ? frame2arp_rx_axis_tready :
                                  (eth_rx_type == 16'h0800) ? frame2ip_rx_axis_tready :
                                  1'b1;

// IPv4 protocols other than UDP/ICMP are drained the same way: tready low
// here would wedge ip_rx and stall the whole receive path permanently.
// ICMP backpressure (icmp_rx accepts only while parsing a frame and its
// payload FIFO has room) now propagates through the demux.
assign ip2udp_rx_axis_tdata  = (ip_type == 16'h0011) ? ip2frame_rx_axis_tdata  : 64'h0;
assign ip2udp_rx_axis_tkeep  = (ip_type == 16'h0011) ? ip2frame_rx_axis_tkeep  : 8'h0 ;
assign ip2udp_rx_axis_tvalid = (ip_type == 16'h0011) ? ip2frame_rx_axis_tvalid : 1'b0 ;
assign ip2udp_rx_axis_tlast  = (ip_type == 16'h0011) ? ip2frame_rx_axis_tlast  : 1'b0 ;
assign ip2udp_rx_axis_tuser  = (ip_type == 16'h0011) ? ip2frame_rx_axis_tuser  : 1'b0 ;
assign ip2frame_rx_axis_tready = (ip_type == 16'h0011) ? ip2udp_rx_axis_tready :
                                 (ip_type == 16'h0001) ? ip2icmp_rx_axis_tready :
                                 1'b1;

assign ip2icmp_rx_axis_tdata  = (ip_type == 16'h0001) ? ip2frame_rx_axis_tdata  : 64'h0;
assign ip2icmp_rx_axis_tkeep  = (ip_type == 16'h0001) ? ip2frame_rx_axis_tkeep  : 8'h0 ;
assign ip2icmp_rx_axis_tvalid = (ip_type == 16'h0001) ? ip2frame_rx_axis_tvalid : 1'b0 ;
assign ip2icmp_rx_axis_tlast  = (ip_type == 16'h0001) ? ip2frame_rx_axis_tlast  : 1'b0 ;
assign ip2icmp_rx_axis_tuser  = (ip_type == 16'h0001) ? ip2frame_rx_axis_tuser  : 1'b0 ;


eth_axis_layer #(
    .DATA_WIDTH(64)
) eth_axis_layer_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_tdata   (mac_rx_axis_tdata),
    .s_axis_tkeep   (mac_rx_axis_tkeep),
    .s_axis_tvalid  (mac_rx_axis_tvalid),
    .s_axis_tready  (mac_rx_axis_tready),
    .s_axis_tlast   (mac_rx_axis_tlast),
    .s_axis_tuser   (mac_rx_axis_tuser),

    .m_eth_dest_mac (eth_rx_dest_mac),
    .m_eth_src_mac  (eth_rx_src_mac),
    .m_eth_type     (eth_rx_type),
    .m_eth_payload_axis_tdata (mac2frame_rx_axis_tdata),
    .m_eth_payload_axis_tkeep (mac2frame_rx_axis_tkeep),
    .m_eth_payload_axis_tvalid(mac2frame_rx_axis_tvalid),
    .m_eth_payload_axis_tready(mac2frame_rx_axis_tready),
    .m_eth_payload_axis_tlast (mac2frame_rx_axis_tlast),
    .m_eth_payload_axis_tuser (mac2frame_rx_axis_tuser),

    .rx_busy(),
    .error_header_early_termination(),

    .s_eth_dest_mac (eth_dest_mac),
    .s_eth_src_mac  (eth_src_mac),
    .s_eth_type     (eth_type),
    .s_eth_payload_axis_tdata (frame2mac_tx_axis_tdata ),
    .s_eth_payload_axis_tkeep (frame2mac_tx_axis_tkeep ),
    .s_eth_payload_axis_tvalid(frame2mac_tx_axis_tvalid),
    .s_eth_payload_axis_tready(frame2mac_tx_axis_tready),
    .s_eth_payload_axis_tlast (frame2mac_tx_axis_tlast ),
    .s_eth_payload_axis_tuser (frame2mac_tx_axis_tuser ),

    .m_axis_tdata   (mac_tx_axis_tdata ),
    .m_axis_tkeep   (mac_tx_axis_tkeep ),
    .m_axis_tvalid  (mac_tx_axis_tvalid),
    .m_axis_tready  (mac_tx_axis_tready),
    .m_axis_tlast   (mac_tx_axis_tlast ),
    .m_axis_tuser   (mac_tx_axis_tuser ),
    .tx_busy()
);

eth_arb_mux_v1 #(
    .S_COUNT     (2  ),
    .DATA_WIDTH  (64 ),
    .KEEP_ENABLE (1  ),
    .ID_ENABLE   (0  ),
    .DEST_ENABLE (0  ),
    .USER_ENABLE (1  ),
    .USER_WIDTH  (1  ),
    .ARB_TYPE_ROUND_ROBIN   (0),
    .ARB_LSB_HIGH_PRIORITY  (1)
)eth_arb_mac_inst (
    .clk(clk),
    .rst(rst),
    //---------------------- Ethernet frame inputs---------------------//
    // port 1: IP frames (ethertype 0x0800), port 0: ARP (ethertype 0x0806)
    // ARP dest/src MAC is derived from the ARP packet itself (see the
    // "ARP TX ethernet header derivation" block above)
    .s_eth_dest_mac             ({m_eth_dest_mac, arp_tx_dest_mac}),
    .s_eth_src_mac              ({m_eth_src_mac , src_mac_addr   }),
    .s_eth_type                 ({16'h0800      , 16'h0806      }),
    .s_eth_payload_axis_tdata   ({frame_tx_axis_tdata   , arp_tx_axis_tdata   }),
    .s_eth_payload_axis_tkeep   ({frame_tx_axis_tkeep   , arp_tx_axis_tkeep   }),
    .s_eth_payload_axis_tvalid  ({frame_tx_axis_tvalid  , arp_tx_axis_tvalid  }),
    .s_eth_payload_axis_tready  ({frame_tx_axis_tready  , arp_tx_axis_tready  }),
    .s_eth_payload_axis_tlast   ({frame_tx_axis_tlast   , arp_tx_axis_tlast   }),
    .s_eth_payload_axis_tuser   ({1'b0   , arp_tx_axis_tuser   }),
    .s_eth_payload_axis_tid     (0),
    .s_eth_payload_axis_tdest   (0),
    
    //--------------------- Ethernet frame output ---------------------//
    .m_eth_dest_mac             (eth_dest_mac),
    .m_eth_src_mac              (eth_src_mac),
    .m_eth_type                 (eth_type),
    .m_eth_payload_axis_tdata   (frame2mac_tx_axis_tdata   ),
    .m_eth_payload_axis_tkeep   (frame2mac_tx_axis_tkeep   ),
    .m_eth_payload_axis_tvalid  (frame2mac_tx_axis_tvalid  ),
    .m_eth_payload_axis_tready  (frame2mac_tx_axis_tready  ),
    .m_eth_payload_axis_tlast   (frame2mac_tx_axis_tlast   ),
    .m_eth_payload_axis_tuser   (frame2mac_tx_axis_tuser   ),
    .m_eth_payload_axis_tid     (),
    .m_eth_payload_axis_tdest   ()
);

arp_layer #(
    .DATA_WIDTH          (64),
    .KEEP_ENABLE         (1),
    .KEEP_WIDTH          (8),
    .CACHE_ADDR_WIDTH    (5),
    .REQUEST_RETRY_COUNT (REQUEST_RETRY_COUNT),
    .REQUEST_RETRY_INTERVAL (REQUEST_RETRY_INTERVAL),
    .REQUEST_TIMEOUT     (REQUEST_TIMEOUT)
) arp_inst (
    .clk                 (clk),
    .rst                 (rst),
    // ARP packet input (from the ethertype demux)
    .s_arp_axis_tdata    (frame2arp_rx_axis_tdata ),
    .s_arp_axis_tkeep    (frame2arp_rx_axis_tkeep ),
    .s_arp_axis_tvalid   (frame2arp_rx_axis_tvalid),
    .s_arp_axis_tready   (frame2arp_rx_axis_tready),
    .s_arp_axis_tlast    (frame2arp_rx_axis_tlast ),
    .s_arp_axis_tuser    (frame2arp_rx_axis_tuser ),
    // ARP packet output (to the TX arbiter)
    .m_arp_axis_tdata    (arp_tx_axis_tdata ),
    .m_arp_axis_tkeep    (arp_tx_axis_tkeep ),
    .m_arp_axis_tvalid   (arp_tx_axis_tvalid),
    .m_arp_axis_tready   (arp_tx_axis_tready),
    .m_arp_axis_tlast    (arp_tx_axis_tlast ),
    .m_arp_axis_tuser    (arp_tx_axis_tuser ),
    // ARP requests (not used in this stack yet)
    .arp_request_valid   (arp_request_valid ),
    .arp_request_ready   (arp_request_ready ),
    .arp_request_ip      (arp_request_ip    ),
    .arp_response_valid  (arp_response_valid),
    .arp_response_ready  (arp_response_ready),
    .arp_response_error  (arp_response_error),
    .arp_response_mac    (arp_response_mac  ),
    // Configuration
    .local_mac           (src_mac_addr),
    .local_ip            (src_ip_addr ),
    .gateway_ip          (gateway_ip_addr ),
    .subnet_mask         (subnet_mask ),
    .clear_cache         (1'b0        )
);


ip_layer #(
    .IP_LAYER_TDATA_WIDTH     (64),
    .IP_LAYER_TKEEP_WIDTH     (8 )
) ip_layer_inst(
    .clk       	(clk),
    .rst     	(rst),

    /* configuration (from the stack-level address registers) */
    .local_ip_addr        	(src_ip_addr_reg ),
    .src_ip_addr          	(src_ip_addr_reg ),
    .dst_ip_addr          	(dst_ip_addr_reg ),
    .ip_send_type         	(m_eth_type[7:0] ),

    /* IP packets from the ethertype demux (ethertype 0x0800) */
    .frame_rx_axis_tdata    (frame2ip_rx_axis_tdata ),
    .frame_rx_axis_tkeep    (frame2ip_rx_axis_tkeep ),
    .frame_rx_axis_tvalid   (frame2ip_rx_axis_tvalid),
    .frame_rx_axis_tlast    (frame2ip_rx_axis_tlast ),
    .frame_rx_axis_tuser    (frame2ip_rx_axis_tuser ),
    .frame_rx_axis_tready   (frame2ip_rx_axis_tready),

    /* transport payload + metadata to the protocol demux */
    .ip_rx_axis_tdata     	(ip2frame_rx_axis_tdata ),
    .ip_rx_axis_tkeep     	(ip2frame_rx_axis_tkeep ),
    .ip_rx_axis_tvalid    	(ip2frame_rx_axis_tvalid),
    .ip_rx_axis_tlast     	(ip2frame_rx_axis_tlast ),
    .ip_rx_axis_tuser     	(ip2frame_rx_axis_tuser ),
    .ip_rx_axis_tready   	(ip2frame_rx_axis_tready),
    .recv_src_ip_addr     	(recv_src_ip_addr),
    .recv_dst_ip_addr     	(recv_dst_ip_addr),
    .ip_type              	(ip_type),
    .ip_payload_len       	(),

    /* transport payload from the TX arbiter */
    .ip_tx_axis_tdata     	(ip_tx_axis_tdata ),
    .ip_tx_axis_tkeep     	(ip_tx_axis_tkeep ),
    .ip_tx_axis_tvalid    	(ip_tx_axis_tvalid),
    .ip_tx_axis_tlast     	(ip_tx_axis_tlast ),
    .ip_tx_axis_tready    	(ip_tx_axis_tready),

    /* complete IP packets to the ethernet TX arbiter */
    .frame_tx_axis_tdata  	(frame_tx_axis_tdata ),
    .frame_tx_axis_tkeep  	(frame_tx_axis_tkeep ),
    .frame_tx_axis_tvalid 	(frame_tx_axis_tvalid),
    .frame_tx_axis_tlast  	(frame_tx_axis_tlast ),
    .frame_tx_axis_tready 	(frame_tx_axis_tready)
);

eth_arb_mux_v1 #(
    .S_COUNT     (2  ),
    .DATA_WIDTH  (64 ),
    .KEEP_ENABLE (1  ),
    .ID_ENABLE   (0  ),
    .DEST_ENABLE (0  ),
    .USER_ENABLE (1  ),
    .USER_WIDTH  (1  ),
    .ARB_TYPE_ROUND_ROBIN   (0),
    .ARB_LSB_HIGH_PRIORITY  (1)
)
eth_arb_ip_inst (
    .clk(clk),
    .rst(rst),
    // no Ethernet header descriptor at this level (IP encapsulation
    // happens downstream in ip_tx)
    .s_eth_dest_mac             ({arp_resolved_mac_reg, arp_resolved_mac_reg}),
    .s_eth_src_mac              ({src_mac_addr,src_mac_addr}),
    .s_eth_type                 ({16'h0011,16'h0001}),
    //---------------------- Ethernet frame inputs---------------------//
    .s_eth_payload_axis_tdata   ({udp2ip_tx_axis_tdata , icmp2ip_tx_axis_tdata }),
    .s_eth_payload_axis_tkeep   ({udp2ip_tx_axis_tkeep , icmp2ip_tx_axis_tkeep }),
    .s_eth_payload_axis_tvalid  ({udp2ip_tx_axis_tvalid, icmp2ip_tx_axis_tvalid}),
    .s_eth_payload_axis_tready  ({udp2ip_tx_axis_tready, icmp2ip_tx_axis_tready}),
    .s_eth_payload_axis_tlast   ({udp2ip_tx_axis_tlast , icmp2ip_tx_axis_tlast }),
    .s_eth_payload_axis_tuser   ({1'b0 , 1'b0 }),
    .s_eth_payload_axis_tid     (0),
    .s_eth_payload_axis_tdest   (0),
    
    //--------------------- Ethernet frame output ---------------------//
    .m_eth_dest_mac             (m_eth_dest_mac),
    .m_eth_src_mac              (m_eth_src_mac),
    .m_eth_type                 (m_eth_type),
    .m_eth_payload_axis_tdata   (ip_tx_axis_tdata   ),
    .m_eth_payload_axis_tkeep   (ip_tx_axis_tkeep   ),
    .m_eth_payload_axis_tvalid  (ip_tx_axis_tvalid  ),
    .m_eth_payload_axis_tready  (ip_tx_axis_tready  ),
    .m_eth_payload_axis_tlast   (ip_tx_axis_tlast   ),
    .m_eth_payload_axis_tuser   (ip_tx_axis_tuser   ),
    .m_eth_payload_axis_tid     (),
    .m_eth_payload_axis_tdest   ()
);


icmp_layer icmp_layer_inst(
    .clk                 (clk),
    .rst                 (rst),
    .icmp_not_empty      (),

    // echo requests from the IP demux
    .icmp_rx_axis_tdata  (ip2icmp_rx_axis_tdata ),
    .icmp_rx_axis_tkeep  (ip2icmp_rx_axis_tkeep ),
    .icmp_rx_axis_tvalid (ip2icmp_rx_axis_tvalid),
    .icmp_rx_axis_tlast  (ip2icmp_rx_axis_tlast ),
    .icmp_rx_axis_tuser  (ip2icmp_rx_axis_tuser ),
    .icmp_rx_axis_tready (ip2icmp_rx_axis_tready),

    // echo replies to the IP TX arbiter
    .icmp_tx_axis_tdata  (icmp2ip_tx_axis_tdata ),
    .icmp_tx_axis_tkeep  (icmp2ip_tx_axis_tkeep ),
    .icmp_tx_axis_tvalid (icmp2ip_tx_axis_tvalid),
    .icmp_tx_axis_tlast  (icmp2ip_tx_axis_tlast ),
    .icmp_tx_axis_tready (icmp2ip_tx_axis_tready)
);

udp_layer #(
    .UDP_LAYER_TDATA_WIDTH     (64),
    .UDP_LAYER_TKEEP_WIDTH     (8 )
) udp_layer_inst(
    .clk       	(clk),
    .rst     	(rst),

    /* configuration (from the stack-level / VIO registers) */
    .src_ip_addr          	(src_ip_addr       ),
    .dst_ip_addr          	(dst_ip_addr       ),
    .udp_src_port         	(udp_src_port      ),
    .udp_dst_port         	(udp_dst_port      ),
    .configure_done       	(configuration_done),

    /* receive metadata from the IP layer */
    .recv_dst_ip_addr     	(recv_dst_ip_addr),
    .recv_src_ip_addr     	(recv_src_ip_addr),

    /* UDP datagrams from the IP protocol demux (protocol 0x11) */
    .udp_rx_axis_tdata    	(ip2udp_rx_axis_tdata ),
    .udp_rx_axis_tkeep    	(ip2udp_rx_axis_tkeep ),
    .udp_rx_axis_tvalid   	(ip2udp_rx_axis_tvalid),
    .udp_rx_axis_tlast    	(ip2udp_rx_axis_tlast ),
    .udp_rx_axis_tready   	(ip2udp_rx_axis_tready),
    .udp_rx_axis_tuser    	(ip2udp_rx_axis_tuser ),

    /* payload to the application */
    .app_rx_axis_tdata    	(app_rx_axis_tdata ),
    .app_rx_axis_tkeep    	(app_rx_axis_tkeep ),
    .app_rx_axis_tvalid   	(app_rx_axis_tvalid),
    .app_rx_axis_tlast    	(app_rx_axis_tlast ),
    .app_rx_axis_tuser    	(app_rx_axis_tuser ),
    .app_rx_axis_tready   	(app_rx_axis_tready),

    /* payload from the application */
    .app_tx_axis_tdata    	(app_tx_axis_tdata ),
    .app_tx_axis_tkeep    	(app_tx_axis_tkeep ),
    .app_tx_axis_tvalid   	(app_tx_axis_tvalid),
    .app_tx_axis_tlast    	(app_tx_axis_tlast ),
    .app_tx_axis_tready   	(app_tx_axis_tready),

    /* UDP datagrams to the IP layer (via the TX arbiter) */
    .ip_tx_axis_tdata     	(udp2ip_tx_axis_tdata ),
    .ip_tx_axis_tkeep     	(udp2ip_tx_axis_tkeep ),
    .ip_tx_axis_tvalid    	(udp2ip_tx_axis_tvalid),
    .ip_tx_axis_tlast     	(udp2ip_tx_axis_tlast ),
    .ip_tx_axis_tready    	(udp2ip_tx_axis_tready)
);


endmodule


`resetall