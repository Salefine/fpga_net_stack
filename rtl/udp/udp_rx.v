/****************************************************************************
 * @file    udp_rx.v
 * @brief   UDP receive: header parse/checksum, 8-byte UDP header strip,
 *          AXI-Stream valid/ready backpressure on both interfaces
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.3
 * @date    2026-11-16
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.1      |                  | 1. fix length-FIFO FWFT|
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.2      |                  | 目的端口过滤:          |
 * |               |             |                  | dst port != 本地端口   |
 * |               |             |                  | 的数据报整帧丢弃       |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.3      |                  | 1. 以太网padding由ip_rx |
 * |               |             |                  |    剔除, 本层不再裁剪, |
 * |               |             |                  |    去掉长度FIFO与裁剪  |
 * |               |             |                  |    状态机, 只保留4级   |
 * |               |             |                  |    延迟线直达输出FIFO  |
 * |               |             |                  | 2. 恢复输入反压        |
 * |               |             |                  |    udp_rx_axis_tready  |
 * |               |             |                  |    (按输出FIFO余量)    |
 * |               |             |                  | 3. UDP校验和为0(未使用)|
 * |               |             |                  |    视为校验通过        |
 * 
 * @copyright Copyright (c) 2026 zzhi
 * ***************************************************************************/

