/*

Copyright (c) 2014-2020 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ARP block for IPv4, v1 (descriptor-less interface)
 *
 * Variant of arp: the ethernet header is no longer part of this block.  Both
 * the frame input and output are plain AXI4-Streams that carry only the 28
 * byte ARP packet (HTYPE .. TPA).  The ethernet header (destination MAC,
 * source MAC, ethertype) is added by the next layer (eth_axis_tx) on transmit
 * and removed by the previous layer (eth_axis_rx) on receive, so this module
 * is self contained for integration into udp_stack_top.
 *
 * The reply destination MAC is not needed here: an ARP reply's target
 * hardware address (THA) equals the requester's sender hardware address
 * (SHA), so the ethernet destination is derived downstream from the ARP
 * packet itself.  The ARP request/response interface, the configuration ports
 * and all of the ARP behaviour (cache lookup, request/retry/timeout handling,
 * auto-reply) are identical to arp.
 */
module arp_layer #
(
    // Width of AXI stream interfaces in bits
    parameter DATA_WIDTH = 8,
    // Propagate tkeep signal
    // If disabled, tkeep assumed to be 1'b1
    parameter KEEP_ENABLE = (DATA_WIDTH>8),
    // tkeep signal width (words per cycle)
    parameter KEEP_WIDTH = (DATA_WIDTH/8),
    // Log2 of ARP cache size
    parameter CACHE_ADDR_WIDTH = 9,
    // ARP request retry count
    parameter REQUEST_RETRY_COUNT = 4,
    // ARP request retry interval (in cycles)
    parameter REQUEST_RETRY_INTERVAL = 125000000*2,
    // ARP request timeout (in cycles)
    parameter REQUEST_TIMEOUT = 125000000*30
)
(
    input  wire                   clk,
    input  wire                   rst,

    /*
     * ARP packet input (28 byte ARP packet only)
     */
    input  wire [DATA_WIDTH-1:0]  s_arp_axis_tdata,
    input  wire [KEEP_WIDTH-1:0]  s_arp_axis_tkeep,
    input  wire                   s_arp_axis_tvalid,
    output wire                   s_arp_axis_tready,
    input  wire                   s_arp_axis_tlast,
    input  wire                   s_arp_axis_tuser,

    /*
     * ARP packet output (28 byte ARP packet only)
     */
    output wire [DATA_WIDTH-1:0]  m_arp_axis_tdata,
    output wire [KEEP_WIDTH-1:0]  m_arp_axis_tkeep,
    output wire                   m_arp_axis_tvalid,
    input  wire                   m_arp_axis_tready,
    output wire                   m_arp_axis_tlast,
    output wire                   m_arp_axis_tuser,

    /*
     * ARP requests
     */
    input  wire                   arp_request_valid,
    output wire                   arp_request_ready,
    input  wire [31:0]            arp_request_ip,
    output wire                   arp_response_valid,
    input  wire                   arp_response_ready,
    output wire                   arp_response_error,
    output wire [47:0]            arp_response_mac,

    /*
     * Configuration
     */
    input  wire [47:0]            local_mac,
    input  wire [31:0]            local_ip,
    input  wire [31:0]            gateway_ip,
    input  wire [31:0]            subnet_mask,
    input  wire                   clear_cache
);

localparam [15:0]
    ARP_OPER_ARP_REQUEST = 16'h0001,
    ARP_OPER_ARP_REPLY = 16'h0002,
    ARP_OPER_INARP_REQUEST = 16'h0008,
    ARP_OPER_INARP_REPLY = 16'h0009;

// the ARP packet carried on the stream, 28 bytes total
localparam ARP_HDR_SIZE = 28;

localparam BYTE_LANES   = KEEP_ENABLE ? KEEP_WIDTH : 1;
localparam CYCLE_COUNT  = (ARP_HDR_SIZE+BYTE_LANES-1)/BYTE_LANES;
localparam PTR_WIDTH    = $clog2(CYCLE_COUNT);

// bus width assertions
initial begin
    if (BYTE_LANES * 8 != DATA_WIDTH) begin
        $error("Error: AXI stream interface requires byte (8-bit) granularity (instance %m)");
        $finish;
    end
end

/*

ARP packet layout (byte 0 first, lane 0 in the stream)

 Offset  Length  Field
 0       2       HTYPE (1)
 2       2       PTYPE (0x0800)
 4       1       HLEN (6)
 5       1       PLEN (4)
 6       2       OPER
 8       6       SHA
 14      4       SPA
 18      6       THA
 24      4       TPA

*/

/*********************************************************************
 * RX: parse the ARP packet from the AXI stream
 *********************************************************************/

