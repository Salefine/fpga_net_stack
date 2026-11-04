/****************************************************************************
 * @file    ip_rx.v
 * @brief   IPv4 receive: header parse/check, 32-bit stream realignment,
 *          AXI-Stream valid/ready backpressure
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.2
 * @date    2025-01-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.1      |                  | propagate backpressure |
 * |               |             |                  | via output FIFO        |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.2      |                  | 1. checksum compare    |
 * |               |             |                  |    with == (not =)     |
 * |               |             |                  | 2. tkeep from tkeep    |
 * |               |             |                  |    (not tdata)         |
 * |               |             |                  | 3. drive src/dst IP +  |
 * |               |             |                  |    ip_type             |
 * |               |             |                  | 4. per-state tready +  |
 * |               |             |                  |    truncated-header     |
 * |               |             |                  |    drop                |
 * |               |             |                  | 5. correct tail keep/  |
 * |               |             |                  |    last (low/high 4B)  |
 * |               |             |                  | 6. no combinational     |
 * |               |             |                  |    latches on *_init   |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.3      |                  | 输出ip_payload_len     |
 * |               |             |                  | (=total_length-IHL*4)  |
 * |               |             |                  | 供TCP层裁剪padding     |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.4      |                  | 目的IP过滤: dst !=    |
 * |               |             |                  | local_ip 且非受限广播 |
 * |               |             |                  | (255.255.255.255) 的  |
 * |               |             |                  | 包整帧丢弃, 不进入    |
 * |               |             |                  | 输出FIFO              |
 * 
 * @copyright Copyright (c) 2026 zzhi
 * ***************************************************************************/