`resetall
`timescale 1ns / 1ps
`default_nettype none

module udp_rx (
    input  wire [31:0] recv_dst_ip_addr,     //destination ip address (local)
    input  wire [31:0] recv_src_ip_addr,     //source ip address (remote)
    input  wire [15:0] local_udp_port,       //本地UDP端口, 目的端口不匹配的数据报将被丢弃
    input  wire [15:0] dst_udp_port, 
          
	input  wire clk,
    input  wire rst,

	/* udp rx axis interface (from ip_rx) */		   
    input  wire [63:0]   udp_rx_axis_tdata ,
    input  wire [7:0]    udp_rx_axis_tkeep ,
    input  wire          udp_rx_axis_tvalid,		 
    input  wire          udp_rx_axis_tlast ,
    output wire          udp_rx_axis_tready,
    input  wire          udp_rx_axis_tuser,

	/* rx axis interface to application */
	output wire  [63:0]  app_rx_axis_tdata ,
    output wire  [7:0]   app_rx_axis_tkeep ,
    output wire          app_rx_axis_tvalid,		   
    output wire          app_rx_axis_tlast ,
    output wire          app_rx_axis_tuser,
    input  wire          app_rx_axis_tready
);

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

//----------------------------------------------------------------
localparam [3:0] RECV_DES = 4'b0001;
localparam [3:0] RECV_DAT = 4'b0010;
localparam [3:0] RECV_SUC = 4'b0100;
localparam [3:0] RECV_FAI = 4'b1000;
localparam [3:0] RECV_DRP = 4'b0011;   // dst-port mismatch: drain the frame

reg [3:0] recv_next,recv_reg;

//----------------------------------------------------------------
// Output FIFO status.  Declared up here because the input handshake below
// has to know how much room is left.
//----------------------------------------------------------------
localparam  OUTPUT_FIFO_ADDR_WIDTH = 9;
localparam  OUTPUT_FIFO_DEPTH      = 2**OUTPUT_FIFO_ADDR_WIDTH;
// The 4-stage output delay line is clocked on every cycle (the position at
// which the checksum error is injected into tuser depends on that fixed
// latency), so the input is stopped a few entries before the FIFO is full:
// a beat already inside the delay line can then always be retired.
localparam  OUTPUT_FIFO_SLACK      = 8;

reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_wr_ptr_reg = 0;
reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_rd_ptr_reg = 0;

wire out_fifo_full  = out_fifo_wr_ptr_reg == (out_fifo_rd_ptr_reg ^ {1'b1, {OUTPUT_FIFO_ADDR_WIDTH{1'b0}}});
wire out_fifo_empty = out_fifo_wr_ptr_reg == out_fifo_rd_ptr_reg;
wire [OUTPUT_FIFO_ADDR_WIDTH:0] out_fifo_used = out_fifo_wr_ptr_reg - out_fifo_rd_ptr_reg;
wire out_fifo_has_room = (out_fifo_used <= OUTPUT_FIFO_DEPTH - OUTPUT_FIFO_SLACK);

// Accept a beat while the UDP header / payload is being parsed, and always
// drain a datagram that is dropped for a port mismatch (nothing is written to
// the output FIFO in that case, so no room is needed).
assign udp_rx_axis_tready = (((recv_reg == RECV_DES) || (recv_reg == RECV_DAT)) && out_fifo_has_room)
                         || (recv_reg == RECV_DRP);

reg [15:0] checksum_header0_next,checksum_header0_reg = 'b0;
reg [15:0] checksum_header1_next,checksum_header1_reg = 'b0;
reg [15:0] checksum_header2_next,checksum_header2_reg = 'b0;
reg [15:0] checksum_header3_next,checksum_header3_reg = 'b0;
reg [15:0] checksum_header4_next,checksum_header4_reg = 'b0;

reg [15:0] checksum_payload0_next, checksum_payload0_reg = 'b0; 
reg [15:0] checksum_payload1_next, checksum_payload1_reg = 'b0; 
reg [15:0] checksum_payload2_next, checksum_payload2_reg = 'b0; 
reg [15:0] checksum_payload3_next, checksum_payload3_reg = 'b0; 

reg [15:0] checksum_eth0_reg = 'b0; 
reg [15:0] checksum_eth1_reg = 'b0; 
reg [15:0] checksum_eth2_reg = 'b0; 
reg [15:0] checksum_eth3_reg = 'b0; 
reg [15:0] checksum_eth4_reg = 'b0; 
reg [15:0] checksum_eth5_reg = 'b0; 
reg        checksum_absent_reg  = 1'b0;
reg        checksum_absent4_reg = 1'b0;
reg        checksum_valid_reg   = 1'b0;


reg [63:0] app_tdata_reg;
reg [7:0]  app_tkeep_reg;
reg app_tuser_reg;
reg app_tvalid_reg;
//reg app_tready_reg;
reg app_tlast_reg;

reg [15:0]  recv_dst_port,recv_dst_port_reg = 'b0;
reg [15:0]  recv_src_port,recv_src_port_reg = 'b0;
reg [15:0]  recv_length  ,recv_length_reg = 'b0;
reg [15:0]  recv_checksum,recv_checksum_reg = 'b0;

// UDP校验和为0表示发送端未计算校验和(IPv4下合法), 此时不做校验
wire udp_cksum_absent = (recv_checksum_reg == 16'h0000);

always @ * begin 
    recv_next = recv_reg;

    checksum_header0_next = checksum_header0_reg;
    checksum_header1_next = checksum_header1_reg;
    checksum_header2_next = checksum_header2_reg;
    checksum_header3_next = checksum_header3_reg;
    checksum_header4_next = checksum_header4_reg;

    checksum_payload0_next = checksum_payload0_reg;
    checksum_payload1_next = checksum_payload1_reg;
    checksum_payload2_next = checksum_payload2_reg;
    checksum_payload3_next = checksum_payload3_reg;

    recv_dst_port = recv_dst_port_reg;
    recv_src_port = recv_src_port_reg;
    recv_length = recv_length_reg;
    recv_checksum = recv_checksum_reg;

    case(recv_reg)
        RECV_DES : begin 
            if(udp_rx_axis_tready & udp_rx_axis_tvalid)begin 
                recv_dst_port = {udp_rx_axis_tdata[23:16],udp_rx_axis_tdata[31:24]};
                recv_src_port = {udp_rx_axis_tdata[7:0],udp_rx_axis_tdata[15:8]};
                recv_length   = {udp_rx_axis_tdata[39:32],udp_rx_axis_tdata[47:40]};
                recv_checksum = {udp_rx_axis_tdata[55:48],udp_rx_axis_tdata[63:56]};

                // destination-port filter: datagrams not addressed to the
                // local port are drained without entering the datapath
                // (nothing is written to the output FIFO)
                if (recv_dst_port != local_udp_port || (dst_udp_port != recv_src_port)) begin
                    recv_next = udp_rx_axis_tlast ? RECV_DES : RECV_DRP;
                end else begin
                    recv_next = udp_rx_axis_tlast ? RECV_SUC : RECV_DAT;
                end

                checksum_header0_next = checksum_gen(recv_src_ip_addr[15:0],recv_src_ip_addr[31:16]);
                checksum_header1_next = checksum_gen(recv_dst_ip_addr[15:0],recv_dst_ip_addr[31:16]);
                checksum_header2_next = checksum_gen(8'h11, recv_length);
                checksum_header3_next = checksum_gen(recv_src_port, recv_dst_port);
                checksum_header4_next = checksum_gen(recv_checksum, recv_length);

                // start a fresh per-frame payload checksum accumulator
                checksum_payload0_next = 16'd0;
                checksum_payload1_next = 16'd0;
                checksum_payload2_next = 16'd0;
                checksum_payload3_next = 16'd0;
                
            end else begin 
                recv_next = RECV_DES;
            end
        end

        RECV_DRP : begin 
            // drain the remaining beats of a datagram addressed to another
            // port; no FIFO writes, so no almost-full gating is needed
            if(udp_rx_axis_tready & udp_rx_axis_tvalid)begin 
                recv_next = udp_rx_axis_tlast ? RECV_DES : RECV_DRP;
            end else begin 
                recv_next = RECV_DRP;
            end
        end

        RECV_DAT : begin 
            if(udp_rx_axis_tready & udp_rx_axis_tvalid)begin 
                if(udp_rx_axis_tlast)begin 
                    case (udp_rx_axis_tkeep)
                        8'b00000001: begin
                            checksum_payload0_next = checksum_gen(checksum_payload0_reg, {udp_rx_axis_tdata[7:0]  , 8'h0});
                        end
                        8'b00000011: begin
                            checksum_payload0_next = checksum_gen(checksum_payload0_reg, {udp_rx_axis_tdata[7:0]  , udp_rx_axis_tdata[15:8]});
                        end
                        8'b00000111: begin
                            checksum_payload0_next = checksum_gen(checksum_payload0_reg, {udp_rx_axis_tdata[7:0]  , udp_rx_axis_tdata[15:8]});
                            checksum_payload1_next = checksum_gen(checksum_payload1_reg, {udp_rx_axis_tdata[23:16], 8'h00});
                        end
                        8'b00001111: begin
                            checksum_payload0_next = checksum_gen(checksum_payload0_reg, {udp_rx_axis_tdata[7:0]  , udp_rx_axis_tdata[15:8]});
                            checksum_payload1_next = checksum_gen(checksum_payload1_reg, {udp_rx_axis_tdata[23:16], udp_rx_axis_tdata[31:24]});
                        end
                        8'b00011111: begin
                            checksum_payload0_next = checksum_gen(checksum_payload0_reg, {udp_rx_axis_tdata[7:0]  , udp_rx_axis_tdata[15:8]});
                            checksum_payload1_next = checksum_gen(checksum_payload1_reg, {udp_rx_axis_tdata[23:16], udp_rx_axis_tdata[31:24]});
                            checksum_payload2_next = checksum_gen(checksum_payload2_reg, {udp_rx_axis_tdata[39:32], 8'h00});
                        end
                        8'b00111111: begin
                            checksum_payload0_next = checksum_gen(checksum_payload0_reg, {udp_rx_axis_tdata[7:0]  , udp_rx_axis_tdata[15:8]});
                            checksum_payload1_next = checksum_gen(checksum_payload1_reg, {udp_rx_axis_tdata[23:16], udp_rx_axis_tdata[31:24]});
                            checksum_payload2_next = checksum_gen(checksum_payload2_reg, {udp_rx_axis_tdata[39:32], udp_rx_axis_tdata[47:40]});
                        end
                        8'b01111111: begin
                            checksum_payload0_next = checksum_gen(checksum_payload0_reg, {udp_rx_axis_tdata[7:0]  , udp_rx_axis_tdata[15:8]});
                            checksum_payload1_next = checksum_gen(checksum_payload1_reg, {udp_rx_axis_tdata[23:16], udp_rx_axis_tdata[31:24]});
                            checksum_payload2_next = checksum_gen(checksum_payload2_reg, {udp_rx_axis_tdata[39:32], udp_rx_axis_tdata[47:40]});
                            checksum_payload3_next = checksum_gen(checksum_payload3_reg, {udp_rx_axis_tdata[55:48], 8'h00});
                        end
                        8'b11111111: begin
                            checksum_payload0_next = checksum_gen(checksum_payload0_reg, {udp_rx_axis_tdata[7:0]  , udp_rx_axis_tdata[15:8]});
                            checksum_payload1_next = checksum_gen(checksum_payload1_reg, {udp_rx_axis_tdata[23:16], udp_rx_axis_tdata[31:24]});
                            checksum_payload2_next = checksum_gen(checksum_payload2_reg, {udp_rx_axis_tdata[39:32], udp_rx_axis_tdata[47:40]});
                            checksum_payload3_next = checksum_gen(checksum_payload3_reg, {udp_rx_axis_tdata[55:48], udp_rx_axis_tdata[63:56]});
                        end            
                        default: begin          
                        end
                    endcase

                    recv_next = RECV_SUC;
                end
                else begin 
                    checksum_payload0_next = checksum_gen(checksum_payload0_reg, {udp_rx_axis_tdata[7:0]  , udp_rx_axis_tdata[15:8]});
                    checksum_payload1_next = checksum_gen(checksum_payload1_reg, {udp_rx_axis_tdata[23:16], udp_rx_axis_tdata[31:24]});
                    checksum_payload2_next = checksum_gen(checksum_payload2_reg, {udp_rx_axis_tdata[39:32], udp_rx_axis_tdata[47:40]});
                    checksum_payload3_next = checksum_gen(checksum_payload3_reg, {udp_rx_axis_tdata[55:48], udp_rx_axis_tdata[63:56]});
                end
            end else begin 
                recv_next = RECV_DAT;
            end
        end

        RECV_SUC : begin 
            recv_next = RECV_DES;
        end

        RECV_FAI : begin 
            recv_next = RECV_DES;
        end
        default:begin 
            recv_next = RECV_DES;
        end
    endcase
end

always @(posedge clk)begin 
    if(rst)begin 
        recv_reg <= RECV_DES;

        checksum_header0_reg <= 'b0;
        checksum_header1_reg <= 'b0;
        checksum_header2_reg <= 'b0;
        checksum_header3_reg <= 'b0;
        checksum_header4_reg <= 'b0;

        checksum_payload0_reg <= 'b0;
        checksum_payload1_reg <= 'b0;
        checksum_payload2_reg <= 'b0;
        checksum_payload3_reg <= 'b0;

        recv_dst_port_reg <= 'b0;
        recv_src_port_reg <= 'b0;
        recv_length_reg   <= 'b0;
        recv_checksum_reg <= 'b0;

        checksum_eth0_reg <= 'b0;
        checksum_eth1_reg <= 'b0;
        checksum_eth2_reg <= 'b0;
        checksum_eth3_reg <= 'b0;
        checksum_eth4_reg <= 'b0;
        checksum_eth5_reg <= 'b0;
        checksum_absent_reg  <= 1'b0;
        checksum_absent4_reg <= 1'b0;
        checksum_valid_reg   <= 1'b0;

        app_tdata_reg <= 'b0;
        app_tkeep_reg <= 'b0;
        app_tvalid_reg<= 'b0;
        app_tuser_reg <= 'b0;
        app_tlast_reg <= 'b0;

    end else begin 
        recv_reg <= recv_next;

        checksum_header0_reg <= checksum_header0_next;
        checksum_header1_reg <= checksum_header1_next;
        checksum_header2_reg <= checksum_header2_next;
        checksum_header3_reg <= checksum_header3_next;
        checksum_header4_reg <= checksum_header4_next;

        checksum_payload0_reg <= checksum_payload0_next;
        checksum_payload1_reg <= checksum_payload1_next;
        checksum_payload2_reg <= checksum_payload2_next;
        checksum_payload3_reg <= checksum_payload3_next;

        recv_dst_port_reg <= recv_dst_port;
        recv_src_port_reg <= recv_src_port;
        recv_length_reg   <= recv_length;
        recv_checksum_reg <= recv_checksum;

        if(recv_reg == RECV_SUC || recv_reg == RECV_FAI)begin 
            checksum_eth0_reg <= checksum_gen(checksum_payload0_reg,checksum_payload1_reg);
            checksum_eth1_reg <= checksum_gen(checksum_payload2_reg,checksum_payload3_reg);
            checksum_eth2_reg <= checksum_gen(checksum_header0_reg,checksum_header1_reg);
            checksum_eth3_reg <= checksum_gen(checksum_header4_reg,
                                checksum_gen(checksum_header2_reg,checksum_header3_reg));
            // 校验和为0表示发送端未计算校验和(IPv4/UDP允许), 随同一级流水寄存,
            // 与checksum_valid_reg同拍对齐
            checksum_absent_reg <= udp_cksum_absent;
        end

        checksum_eth4_reg <= checksum_gen(checksum_eth0_reg,checksum_eth1_reg);
        checksum_eth5_reg <= checksum_gen(checksum_eth2_reg,checksum_eth3_reg);
        checksum_absent4_reg <= checksum_absent_reg;
        // 1 = 本帧UDP校验和通过(或未使用), 与延迟线上的帧末拍同拍有效
        checksum_valid_reg <= (checksum_gen(checksum_eth4_reg,checksum_eth5_reg) == 16'hffff)
                           || checksum_absent4_reg;

        if(recv_reg == RECV_DAT && (udp_rx_axis_tready & udp_rx_axis_tvalid))begin 
            app_tdata_reg <= udp_rx_axis_tdata;
            app_tkeep_reg <= udp_rx_axis_tkeep;
            app_tvalid_reg<= udp_rx_axis_tvalid;
            app_tuser_reg <= udp_rx_axis_tuser;
            app_tlast_reg <= udp_rx_axis_tlast;
        end else begin
            app_tvalid_reg <= 1'b0;
        end
    end
end

//-------------------------------------------------------------------------
// 4-stage delay line aligning the payload with the checksum result, which
// needs three more cycles after the last beat has been accepted
//-------------------------------------------------------------------------
localparam DLY_LENGTH = 4;

reg     [63:0]  app_tdata_dly[0:DLY_LENGTH - 1];
reg     [7:0]   app_tkeep_dly[0:DLY_LENGTH - 1];
reg     [DLY_LENGTH - 1 : 0]  app_tvalid_dly;
reg     [DLY_LENGTH - 1 : 0]  app_tlast_dly;
reg     [DLY_LENGTH - 1 : 0]  app_tuser_dly;


wire [63:0] app_rx_axis_tdata_init;
wire [7:0]  app_rx_axis_tkeep_init;
wire app_rx_axis_tuser_init;
wire app_rx_axis_tvalid_init;
wire app_rx_axis_tready_init;
wire app_rx_axis_tlast_init;


genvar i;
generate
    for (i = 0; i < DLY_LENGTH ; i = i + 1) begin:delay_line
        always @(posedge clk) begin
            if (rst) begin
                app_tdata_dly[i]    <=  0;
                app_tkeep_dly[i]    <=  0;
                app_tvalid_dly[i]   <=  0;
                app_tlast_dly [i]    <=  0;
                app_tuser_dly [i]    <=  0;
            end
            else begin
                app_tdata_dly[i]    <=  (i == 0) ? app_tdata_reg : app_tdata_dly[i-1];
                app_tkeep_dly[i]    <=  (i == 0) ? app_tkeep_reg : app_tkeep_dly[i-1];
                app_tvalid_dly[i]   <=  (i == 0) ? app_tvalid_reg: app_tvalid_dly[i-1];
                app_tlast_dly[i]    <=  (i == 0) ? app_tlast_reg : app_tlast_dly[i-1];
                if(i == 0)begin
                    app_tuser_dly[i] <= app_tuser_reg;
                end
                else if(i == DLY_LENGTH - 1)begin
                    if(checksum_valid_reg)begin
                            app_tuser_dly[i] <= app_tuser_dly[i-1];
                        end
                    else begin 
                        if(app_tlast_dly[DLY_LENGTH-2])begin
                            app_tuser_dly[i] <= 1;
                        end  
                        else begin
                            app_tuser_dly[i] <= 0;
                        end
                    end
                end
                else begin
                    app_tuser_dly[i] <= app_tuser_dly[i-1];
                end      
            end
        end
    end
endgenerate

assign app_rx_axis_tdata_init = app_tdata_dly[DLY_LENGTH-1];
assign app_rx_axis_tkeep_init = app_tkeep_dly[DLY_LENGTH-1];
assign app_rx_axis_tvalid_init = app_tvalid_dly[DLY_LENGTH-1];
assign app_rx_axis_tlast_init = app_tlast_dly[DLY_LENGTH-1];
assign app_rx_axis_tuser_init = app_tuser_dly[DLY_LENGTH-1];

//-------------------------------------------------------------------------
// Output FIFO: registered output (first-word-fall-through style), decouples
// the delay line from the consumer handshake.  The pointers and the status
// flags are declared with the input handshake at the top of this file.
//-------------------------------------------------------------------------
reg [63:0] app_rx_axis_tdata_reg = 'b0;
reg [7:0]  app_rx_axis_tkeep_reg = 'b0;
reg        app_rx_axis_tlast_reg = 'b0;
reg        app_rx_axis_tuser_reg = 'b0;
reg        app_rx_axis_tvalid_reg= 'b0;

(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [63:0] out_fifo_wdata[OUTPUT_FIFO_DEPTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [7:0]  out_fifo_wstrb[OUTPUT_FIFO_DEPTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg  out_fifo_eop[OUTPUT_FIFO_DEPTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg  out_fifo_tuser[OUTPUT_FIFO_DEPTH-1:0];

assign app_rx_axis_tready_init = !out_fifo_full;


always @(posedge clk) begin
    app_rx_axis_tvalid_reg <= app_rx_axis_tvalid_reg && !app_rx_axis_tready;

    if (!out_fifo_full && app_rx_axis_tvalid_init) begin
        out_fifo_wdata[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= app_rx_axis_tdata_init;
        out_fifo_wstrb[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= app_rx_axis_tkeep_init;
        out_fifo_eop[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= app_rx_axis_tlast_init;     
        out_fifo_tuser[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= app_rx_axis_tuser_init;  

        out_fifo_wr_ptr_reg <= out_fifo_wr_ptr_reg + 1;
    end

    if (!out_fifo_empty && (!app_rx_axis_tvalid_reg || app_rx_axis_tready)) begin
        app_rx_axis_tdata_reg <= out_fifo_wdata[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        app_rx_axis_tkeep_reg <= out_fifo_wstrb[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        app_rx_axis_tlast_reg <= out_fifo_eop[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        app_rx_axis_tuser_reg <= out_fifo_tuser[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];

        app_rx_axis_tvalid_reg <= 1'b1;
        out_fifo_rd_ptr_reg <= out_fifo_rd_ptr_reg + 1;
    end

    if (rst) begin
        out_fifo_wr_ptr_reg <= 0;
        out_fifo_rd_ptr_reg <= 0;
        app_rx_axis_tvalid_reg <= 1'b0;
    end
end

assign app_rx_axis_tdata  = app_rx_axis_tdata_reg;
assign app_rx_axis_tkeep  = app_rx_axis_tkeep_reg;
assign app_rx_axis_tvalid = app_rx_axis_tvalid_reg;
assign app_rx_axis_tlast  = app_rx_axis_tlast_reg;
assign app_rx_axis_tuser  = app_rx_axis_tuser_reg;


endmodule

`resetall