reg rx_read_header_reg = 1'b1, rx_read_header_next;
reg [PTR_WIDTH-1:0] rx_ptr_reg = 0, rx_ptr_next;

reg s_arp_axis_tready_reg = 1'b0, s_arp_axis_tready_next;

reg incoming_frame_valid_reg = 1'b0, incoming_frame_valid_next;
reg [15:0] incoming_arp_htype_reg = 16'd0, incoming_arp_htype_next;
reg [15:0] incoming_arp_ptype_reg = 16'd0, incoming_arp_ptype_next;
reg [7:0]  incoming_arp_hlen_reg = 8'd0, incoming_arp_hlen_next;
reg [7:0]  incoming_arp_plen_reg = 8'd0, incoming_arp_plen_next;
reg [15:0] incoming_arp_oper_reg = 16'd0, incoming_arp_oper_next;
reg [47:0] incoming_arp_sha_reg = 48'd0, incoming_arp_sha_next;
reg [31:0] incoming_arp_spa_reg = 32'd0, incoming_arp_spa_next;
reg [47:0] incoming_arp_tha_reg = 48'd0, incoming_arp_tha_next;
reg [31:0] incoming_arp_tpa_reg = 32'd0, incoming_arp_tpa_next;

reg rx_error_header_early_termination_reg = 1'b0, rx_error_header_early_termination_next;
reg rx_error_invalid_header_reg = 1'b0, rx_error_invalid_header_next;

reg incoming_frame_ready;

wire incoming_frame_valid;
wire [15:0] incoming_arp_htype;
wire [15:0] incoming_arp_ptype;
wire [7:0]  incoming_arp_hlen;
wire [7:0]  incoming_arp_plen;
wire [15:0] incoming_arp_oper;
wire [47:0] incoming_arp_sha;
wire [31:0] incoming_arp_spa;
wire [47:0] incoming_arp_tha;
wire [31:0] incoming_arp_tpa;

assign s_arp_axis_tready = s_arp_axis_tready_reg;