`resetall
`timescale 1ns / 1ps
`default_nettype none

module ip_rx(
    input   wire        clk ,
    input   wire        rst ,

    input   wire[63:0]  frame_rx_axis_tdata   ,
    input   wire[7:0]   frame_rx_axis_tkeep   ,
    input   wire        frame_rx_axis_tvalid  ,
    input   wire        frame_rx_axis_tuser   ,
    input   wire        frame_rx_axis_tlast   ,
    output  reg         frame_rx_axis_tready  ,

    output  wire[63:0]   ip_rx_axis_tdata    ,
    output  wire[7:0]    ip_rx_axis_tkeep    ,
    output  wire         ip_rx_axis_tvalid   ,
    output  wire         ip_rx_axis_tuser    ,
    output  wire         ip_rx_axis_tlast    ,
    input   wire         ip_rx_axis_tready   ,

    input   wire[31:0]  local_ip_addr       ,
    output  wire[31:0]  recv_dst_ip_addr    ,
    output  wire[31:0]  recv_src_ip_addr    , 
    output  wire[15:0]  ip_type             ,
    output  wire[15:0]  ip_payload_len      // = IP total_length - IHL*4, 供传输层裁剪以太网padding
);

//-----------------------------------------------------------------
localparam  RECV_IP_HEADER0 =   7'b0000001;
localparam  RECV_IP_HEADER1 =   7'b0000010;
localparam  RECV_IP_HEADER2 =   7'b0000100;
localparam  RECV_IP_PAYLOAD =   7'b0001000;
localparam  RECV_IP_GOOD    =   7'b0010000;
localparam  RECV_IP_FAIL    =   7'b0100000;
localparam  RECV_IP_DROP    =   7'b1000000;   // dst IP not ours: drain frame

reg [6:0] recv_ip_next, recv_ip_reg;
reg [15:0] checksum_header0_next,checksum_header0_reg = 'b0;
reg [15:0] checksum_header1_next,checksum_header1_reg = 'b0;
reg [15:0] checksum_header2_next,checksum_header2_reg = 'b0;
reg [15:0] checksum_header3_next,checksum_header3_reg = 'b0;
reg [15:0] checksum_header4_next,checksum_header4_reg = 'b0;
reg [15:0] checksum_header5_next,checksum_header5_reg = 'b0;
reg [15:0] checksum_header6_next,checksum_header6_reg = 'b0;
reg [15:0] checksum_header7_next,checksum_header7_reg = 'b0;

reg [31:0] recv_src_ip_addr_next, recv_src_ip_addr_reg = 'b0;
reg [31:0] recv_dst_ip_addr_next, recv_dst_ip_addr_reg = 'b0;
reg [15:0] ip_type_next,          ip_type_reg          = 'b0;
reg [15:0] ip_payload_len_next,   ip_payload_len_reg   = 'b0;

reg [63:0] ip_rx_axis_tdata_init;
reg [7:0]  ip_rx_axis_tkeep_init;
reg        ip_rx_axis_tlast_init;
reg        ip_rx_axis_tuser_init;
reg        ip_rx_axis_tvalid_init;

reg [63:0] ip_rx_axis_tdata_shift;
reg [7:0]  ip_rx_axis_tkeep_shift;
reg        ip_rx_axis_tlast_shift;
reg        ip_rx_axis_tuser_shift;
reg        ip_rx_axis_tvalid_shift;

//------------------------------------------------------------------
// Output FIFO pointer / status signals.  Declared here because the
// combinational state machine below needs out_fifo_full / out_fifo_empty.
//------------------------------------------------------------------
localparam  OUTPUT_FIFO_ADDR_WIDTH = 9;

reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_wr_ptr_reg = 0;
reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_rd_ptr_reg = 0;

wire out_fifo_full  = out_fifo_wr_ptr_reg == (out_fifo_rd_ptr_reg ^ {1'b1, {OUTPUT_FIFO_ADDR_WIDTH{1'b0}}});
wire out_fifo_empty = out_fifo_wr_ptr_reg == out_fifo_rd_ptr_reg;

assign recv_dst_ip_addr = recv_dst_ip_addr_reg;
assign recv_src_ip_addr = recv_src_ip_addr_reg;
assign ip_type          = ip_type_reg;
assign ip_payload_len   = ip_payload_len_reg;

function    [15:0]  checksum_gen
  (
    input       [15:0]  dataina,
    input       [15:0]  datainb
  );
  
    reg [16:0]  sum ;

  begin
    sum = dataina[15:0] + datainb[15:0];
    checksum_gen = sum[16] ? sum[15:0] + 1 : sum[15:0];
  end
  
endfunction

// Zero byte lanes not asserted in tkeep.  Keeps don't-care input lanes
// (which may be X in simulation) from ever reaching the output data bus.
function [63:0] tkeep_mask
  (
    input [63:0] d,
    input [7:0]  k
  );
    integer i;
  begin
    tkeep_mask = d;
    for (i = 0; i < 8; i = i + 1) begin
        if (!k[i]) tkeep_mask[i*8 +: 8] = 8'h00;
    end
  end
endfunction

always @ * begin 
    recv_ip_next = recv_ip_reg;
    checksum_header0_next = checksum_header0_reg;
    checksum_header1_next = checksum_header1_reg;
    checksum_header2_next = checksum_header2_reg;
    checksum_header3_next = checksum_header3_reg;
    checksum_header4_next = checksum_header4_reg;
    checksum_header5_next = checksum_header5_reg;
    checksum_header6_next = checksum_header6_reg;
    checksum_header7_next = checksum_header7_reg;

    recv_src_ip_addr_next = recv_src_ip_addr_reg;
    recv_dst_ip_addr_next = recv_dst_ip_addr_reg;
    ip_type_next          = ip_type_reg;
    ip_payload_len_next   = ip_payload_len_reg;

    frame_rx_axis_tready = 1'b0;

    ip_rx_axis_tdata_init  = 64'd0;
    ip_rx_axis_tkeep_init  = 8'd0;
    ip_rx_axis_tlast_init  = 1'b0;
    ip_rx_axis_tuser_init  = 1'b0;
    ip_rx_axis_tvalid_init = 1'b0;

    case(recv_ip_reg)
        RECV_IP_HEADER0 : begin 
            // do not start a new frame until the previous frame has been
            // fully drained, keeping ip_type / address outputs stable
            frame_rx_axis_tready = out_fifo_empty;
            if(frame_rx_axis_tvalid & frame_rx_axis_tready)begin 
                if(frame_rx_axis_tlast)begin 
                    // header shorter than one beat: drop
                    recv_ip_next = RECV_IP_HEADER0;
                end else begin 
                    recv_ip_next = RECV_IP_HEADER1;
                    checksum_header0_next = checksum_gen({frame_rx_axis_tdata[23:16],frame_rx_axis_tdata[31:24]},
                                            {frame_rx_axis_tdata[7:0],frame_rx_axis_tdata[15:8]});
                    checksum_header1_next = checksum_gen({frame_rx_axis_tdata[39:32],frame_rx_axis_tdata[47:40]},
                                            {frame_rx_axis_tdata[55:48],frame_rx_axis_tdata[63:56]});
                    // total_length = {tdata[23:16], tdata[31:24]}, IHL = tdata[3:0]
                    // IP payload 长度 = total_length - IHL*4
                    ip_payload_len_next = {frame_rx_axis_tdata[23:16],frame_rx_axis_tdata[31:24]}
                                        - {10'h0, frame_rx_axis_tdata[3:0], 2'b00};
                end
            end
        end

        RECV_IP_HEADER1 : begin 
            frame_rx_axis_tready = 1'b1;
            if(frame_rx_axis_tvalid & frame_rx_axis_tready)begin 
                if(frame_rx_axis_tlast)begin 
                    // header shorter than two beats: drop
                    recv_ip_next = RECV_IP_HEADER0;
                end else begin 
                    recv_ip_next = RECV_IP_HEADER2;
                    checksum_header2_next = checksum_gen({frame_rx_axis_tdata[23:16],frame_rx_axis_tdata[31:24]},
                                            {frame_rx_axis_tdata[7:0],frame_rx_axis_tdata[15:8]});
                    checksum_header3_next = checksum_gen({frame_rx_axis_tdata[39:32],frame_rx_axis_tdata[47:40]},
                                            {frame_rx_axis_tdata[55:48],frame_rx_axis_tdata[63:56]});
                    checksum_header4_next = checksum_gen(checksum_header0_reg, checksum_header1_reg);
                    recv_src_ip_addr_next = {frame_rx_axis_tdata[39:32],
                                             frame_rx_axis_tdata[47:40],
                                             frame_rx_axis_tdata[55:48],
                                             frame_rx_axis_tdata[63:56]};
                    ip_type_next = {8'h00, frame_rx_axis_tdata[15:8]};
                end
            end
        end

        RECV_IP_HEADER2 : begin 
            frame_rx_axis_tready = 1'b1;
            if(frame_rx_axis_tvalid & frame_rx_axis_tready)begin 
                if(frame_rx_axis_tlast)begin 
                    // 20-byte header with no usable payload: drop
                    recv_ip_next = RECV_IP_HEADER0;
                end else begin 
                    checksum_header5_next = checksum_gen({frame_rx_axis_tdata[7:0],frame_rx_axis_tdata[15:8]},
                                            {frame_rx_axis_tdata[23:16],frame_rx_axis_tdata[31:24]});  
                    checksum_header6_next = checksum_gen(checksum_gen(checksum_header2_reg,checksum_header3_reg),
                                            checksum_header4_reg);
                    recv_dst_ip_addr_next = {frame_rx_axis_tdata[7:0],
                                             frame_rx_axis_tdata[15:8],
                                             frame_rx_axis_tdata[23:16],
                                             frame_rx_axis_tdata[31:24]};
                    // destination IP filter: the frame must be addressed to
                    // us (or the limited broadcast address); anything else is
                    // drained silently so it never reaches the transport layer
                    if (recv_dst_ip_addr_next == local_ip_addr ||
                        recv_dst_ip_addr_next == 32'hffffffff) begin 
                        recv_ip_next = RECV_IP_PAYLOAD;
                    end else begin 
                        recv_ip_next = RECV_IP_DROP;
                    end
                end
            end
        end

        RECV_IP_DROP : begin 
            // consume the remaining beats of a frame addressed to another
            // host without writing anything to the output FIFO
            frame_rx_axis_tready = 1'b1;
            if(frame_rx_axis_tvalid & frame_rx_axis_tready)begin 
                if(frame_rx_axis_tlast)begin 
                    recv_ip_next = RECV_IP_HEADER0;
                end else begin 
                    recv_ip_next = RECV_IP_DROP;
                end
            end
        end

        RECV_IP_PAYLOAD : begin 
            checksum_header7_next = checksum_gen(checksum_header5_reg , checksum_header6_reg);
            frame_rx_axis_tready = ~out_fifo_full;
            if(frame_rx_axis_tvalid & frame_rx_axis_tready)begin 
                // output one beat combining the previous beat's upper half
                // and the current beat's lower half (4-byte realignment)
                ip_rx_axis_tdata_init  = tkeep_mask({frame_rx_axis_tdata[31:0] , ip_rx_axis_tdata_shift[63:32]},
                                                    {frame_rx_axis_tkeep[3:0] , ip_rx_axis_tkeep_shift[7:4]});
                ip_rx_axis_tkeep_init  = {frame_rx_axis_tkeep[3:0] , ip_rx_axis_tkeep_shift[7:4]};
                ip_rx_axis_tvalid_init = 1'b1;

                if(frame_rx_axis_tlast)begin 
                    if(|frame_rx_axis_tkeep[7:4])begin 
                        // payload tail continues into the upper 4 bytes of the
                        // last input beat: one flush beat follows
                        ip_rx_axis_tlast_init = 1'b0;
                        ip_rx_axis_tuser_init = 1'b0;
                        if(frame_rx_axis_tuser) recv_ip_next = RECV_IP_FAIL;
                        else                     recv_ip_next = RECV_IP_GOOD;
                    end
                    else begin 
                        // payload tail ends in the lower 4 bytes: final beat now
                        ip_rx_axis_tlast_init = 1'b1;
                        ip_rx_axis_tuser_init = ((checksum_header7_next == 16'hffff) && ~frame_rx_axis_tuser) ? 1'b0 : 1'b1;
                        recv_ip_next = RECV_IP_HEADER0;
                    end
                end
                else begin 
                    ip_rx_axis_tlast_init = 1'b0;
                    ip_rx_axis_tuser_init = 1'b0;
                    recv_ip_next = RECV_IP_PAYLOAD;
                end
            end
        end

        RECV_IP_GOOD : begin 
            frame_rx_axis_tready = 1'b0;
            if(~out_fifo_full)begin 
                recv_ip_next = RECV_IP_HEADER0;
                ip_rx_axis_tdata_init  = tkeep_mask({32'h0 , ip_rx_axis_tdata_shift[63:32]},
                                                    {4'h0 , ip_rx_axis_tkeep_shift[7:4]});
                ip_rx_axis_tkeep_init  = {4'h0 , ip_rx_axis_tkeep_shift[7:4]};
                ip_rx_axis_tvalid_init = 1'b1;
                ip_rx_axis_tlast_init  = 1'b1;
                ip_rx_axis_tuser_init  = (checksum_header7_reg == 16'hffff) ? 1'b0 : 1'b1;
            end
        end

        RECV_IP_FAIL : begin 
            frame_rx_axis_tready = 1'b0;
            if(~out_fifo_full)begin 
                recv_ip_next = RECV_IP_HEADER0;
                ip_rx_axis_tdata_init  = tkeep_mask({32'h0 , ip_rx_axis_tdata_shift[63:32]},
                                                    {4'h0 , ip_rx_axis_tkeep_shift[7:4]});
                ip_rx_axis_tkeep_init  = {4'h0 , ip_rx_axis_tkeep_shift[7:4]};
                ip_rx_axis_tvalid_init = 1'b1;
                ip_rx_axis_tlast_init  = 1'b1;
                ip_rx_axis_tuser_init  = 1'b1;
            end
        end

        default : begin 
            recv_ip_next = RECV_IP_HEADER0;
        end
    endcase
end

always @(posedge clk)begin 
    if(rst)begin 
        recv_ip_reg <= RECV_IP_HEADER0;

        checksum_header0_reg <= 'b0;
        checksum_header1_reg <= 'b0;
        checksum_header2_reg <= 'b0;
        checksum_header3_reg <= 'b0;
        checksum_header4_reg <= 'b0;
        checksum_header5_reg <= 'b0;
        checksum_header6_reg <= 'b0;
        checksum_header7_reg <= 'b0;

        recv_src_ip_addr_reg <= 'b0;
        recv_dst_ip_addr_reg <= 'b0;
        ip_type_reg          <= 'b0;
        ip_payload_len_reg   <= 'b0;

        ip_rx_axis_tdata_shift  <= 64'd0;
        ip_rx_axis_tkeep_shift  <= 8'd0;
        ip_rx_axis_tlast_shift  <= 1'b0;
        ip_rx_axis_tuser_shift  <= 1'b0;
        ip_rx_axis_tvalid_shift <= 1'b0;
    end
    else begin 
        if(frame_rx_axis_tvalid & frame_rx_axis_tready)begin 
            ip_rx_axis_tdata_shift <= frame_rx_axis_tdata;
            ip_rx_axis_tkeep_shift <= frame_rx_axis_tkeep;
            ip_rx_axis_tuser_shift <= frame_rx_axis_tuser;
            ip_rx_axis_tvalid_shift <= frame_rx_axis_tvalid;
            ip_rx_axis_tlast_shift <= frame_rx_axis_tlast;
        end
        recv_ip_reg <= recv_ip_next;
        checksum_header0_reg <= checksum_header0_next;
        checksum_header1_reg <= checksum_header1_next;
        checksum_header2_reg <= checksum_header2_next;
        checksum_header3_reg <= checksum_header3_next;
        checksum_header4_reg <= checksum_header4_next;
        checksum_header5_reg <= checksum_header5_next;
        checksum_header6_reg <= checksum_header6_next;
        checksum_header7_reg <= checksum_header7_next;
        recv_src_ip_addr_reg <= recv_src_ip_addr_next;
        recv_dst_ip_addr_reg <= recv_dst_ip_addr_next;
        ip_type_reg          <= ip_type_next;
        ip_payload_len_reg   <= ip_payload_len_next;
    end
end

//------------------------------------------------------------------
// Output FIFO: registered output (first-word-fall-through style),
// decouples the realignment datapath from the consumer handshake.
//------------------------------------------------------------------
reg [63:0] ip_rx_axis_tdata_reg;
reg [7:0]  ip_rx_axis_tkeep_reg;
reg        ip_rx_axis_tlast_reg;
reg        ip_rx_axis_tuser_reg;
reg        ip_rx_axis_tvalid_reg;

(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [63:0] out_fifo_wdata[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [7:0]  out_fifo_wstrb[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg        out_fifo_eop[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg        out_fifo_tuser[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];

always @(posedge clk) begin
    ip_rx_axis_tvalid_reg <= ip_rx_axis_tvalid_reg && !ip_rx_axis_tready;

    if (!out_fifo_full && ip_rx_axis_tvalid_init) begin
        out_fifo_wdata[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= ip_rx_axis_tdata_init;
        out_fifo_wstrb[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= ip_rx_axis_tkeep_init;
        out_fifo_eop[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]]   <= ip_rx_axis_tlast_init;     
        out_fifo_tuser[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= ip_rx_axis_tuser_init;
        out_fifo_wr_ptr_reg <= out_fifo_wr_ptr_reg + 1;
    end

    if (!out_fifo_empty && (!ip_rx_axis_tvalid_reg || ip_rx_axis_tready)) begin
        ip_rx_axis_tdata_reg <= out_fifo_wdata[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        ip_rx_axis_tkeep_reg <= out_fifo_wstrb[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        ip_rx_axis_tlast_reg <= out_fifo_eop[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        ip_rx_axis_tuser_reg <= out_fifo_tuser[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        ip_rx_axis_tvalid_reg <= 1'b1;
        out_fifo_rd_ptr_reg <= out_fifo_rd_ptr_reg + 1;
    end

    if (rst) begin
        out_fifo_wr_ptr_reg <= 0;
        out_fifo_rd_ptr_reg <= 0;
        ip_rx_axis_tvalid_reg <= 1'b0;
        ip_rx_axis_tdata_reg  <= 64'd0;
        ip_rx_axis_tkeep_reg  <= 8'd0;
        ip_rx_axis_tlast_reg  <= 1'b0;
        ip_rx_axis_tuser_reg  <= 1'b0;
    end
end

assign ip_rx_axis_tdata  = ip_rx_axis_tdata_reg;
assign ip_rx_axis_tkeep  = ip_rx_axis_tkeep_reg;
assign ip_rx_axis_tlast  = ip_rx_axis_tlast_reg;
assign ip_rx_axis_tvalid = ip_rx_axis_tvalid_reg;
assign ip_rx_axis_tuser  = ip_rx_axis_tuser_reg;

endmodule

`resetall