always @* begin
    rx_read_header_next = rx_read_header_reg;
    rx_ptr_next = rx_ptr_reg;

    s_arp_axis_tready_next = 1'b0;

    incoming_frame_valid_next = incoming_frame_valid_reg && !incoming_frame_ready;

    incoming_arp_htype_next = incoming_arp_htype_reg;
    incoming_arp_ptype_next = incoming_arp_ptype_reg;
    incoming_arp_hlen_next = incoming_arp_hlen_reg;
    incoming_arp_plen_next = incoming_arp_plen_reg;
    incoming_arp_oper_next = incoming_arp_oper_reg;
    incoming_arp_sha_next = incoming_arp_sha_reg;
    incoming_arp_spa_next = incoming_arp_spa_reg;
    incoming_arp_tha_next = incoming_arp_tha_reg;
    incoming_arp_tpa_next = incoming_arp_tpa_reg;

    rx_error_header_early_termination_next = 1'b0;
    rx_error_invalid_header_next = 1'b0;

    if (s_arp_axis_tready_reg && s_arp_axis_tvalid) begin
        if (rx_read_header_reg) begin
            // word transfer in - store it
            rx_ptr_next = rx_ptr_reg + 1;

            `define _HEADER_FIELD_(offset, field) \
                if (rx_ptr_reg == offset/BYTE_LANES && (!KEEP_ENABLE || s_arp_axis_tkeep[offset%BYTE_LANES])) begin \
                    field = s_arp_axis_tdata[(offset%BYTE_LANES)*8 +: 8]; \
                end

            `_HEADER_FIELD_(0,  incoming_arp_htype_next[1*8 +: 8])
            `_HEADER_FIELD_(1,  incoming_arp_htype_next[0*8 +: 8])
            `_HEADER_FIELD_(2,  incoming_arp_ptype_next[1*8 +: 8])
            `_HEADER_FIELD_(3,  incoming_arp_ptype_next[0*8 +: 8])
            `_HEADER_FIELD_(4,  incoming_arp_hlen_next[0*8 +: 8])
            `_HEADER_FIELD_(5,  incoming_arp_plen_next[0*8 +: 8])
            `_HEADER_FIELD_(6,  incoming_arp_oper_next[1*8 +: 8])
            `_HEADER_FIELD_(7,  incoming_arp_oper_next[0*8 +: 8])
            `_HEADER_FIELD_(8,  incoming_arp_sha_next[5*8 +: 8])
            `_HEADER_FIELD_(9,  incoming_arp_sha_next[4*8 +: 8])
            `_HEADER_FIELD_(10, incoming_arp_sha_next[3*8 +: 8])
            `_HEADER_FIELD_(11, incoming_arp_sha_next[2*8 +: 8])
            `_HEADER_FIELD_(12, incoming_arp_sha_next[1*8 +: 8])
            `_HEADER_FIELD_(13, incoming_arp_sha_next[0*8 +: 8])
            `_HEADER_FIELD_(14, incoming_arp_spa_next[3*8 +: 8])
            `_HEADER_FIELD_(15, incoming_arp_spa_next[2*8 +: 8])
            `_HEADER_FIELD_(16, incoming_arp_spa_next[1*8 +: 8])
            `_HEADER_FIELD_(17, incoming_arp_spa_next[0*8 +: 8])
            `_HEADER_FIELD_(18, incoming_arp_tha_next[5*8 +: 8])
            `_HEADER_FIELD_(19, incoming_arp_tha_next[4*8 +: 8])
            `_HEADER_FIELD_(20, incoming_arp_tha_next[3*8 +: 8])
            `_HEADER_FIELD_(21, incoming_arp_tha_next[2*8 +: 8])
            `_HEADER_FIELD_(22, incoming_arp_tha_next[1*8 +: 8])
            `_HEADER_FIELD_(23, incoming_arp_tha_next[0*8 +: 8])
            `_HEADER_FIELD_(24, incoming_arp_tpa_next[3*8 +: 8])
            `_HEADER_FIELD_(25, incoming_arp_tpa_next[2*8 +: 8])
            `_HEADER_FIELD_(26, incoming_arp_tpa_next[1*8 +: 8])
            `_HEADER_FIELD_(27, incoming_arp_tpa_next[0*8 +: 8])

            if (rx_ptr_reg == (ARP_HDR_SIZE-1)/BYTE_LANES && (!KEEP_ENABLE || s_arp_axis_tkeep[(ARP_HDR_SIZE-1)%BYTE_LANES])) begin
                rx_read_header_next = 1'b0;
            end

            `undef _HEADER_FIELD_
        end

        if (s_arp_axis_tlast) begin
            if (rx_read_header_next) begin
                // don't have the whole header
                rx_error_header_early_termination_next = 1'b1;
            end else if (incoming_arp_hlen_next != 4'd6 || incoming_arp_plen_next != 4'd4) begin
                // lengths not valid
                rx_error_invalid_header_next = 1'b1;
            end else begin
                // otherwise, transfer tuser
                incoming_frame_valid_next = !s_arp_axis_tuser;
            end

            rx_ptr_next = 0;
            rx_read_header_next = 1'b1;
        end
    end

    s_arp_axis_tready_next = !incoming_frame_valid_next;
end

always @(posedge clk) begin
    rx_read_header_reg <= rx_read_header_next;
    rx_ptr_reg <= rx_ptr_next;

    s_arp_axis_tready_reg <= s_arp_axis_tready_next;

    incoming_frame_valid_reg <= incoming_frame_valid_next;

    incoming_arp_htype_reg <= incoming_arp_htype_next;
    incoming_arp_ptype_reg <= incoming_arp_ptype_next;
    incoming_arp_hlen_reg <= incoming_arp_hlen_next;
    incoming_arp_plen_reg <= incoming_arp_plen_next;
    incoming_arp_oper_reg <= incoming_arp_oper_next;
    incoming_arp_sha_reg <= incoming_arp_sha_next;
    incoming_arp_spa_reg <= incoming_arp_spa_next;
    incoming_arp_tha_reg <= incoming_arp_tha_next;
    incoming_arp_tpa_reg <= incoming_arp_tpa_next;

    rx_error_header_early_termination_reg <= rx_error_header_early_termination_next;
    rx_error_invalid_header_reg <= rx_error_invalid_header_next;

    if (rst) begin
        rx_read_header_reg <= 1'b1;
        rx_ptr_reg <= 0;
        s_arp_axis_tready_reg <= 1'b0;
        incoming_frame_valid_reg <= 1'b0;
        rx_error_header_early_termination_reg <= 1'b0;
        rx_error_invalid_header_reg <= 1'b0;
    end
end

assign incoming_frame_valid = incoming_frame_valid_reg;
assign incoming_arp_htype = incoming_arp_htype_reg;
assign incoming_arp_ptype = incoming_arp_ptype_reg;
assign incoming_arp_hlen = incoming_arp_hlen_reg;
assign incoming_arp_plen = incoming_arp_plen_reg;
assign incoming_arp_oper = incoming_arp_oper_reg;
assign incoming_arp_sha = incoming_arp_sha_reg;
assign incoming_arp_spa = incoming_arp_spa_reg;
assign incoming_arp_tha = incoming_arp_tha_reg;
assign incoming_arp_tpa = incoming_arp_tpa_reg;

/*********************************************************************
 * TX: serialize the ARP packet onto the AXI stream
 *********************************************************************/

reg outgoing_frame_valid_reg = 1'b0, outgoing_frame_valid_next;
wire outgoing_frame_ready;
reg [15:0] outgoing_arp_oper_reg = 16'd0, outgoing_arp_oper_next;
reg [47:0] outgoing_arp_tha_reg = 48'd0, outgoing_arp_tha_next;
reg [31:0] outgoing_arp_tpa_reg = 32'd0, outgoing_arp_tpa_next;

reg tx_send_header_reg = 1'b0, tx_send_header_next;
reg [PTR_WIDTH-1:0] tx_ptr_reg = 0, tx_ptr_next;

reg store_frame;

reg outgoing_frame_ready_reg = 1'b0, outgoing_frame_ready_next;

// stored frame fields
reg [15:0] tx_arp_htype_reg = 16'd0;
reg [15:0] tx_arp_ptype_reg = 16'd0;
reg [15:0] tx_arp_oper_reg = 16'd0;
reg [47:0] tx_arp_sha_reg = 48'd0;
reg [31:0] tx_arp_spa_reg = 32'd0;
reg [47:0] tx_arp_tha_reg = 48'd0;
reg [31:0] tx_arp_tpa_reg = 32'd0;

// internal datapath
reg [DATA_WIDTH-1:0] m_arp_axis_tdata_int;
reg [KEEP_WIDTH-1:0] m_arp_axis_tkeep_int;
reg                  m_arp_axis_tvalid_int;
reg                  m_arp_axis_tready_int_reg = 1'b0;
reg                  m_arp_axis_tlast_int;
reg                  m_arp_axis_tuser_int;
wire                 m_arp_axis_tready_int_early;

assign outgoing_frame_ready = outgoing_frame_ready_reg;

always @* begin
    tx_send_header_next = tx_send_header_reg;
    tx_ptr_next = tx_ptr_reg;

    outgoing_frame_ready_next = 1'b0;

    store_frame = 1'b0;

    m_arp_axis_tdata_int = {DATA_WIDTH{1'b0}};
    m_arp_axis_tkeep_int = {KEEP_WIDTH{1'b0}};
    m_arp_axis_tvalid_int = 1'b0;
    m_arp_axis_tlast_int = 1'b0;
    m_arp_axis_tuser_int = 1'b0;

    if (outgoing_frame_valid_reg && outgoing_frame_ready_reg) begin
        store_frame = 1'b1;
        tx_send_header_next = 1'b1;
        tx_ptr_next = 0;
    end

    if (m_arp_axis_tready_int_reg) begin
        if (tx_send_header_reg) begin
            tx_ptr_next = tx_ptr_reg + 1;

            m_arp_axis_tdata_int = {DATA_WIDTH{1'b0}};
            m_arp_axis_tkeep_int = {KEEP_WIDTH{1'b0}};
            m_arp_axis_tvalid_int = 1'b1;
            m_arp_axis_tlast_int = 1'b0;
            m_arp_axis_tuser_int = 1'b0;

            `define _HEADER_FIELD_(offset, field) \
                if (tx_ptr_reg == offset/BYTE_LANES) begin \
                    m_arp_axis_tdata_int[(offset%BYTE_LANES)*8 +: 8] = field; \
                    m_arp_axis_tkeep_int[offset%BYTE_LANES] = 1'b1; \
                end

            `_HEADER_FIELD_(0,  tx_arp_htype_reg[1*8 +: 8])
            `_HEADER_FIELD_(1,  tx_arp_htype_reg[0*8 +: 8])
            `_HEADER_FIELD_(2,  tx_arp_ptype_reg[1*8 +: 8])
            `_HEADER_FIELD_(3,  tx_arp_ptype_reg[0*8 +: 8])
            `_HEADER_FIELD_(4,  8'd6)
            `_HEADER_FIELD_(5,  8'd4)
            `_HEADER_FIELD_(6,  tx_arp_oper_reg[1*8 +: 8])
            `_HEADER_FIELD_(7,  tx_arp_oper_reg[0*8 +: 8])
            `_HEADER_FIELD_(8,  tx_arp_sha_reg[5*8 +: 8])
            `_HEADER_FIELD_(9,  tx_arp_sha_reg[4*8 +: 8])
            `_HEADER_FIELD_(10, tx_arp_sha_reg[3*8 +: 8])
            `_HEADER_FIELD_(11, tx_arp_sha_reg[2*8 +: 8])
            `_HEADER_FIELD_(12, tx_arp_sha_reg[1*8 +: 8])
            `_HEADER_FIELD_(13, tx_arp_sha_reg[0*8 +: 8])
            `_HEADER_FIELD_(14, tx_arp_spa_reg[3*8 +: 8])
            `_HEADER_FIELD_(15, tx_arp_spa_reg[2*8 +: 8])
            `_HEADER_FIELD_(16, tx_arp_spa_reg[1*8 +: 8])
            `_HEADER_FIELD_(17, tx_arp_spa_reg[0*8 +: 8])
            `_HEADER_FIELD_(18, tx_arp_tha_reg[5*8 +: 8])
            `_HEADER_FIELD_(19, tx_arp_tha_reg[4*8 +: 8])
            `_HEADER_FIELD_(20, tx_arp_tha_reg[3*8 +: 8])
            `_HEADER_FIELD_(21, tx_arp_tha_reg[2*8 +: 8])
            `_HEADER_FIELD_(22, tx_arp_tha_reg[1*8 +: 8])
            `_HEADER_FIELD_(23, tx_arp_tha_reg[0*8 +: 8])
            `_HEADER_FIELD_(24, tx_arp_tpa_reg[3*8 +: 8])
            `_HEADER_FIELD_(25, tx_arp_tpa_reg[2*8 +: 8])
            `_HEADER_FIELD_(26, tx_arp_tpa_reg[1*8 +: 8])
            `_HEADER_FIELD_(27, tx_arp_tpa_reg[0*8 +: 8])

            if (tx_ptr_reg == (ARP_HDR_SIZE-1)/BYTE_LANES) begin
                m_arp_axis_tlast_int = 1'b1;
                tx_send_header_next = 1'b0;
            end

            `undef _HEADER_FIELD_
        end
    end

    outgoing_frame_ready_next = !tx_send_header_next;
end

always @(posedge clk) begin
    tx_send_header_reg <= tx_send_header_next;
    tx_ptr_reg <= tx_ptr_next;

    outgoing_frame_ready_reg <= outgoing_frame_ready_next;

    if (store_frame) begin
        tx_arp_htype_reg <= 16'h0001;
        tx_arp_ptype_reg <= 16'h0800;
        tx_arp_oper_reg <= outgoing_arp_oper_reg;
        tx_arp_sha_reg <= local_mac;
        tx_arp_spa_reg <= local_ip;
        tx_arp_tha_reg <= outgoing_arp_tha_reg;
        tx_arp_tpa_reg <= outgoing_arp_tpa_reg;
    end

    if (rst) begin
        tx_send_header_reg <= 1'b0;
        tx_ptr_reg <= 0;
        outgoing_frame_ready_reg <= 1'b0;
    end
end

// output datapath logic
reg [DATA_WIDTH-1:0] m_arp_axis_tdata_reg = {DATA_WIDTH{1'b0}};
reg [KEEP_WIDTH-1:0] m_arp_axis_tkeep_reg = {KEEP_WIDTH{1'b0}};
reg                  m_arp_axis_tvalid_reg = 1'b0, m_arp_axis_tvalid_next;
reg                  m_arp_axis_tlast_reg = 1'b0;
reg                  m_arp_axis_tuser_reg = 1'b0;

reg [DATA_WIDTH-1:0] temp_m_arp_axis_tdata_reg = {DATA_WIDTH{1'b0}};
reg [KEEP_WIDTH-1:0] temp_m_arp_axis_tkeep_reg = {KEEP_WIDTH{1'b0}};
reg                  temp_m_arp_axis_tvalid_reg = 1'b0, temp_m_arp_axis_tvalid_next;
reg                  temp_m_arp_axis_tlast_reg = 1'b0;
reg                  temp_m_arp_axis_tuser_reg = 1'b0;

// datapath control
reg store_payload_int_to_output;
reg store_payload_int_to_temp;
reg store_payload_temp_to_output;

assign m_arp_axis_tdata = m_arp_axis_tdata_reg;
assign m_arp_axis_tkeep = KEEP_ENABLE ? m_arp_axis_tkeep_reg : {KEEP_WIDTH{1'b1}};
assign m_arp_axis_tvalid = m_arp_axis_tvalid_reg;
assign m_arp_axis_tlast = m_arp_axis_tlast_reg;
assign m_arp_axis_tuser = m_arp_axis_tuser_reg;

// enable ready input next cycle if output is ready or if both output registers are empty
assign m_arp_axis_tready_int_early = m_arp_axis_tready || (!temp_m_arp_axis_tvalid_reg && !m_arp_axis_tvalid_reg);

always @* begin
    // transfer sink ready state to source
    m_arp_axis_tvalid_next = m_arp_axis_tvalid_reg;
    temp_m_arp_axis_tvalid_next = temp_m_arp_axis_tvalid_reg;

    store_payload_int_to_output = 1'b0;
    store_payload_int_to_temp = 1'b0;
    store_payload_temp_to_output = 1'b0;

    if (m_arp_axis_tready_int_reg) begin
        // input is ready
        if (m_arp_axis_tready || !m_arp_axis_tvalid_reg) begin
            // output is ready or currently not valid, transfer data to output
            m_arp_axis_tvalid_next = m_arp_axis_tvalid_int;
            store_payload_int_to_output = 1'b1;
        end else begin
            // output is not ready, store input in temp
            temp_m_arp_axis_tvalid_next = m_arp_axis_tvalid_int;
            store_payload_int_to_temp = 1'b1;
        end
    end else if (m_arp_axis_tready) begin
        // input is not ready, but output is ready
        m_arp_axis_tvalid_next = temp_m_arp_axis_tvalid_reg;
        temp_m_arp_axis_tvalid_next = 1'b0;
        store_payload_temp_to_output = 1'b1;
    end
end

always @(posedge clk) begin
    m_arp_axis_tvalid_reg <= m_arp_axis_tvalid_next;
    m_arp_axis_tready_int_reg <= m_arp_axis_tready_int_early;
    temp_m_arp_axis_tvalid_reg <= temp_m_arp_axis_tvalid_next;

    // datapath
    if (store_payload_int_to_output) begin
        m_arp_axis_tdata_reg <= m_arp_axis_tdata_int;
        m_arp_axis_tkeep_reg <= m_arp_axis_tkeep_int;
        m_arp_axis_tlast_reg <= m_arp_axis_tlast_int;
        m_arp_axis_tuser_reg <= m_arp_axis_tuser_int;
    end else if (store_payload_temp_to_output) begin
        m_arp_axis_tdata_reg <= temp_m_arp_axis_tdata_reg;
        m_arp_axis_tkeep_reg <= temp_m_arp_axis_tkeep_reg;
        m_arp_axis_tlast_reg <= temp_m_arp_axis_tlast_reg;
        m_arp_axis_tuser_reg <= temp_m_arp_axis_tuser_reg;
    end

    if (store_payload_int_to_temp) begin
        temp_m_arp_axis_tdata_reg <= m_arp_axis_tdata_int;
        temp_m_arp_axis_tkeep_reg <= m_arp_axis_tkeep_int;
        temp_m_arp_axis_tlast_reg <= m_arp_axis_tlast_int;
        temp_m_arp_axis_tuser_reg <= m_arp_axis_tuser_int;
    end

    if (rst) begin
        m_arp_axis_tvalid_reg <= 1'b0;
        m_arp_axis_tready_int_reg <= 1'b0;
        temp_m_arp_axis_tvalid_reg <= 1'b0;
    end
end

/*********************************************************************
 * ARP cache
 *********************************************************************/

reg cache_query_request_valid_reg = 1'b0, cache_query_request_valid_next;
reg [31:0] cache_query_request_ip_reg = 32'd0, cache_query_request_ip_next;
wire cache_query_response_valid;
wire cache_query_response_error;
wire [47:0] cache_query_response_mac;

reg cache_write_request_valid_reg = 1'b0, cache_write_request_valid_next;
reg [31:0] cache_write_request_ip_reg = 32'd0, cache_write_request_ip_next;
reg [47:0] cache_write_request_mac_reg = 48'd0, cache_write_request_mac_next;

arp_cache #(
    .CACHE_ADDR_WIDTH(CACHE_ADDR_WIDTH)
)
arp_cache_inst (
    .clk(clk),
    .rst(rst),
    // Query cache
    .query_request_valid(cache_query_request_valid_reg),
    .query_request_ready(),
    .query_request_ip(cache_query_request_ip_reg),
    .query_response_valid(cache_query_response_valid),
    .query_response_ready(1'b1),
    .query_response_error(cache_query_response_error),
    .query_response_mac(cache_query_response_mac),
    // Write cache
    .write_request_valid(cache_write_request_valid_reg),
    .write_request_ready(),
    .write_request_ip(cache_write_request_ip_reg),
    .write_request_mac(cache_write_request_mac_reg),
    // Configuration
    .clear_cache(clear_cache)
);

/*********************************************************************
 * ARP request / response control (identical to arp)
 *********************************************************************/

reg arp_request_operation_reg = 1'b0, arp_request_operation_next;

reg arp_request_ready_reg = 1'b0, arp_request_ready_next;
reg [31:0] arp_request_ip_reg = 32'd0, arp_request_ip_next;

reg arp_response_valid_reg = 1'b0, arp_response_valid_next;
reg arp_response_error_reg = 1'b0, arp_response_error_next;
reg [47:0] arp_response_mac_reg = 48'd0, arp_response_mac_next;

reg [5:0] arp_request_retry_cnt_reg = 6'd0, arp_request_retry_cnt_next;
reg [35:0] arp_request_timer_reg = 36'd0, arp_request_timer_next;

assign arp_request_ready = arp_request_ready_reg;

assign arp_response_valid = arp_response_valid_reg;
assign arp_response_error = arp_response_error_reg;
assign arp_response_mac = arp_response_mac_reg;

always @* begin
    incoming_frame_ready = 1'b0;

    outgoing_frame_valid_next = outgoing_frame_valid_reg && !outgoing_frame_ready;
    outgoing_arp_oper_next = outgoing_arp_oper_reg;
    outgoing_arp_tha_next = outgoing_arp_tha_reg;
    outgoing_arp_tpa_next = outgoing_arp_tpa_reg;

    cache_query_request_valid_next = 1'b0;
    cache_query_request_ip_next = cache_query_request_ip_reg;

    cache_write_request_valid_next = 1'b0;
    cache_write_request_mac_next = cache_write_request_mac_reg;
    cache_write_request_ip_next = cache_write_request_ip_reg;

    arp_request_ready_next = 1'b0;
    arp_request_ip_next = arp_request_ip_reg;
    arp_request_operation_next = arp_request_operation_reg;
    arp_request_retry_cnt_next = arp_request_retry_cnt_reg;
    arp_request_timer_next = arp_request_timer_reg;
    arp_response_valid_next = arp_response_valid_reg && !arp_response_ready;
    // response data (mac/error) is presented together with arp_response_valid
    // and held stable through the valid/ready handshake; it is retained
    // until the next response updates it
    arp_response_error_next = arp_response_error_reg;
    arp_response_mac_next = arp_response_mac_reg;

    // manage incoming frames
    incoming_frame_ready = outgoing_frame_ready;
    if (incoming_frame_valid && incoming_frame_ready) begin
        if (incoming_arp_htype == 16'h0001 && incoming_arp_ptype == 16'h0800) begin
            // store sender addresses in cache
            cache_write_request_valid_next = 1'b1;
            cache_write_request_ip_next = incoming_arp_spa;
            cache_write_request_mac_next = incoming_arp_sha;
            if (incoming_arp_oper == ARP_OPER_ARP_REQUEST) begin
                // ARP request
                if (incoming_arp_tpa == local_ip) begin
                    // send reply frame to valid incoming request
                    outgoing_frame_valid_next = 1'b1;
                    outgoing_arp_oper_next = ARP_OPER_ARP_REPLY;
                    outgoing_arp_tha_next = incoming_arp_sha;
                    outgoing_arp_tpa_next = incoming_arp_spa;
                end
            end else if (incoming_arp_oper == ARP_OPER_INARP_REQUEST) begin
                // INARP request
                if (incoming_arp_tha == local_mac) begin
                    // send reply frame to valid incoming request
                    outgoing_frame_valid_next = 1'b1;
                    outgoing_arp_oper_next = ARP_OPER_INARP_REPLY;
                    outgoing_arp_tha_next = incoming_arp_sha;
                    outgoing_arp_tpa_next = incoming_arp_spa;
                end 
            end
        end
    end

    // manage ARP lookup requests
    if (arp_request_operation_reg) begin
        arp_request_ready_next = 1'b0;
        cache_query_request_valid_next = 1'b1;
        arp_request_timer_next = arp_request_timer_reg - 1;
        // if we got a response, it will go in the cache, so when the query succeds, we're done
        if (cache_query_response_valid && !cache_query_response_error) begin
            arp_request_operation_next = 1'b0;
            cache_query_request_valid_next = 1'b0;
            arp_response_valid_next = 1'b1;
            arp_response_error_next = 1'b0;
            arp_response_mac_next = cache_query_response_mac;
        end
        // timer timeout
        if (arp_request_timer_reg == 0) begin
            if (arp_request_retry_cnt_reg > 0) begin
                // have more retries
                // send ARP request frame
                outgoing_frame_valid_next = 1'b1;
                outgoing_arp_oper_next = ARP_OPER_ARP_REQUEST;
                outgoing_arp_tha_next = 48'h000000000000;
                outgoing_arp_tpa_next = arp_request_ip_reg;
                arp_request_retry_cnt_next = arp_request_retry_cnt_reg - 1;
                if (arp_request_retry_cnt_reg > 1) begin
                    arp_request_timer_next = REQUEST_RETRY_INTERVAL;
                end else begin
                    arp_request_timer_next = REQUEST_TIMEOUT;
                end
            end else begin
                // out of retries
                arp_request_operation_next = 1'b0;
                arp_response_valid_next = 1'b1;
                arp_response_error_next = 1'b1;
                cache_query_request_valid_next = 1'b0;
            end
        end
    end else begin
        arp_request_ready_next = !arp_response_valid_next;
        if (cache_query_request_valid_reg) begin
            cache_query_request_valid_next = 1'b1;
            if (cache_query_response_valid) begin
                if (cache_query_response_error) begin
                    arp_request_operation_next = 1'b1;
                    // send ARP request frame
                    outgoing_frame_valid_next = 1'b1;
                    outgoing_arp_oper_next = ARP_OPER_ARP_REQUEST;
                    outgoing_arp_tha_next = 48'h000000000000;
                    outgoing_arp_tpa_next = arp_request_ip_reg;
                    arp_request_retry_cnt_next = REQUEST_RETRY_COUNT-1;
                    arp_request_timer_next = REQUEST_RETRY_INTERVAL;
                end else begin
                    cache_query_request_valid_next = 1'b0;
                    arp_response_valid_next = 1'b1;
                    arp_response_error_next = 1'b0;
                    arp_response_mac_next = cache_query_response_mac;
                end
            end
        end else if (arp_request_valid && arp_request_ready) begin
            if (arp_request_ip == 32'hffffffff) begin
                // broadcast address; use broadcast MAC address
                arp_response_valid_next = 1'b1;
                arp_response_error_next = 1'b0;
                arp_response_mac_next = 48'hffffffffffff;
            end else if (((arp_request_ip ^ gateway_ip) & subnet_mask) == 0) begin
                // within subnet
                // (no bits differ between request IP and gateway IP where subnet mask is set)
                if (~(arp_request_ip | subnet_mask) == 0) begin
                    // broadcast address; use broadcast MAC address
                    // (all bits in request IP set where subnet mask is set)
                    arp_response_valid_next = 1'b1;
                    arp_response_error_next = 1'b0;
                    arp_response_mac_next = 48'hffffffffffff;
                end else begin
                    // unicast address; look up IP directly
                    cache_query_request_valid_next = 1'b1;
                    cache_query_request_ip_next = arp_request_ip;
                    arp_request_ip_next = arp_request_ip;
                end
            end else begin
                // outside of subnet, so look up gateway address
                cache_query_request_valid_next = 1'b1;
                cache_query_request_ip_next = gateway_ip;
                arp_request_ip_next = gateway_ip;
            end
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        outgoing_frame_valid_reg <= 1'b0;
        cache_query_request_valid_reg <= 1'b0;
        cache_write_request_valid_reg <= 1'b0;
        arp_request_ready_reg <= 1'b0;
        arp_request_operation_reg <= 1'b0;
        arp_request_retry_cnt_reg <= 6'd0;
        arp_request_timer_reg <= 36'd0;
        arp_response_valid_reg <= 1'b0;
    end else begin
        outgoing_frame_valid_reg <= outgoing_frame_valid_next;
        cache_query_request_valid_reg <= cache_query_request_valid_next;
        cache_write_request_valid_reg <= cache_write_request_valid_next;
        arp_request_ready_reg <= arp_request_ready_next;
        arp_request_operation_reg <= arp_request_operation_next;
        arp_request_retry_cnt_reg <= arp_request_retry_cnt_next;
        arp_request_timer_reg <= arp_request_timer_next;
        arp_response_valid_reg <= arp_response_valid_next;
    end

    cache_query_request_ip_reg <= cache_query_request_ip_next;
    outgoing_arp_oper_reg <= outgoing_arp_oper_next;
    outgoing_arp_tha_reg <= outgoing_arp_tha_next;
    outgoing_arp_tpa_reg <= outgoing_arp_tpa_next;
    cache_write_request_mac_reg <= cache_write_request_mac_next;
    cache_write_request_ip_reg <= cache_write_request_ip_next;
    arp_request_ip_reg <= arp_request_ip_next;
    arp_response_error_reg <= arp_response_error_next;
    arp_response_mac_reg <= arp_response_mac_next;
end

endmodule

`resetall
