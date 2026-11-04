/****************************************************************************
 * @file    udp_rx.v
 * @brief   UDP receive: header parse/checksum, store-and-forward payload,
 *          AXI-Stream valid/ready backpressure on both interfaces
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.1
 * @date    2025-01-22
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

function [3:0] count_valid_bytes;
    input [7:0] keep;
    integer i;
    begin
        count_valid_bytes = 4'd0;
        for (i = 0; i < 8; i = i + 1) begin
            count_valid_bytes = count_valid_bytes + keep[i];
        end
    end
endfunction

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
reg [15:0] udp_payload_length_reg      = 16'd0;
reg [15:0] udp_payload_length_temp_reg = 16'd0;

always @(posedge clk) begin
    if (rst) begin
        udp_payload_length_reg      <= 16'd0;
        udp_payload_length_temp_reg <= 16'd0;
    end
    else if (udp_rx_axis_tvalid && udp_rx_axis_tready) begin
        if (udp_rx_axis_tlast) begin
            udp_payload_length_reg <= udp_payload_length_temp_reg + count_valid_bytes(udp_rx_axis_tkeep);
            udp_payload_length_temp_reg <= 16'd0;
        end
        else begin
            udp_payload_length_temp_reg <= udp_payload_length_temp_reg + count_valid_bytes(udp_rx_axis_tkeep);
        end
    end
end

//----------------------------------------------------------------
localparam [3:0] RECV_DES = 4'b0001;
localparam [3:0] RECV_DAT = 4'b0010;
localparam [3:0] RECV_SUC = 4'b0100;
localparam [3:0] RECV_FAI = 4'b1000;
localparam [3:0] RECV_DRP = 4'b0011;   // dst-port mismatch: drain the frame

reg [3:0] recv_next,recv_reg;

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
reg [15:0] checksum_eth_reg  = 'b0; 


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
                // (nothing is written to the payload / length FIFOs)
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
        checksum_eth_reg  <= 'b0;

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
        end

        checksum_eth4_reg <= checksum_gen(checksum_eth0_reg,checksum_eth1_reg);
        checksum_eth5_reg <= checksum_gen(checksum_eth2_reg,checksum_eth3_reg);
        checksum_eth_reg  <= ~checksum_gen(checksum_eth4_reg,checksum_eth5_reg);

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


//-------------------------------------------------------------
localparam      WIDTH               = 75    ;	
localparam      DEPTH               = 11    ;   	
localparam      FIFO_TYPE           = "fwft";
localparam      FIFO_MEMORY         = "auto";
localparam      USER_ADV_FEATURES   = "1f1f";
localparam      CASCADE_HEIGHT      = 0;
localparam      DOUT_RESET_VALUE    = "0";
localparam      ECC_MODE            = (FIFO_MEMORY == "auto") ? "no_ecc" : "en_ecc";
localparam      FIFO_MEMORY_TYPE    = FIFO_MEMORY;
localparam      FIFO_READ_LATENCY   = (FIFO_TYPE == "fwft") ? 0 : 1;
localparam      FIFO_WRITE_DEPTH    = 2**DEPTH;
localparam      FULL_RESET_VALUE    = 0;
localparam      PROG_EMPTY_THRESH   = 10;
localparam      PROG_FULL_THRESH    = 10;
localparam      RD_DATA_COUNT_WIDTH = DEPTH + 1;
localparam      READ_DATA_WIDTH     = WIDTH;
localparam      READ_MODE           = FIFO_TYPE;
localparam      SIM_ASSERT_CHK      = 1;
localparam      USE_ADV_FEATURES    = USER_ADV_FEATURES;
localparam      WAKEUP_TIME         = (FIFO_MEMORY_TYPE == "auto") ? 0 : 2;
localparam      WRITE_DATA_WIDTH    = WIDTH;  
localparam      WR_DATA_COUNT_WIDTH = DEPTH + 1;
localparam DLY_LENGTH = 4;

// snapshot of per-frame lengths, aligned with the payload FIFO write via the
// same DLY_LENGTH-stage delay line used for the data path
wire frame_end = (recv_reg == RECV_DAT) && udp_rx_axis_tvalid && udp_rx_axis_tready && udp_rx_axis_tlast;
wire [15:0] frame_total_wire = udp_payload_length_temp_reg + count_valid_bytes(udp_rx_axis_tkeep);

reg [15:0] frame_payload_len;  // real UDP payload bytes (= UDP length field - 8)
reg [15:0] frame_total_len;    // bytes written to payload FIFO (payload + padding)

always @(posedge clk) begin
    if (rst) begin
        frame_payload_len <= 16'd0;
        frame_total_len   <= 16'd0;
    end else if (frame_end) begin
        frame_payload_len <= (recv_length_reg > 16'd8) ? (recv_length_reg - 16'd8) : 16'd0;
        frame_total_len   <= (frame_total_wire > 16'd8) ? (frame_total_wire - 16'd8) : 16'd0;
    end
end


reg     [63:0]  app_tdata_dly[0:DLY_LENGTH - 1];
reg     [7:0]   app_tkeep_dly[0:DLY_LENGTH - 1];
reg     [DLY_LENGTH - 1 : 0]  app_tvalid_dly;
reg     [DLY_LENGTH - 1 : 0]  app_tlast_dly;
reg     [DLY_LENGTH - 1 : 0]  app_tuser_dly;
reg     [15:0]  frame_payload_len_dly[0:DLY_LENGTH - 1];
reg     [15:0]  frame_total_len_dly[0:DLY_LENGTH - 1];

reg [63:0] app_rx_axis_tdata_init;
reg [7:0]  app_rx_axis_tkeep_init;
reg app_rx_axis_tuser_init;
reg app_rx_axis_tvalid_init;
wire app_rx_axis_tready_init;
reg app_rx_axis_tlast_init;


genvar i;
generate
    for (i = 0; i < DLY_LENGTH ; i = i + 1) begin:delay_line
        always @(posedge clk) begin
            if (rst) begin
                app_tdata_dly[i]    <=  0;
                app_tkeep_dly[i]    <=  0;
                app_tvalid_dly[i]   <=  0;
                app_tlast_dly[i]    <=  0;
                app_tuser_dly[i]    <=  0;
                frame_payload_len_dly[i] <= 16'd0;
                frame_total_len_dly[i]   <= 16'd0;
            end
            else begin
                app_tdata_dly[i]    <=  (i == 0) ? app_tdata_reg : app_tdata_dly[i-1];
                app_tkeep_dly[i]    <=  (i == 0) ? app_tkeep_reg : app_tkeep_dly[i-1];
                app_tvalid_dly[i]   <=  (i == 0) ? app_tvalid_reg: app_tvalid_dly[i-1];
                app_tlast_dly[i]    <=  (i == 0) ? app_tlast_reg : app_tlast_dly[i-1];
                frame_payload_len_dly[i] <= (i == 0) ? frame_payload_len : frame_payload_len_dly[i-1];
                frame_total_len_dly[i]   <= (i == 0) ? frame_total_len   : frame_total_len_dly[i-1];
                if(i == 0)begin
                    app_tuser_dly[i] <= app_tuser_reg;
                end
                else if(i == DLY_LENGTH - 1)begin
                    if(checksum_eth_reg == 16'h0000)begin
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

// one length entry per frame, written in lock-step with the final payload word
wire udp_length_wren;
assign udp_length_wren = app_tvalid_dly[DLY_LENGTH-1] && app_tlast_dly[DLY_LENGTH-1];

reg   udp_payload_fifo_rden = 0;
wire  udp_payload_alful,udp_payload_empty;
wire [63:0] udp_payload_data;
wire [7:0]  udp_payload_keep;
wire        udp_payload_last;
wire        udp_payload_valid;
wire        udp_payload_user;

xpm_fifo_sync #(
      .CASCADE_HEIGHT       (CASCADE_HEIGHT      ),       
      .DOUT_RESET_VALUE     (DOUT_RESET_VALUE    ),    
      .ECC_MODE             (ECC_MODE            ),     
      .FIFO_MEMORY_TYPE     (FIFO_MEMORY_TYPE    ),
      .FIFO_READ_LATENCY    (FIFO_READ_LATENCY   ),   
      .FIFO_WRITE_DEPTH     (FIFO_WRITE_DEPTH    ),  
      .FULL_RESET_VALUE     (FULL_RESET_VALUE    ),     
      .PROG_EMPTY_THRESH    (PROG_EMPTY_THRESH   ),   
      .PROG_FULL_THRESH     (PROG_FULL_THRESH    ),   
      .RD_DATA_COUNT_WIDTH  (RD_DATA_COUNT_WIDTH ),  
      .READ_DATA_WIDTH      (READ_DATA_WIDTH     ),   
      .READ_MODE            (READ_MODE           ),        
      .SIM_ASSERT_CHK       (SIM_ASSERT_CHK      ),        
      .USE_ADV_FEATURES     (USE_ADV_FEATURES    ), 
      .WAKEUP_TIME          (WAKEUP_TIME         ),          
      .WRITE_DATA_WIDTH     (WRITE_DATA_WIDTH    ),     
      .WR_DATA_COUNT_WIDTH  (WR_DATA_COUNT_WIDTH )    
)udp_payload_fifo (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      .almost_full          (udp_payload_alful),   
      .dout                 ({ udp_payload_last,
                                udp_payload_valid,
                                udp_payload_user,
                                udp_payload_keep,
                                udp_payload_data}),       
      .empty                (udp_payload_empty),                 
      .din                  ({app_tlast_dly[DLY_LENGTH-1],
                              app_tvalid_dly[DLY_LENGTH-1],
                              app_tuser_dly[DLY_LENGTH-1],
                              app_tkeep_dly[DLY_LENGTH-1],
                              app_tdata_dly[DLY_LENGTH-1]}),              
      .rd_en                (udp_payload_fifo_rden),               
      .rst                  (rst),                  
      .wr_clk               (clk),              
      .wr_en                (app_tvalid_dly[DLY_LENGTH-1])           
);

wire [15:0] udp_payload_len;  // real UDP payload bytes to output (= UDP length field - 8)
wire [15:0] udp_frame_len;    // bytes in payload FIFO for this frame (payload + padding)
wire udp_recv_tuser;
wire udp_length_alful, udp_length_empty;
reg udp_length_rden = 0;
xpm_fifo_sync #(
      .CASCADE_HEIGHT       (CASCADE_HEIGHT      ),       
      .DOUT_RESET_VALUE     (DOUT_RESET_VALUE    ),    
      .ECC_MODE             (ECC_MODE            ),     
      .FIFO_MEMORY_TYPE     (FIFO_MEMORY_TYPE    ),
      .FIFO_READ_LATENCY    (1),   
      .FIFO_WRITE_DEPTH     (FIFO_WRITE_DEPTH    ),  
      .FULL_RESET_VALUE     (FULL_RESET_VALUE    ),     
      .PROG_EMPTY_THRESH    (PROG_EMPTY_THRESH   ),   
      .PROG_FULL_THRESH     (PROG_FULL_THRESH    ),   
      .RD_DATA_COUNT_WIDTH  (RD_DATA_COUNT_WIDTH ),  
      .READ_DATA_WIDTH      (33),   
      .READ_MODE            ("std"),        
      .SIM_ASSERT_CHK       (SIM_ASSERT_CHK      ),        
      .USE_ADV_FEATURES     (USE_ADV_FEATURES    ), 
      .WAKEUP_TIME          (WAKEUP_TIME         ),          
      .WRITE_DATA_WIDTH     (33),     
      .WR_DATA_COUNT_WIDTH  (WR_DATA_COUNT_WIDTH )    
)udp_length_fifo (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      .almost_full          (udp_length_alful),   
      .dout                 ({udp_recv_tuser, udp_frame_len, udp_payload_len}),      
      .empty                (udp_length_empty),                 
      .din                  ({app_tuser_dly[DLY_LENGTH-1],frame_total_len_dly[DLY_LENGTH-1],frame_payload_len_dly[DLY_LENGTH-1]}),              
      .rd_en                (udp_length_rden),               
      .rst                  (rst),                  
      .wr_clk               (clk),              
      .wr_en                (udp_length_wren)           
);

//-------------------------------------------------------------------------
// input backpressure: accept only while parsing header/payload and both FIFOs have room.
// A datagram being discarded for port mismatch (RECV_DRP) is drained without
// almost-full gating: nothing is written to the FIFOs while dropping.
assign udp_rx_axis_tready = (((recv_reg == RECV_DES) || (recv_reg == RECV_DAT)) && ~udp_payload_alful && ~udp_length_alful)
                         || (recv_reg == RECV_DRP);

localparam APP_TX_IDLE  = 4'b0001,
           APP_TX_WAIT  = 4'b0010,
           APP_TX_DAT   = 4'b0100,
           APP_TX_DRAIN = 4'b1000;

reg [3:0] app_tx_next, app_tx_reg;
reg [15:0] payload_remain_next, payload_remain_reg = 'b0;
reg [15:0] frame_remain_next, frame_remain_reg = 'b0;

always @ * begin
    app_tx_next = app_tx_reg;
    udp_length_rden = 1'b0;
    udp_payload_fifo_rden = 1'b0;
    payload_remain_next = payload_remain_reg;
    frame_remain_next = frame_remain_reg;

    app_rx_axis_tdata_init  = 64'd0;
    app_rx_axis_tvalid_init = 1'b0;
    app_rx_axis_tlast_init  = 1'b0;
    app_rx_axis_tuser_init  = 1'b0;
    app_rx_axis_tkeep_init  = 8'h00;

    case (app_tx_reg)
        APP_TX_IDLE : begin
            if (~udp_length_empty) begin
                udp_length_rden = 1'b1;
                app_tx_next = APP_TX_WAIT;
            end else begin
                app_tx_next = APP_TX_IDLE;
            end
        end

        APP_TX_WAIT : begin
            // udp_payload_len: real payload bytes; udp_frame_len: payload + padding bytes
            payload_remain_next = udp_payload_len;
            frame_remain_next   = udp_frame_len;
            if (udp_payload_len == 16'd0) begin
                app_tx_next = APP_TX_DRAIN;  // empty payload: only discard padding
            end else begin
                app_tx_next = APP_TX_DAT;
            end
        end

        APP_TX_DAT : begin
            if (~udp_payload_empty && app_rx_axis_tready_init) begin
                udp_payload_fifo_rden = 1'b1;
                app_rx_axis_tdata_init  = udp_payload_data;
                app_rx_axis_tvalid_init = 1'b1;

                if (payload_remain_reg >= 16'd8) begin
                    // whole word is payload
                    app_rx_axis_tkeep_init = udp_payload_keep;
                    payload_remain_next = payload_remain_reg - 16'd8;
                    frame_remain_next   = frame_remain_reg - count_valid_bytes(udp_payload_keep);

                    if (payload_remain_reg == 16'd8) begin
                        // payload ends exactly at this word boundary
                        app_rx_axis_tlast_init = 1'b1;
                        app_rx_axis_tuser_init = udp_recv_tuser;
                        app_tx_next = APP_TX_DRAIN;
                    end else if (udp_payload_last) begin
                        // truncated frame: wire ended before UDP length was consumed
                        app_rx_axis_tlast_init = 1'b1;
                        app_rx_axis_tuser_init = udp_recv_tuser;
                        frame_remain_next = 16'd0;
                        app_tx_next = APP_TX_IDLE;
                    end else begin
                        app_rx_axis_tlast_init = 1'b0;
                        app_rx_axis_tuser_init = 1'b0;
                    end
                end else begin
                    // payload ends inside this word (payload_remain_reg in 1..7)
                    app_rx_axis_tkeep_init = (8'b1 << payload_remain_reg[2:0]) - 8'b1;
                    app_rx_axis_tlast_init = 1'b1;
                    app_rx_axis_tuser_init = udp_recv_tuser;
                    payload_remain_next = 16'd0;
                    frame_remain_next   = frame_remain_reg - count_valid_bytes(udp_payload_keep);
                    app_tx_next = APP_TX_DRAIN;
                end
            end
        end

        APP_TX_DRAIN : begin
            // discard remaining padding words of this frame
            if (frame_remain_reg != 16'd0 && ~udp_payload_empty) begin
                udp_payload_fifo_rden = 1'b1;
                frame_remain_next = frame_remain_reg - count_valid_bytes(udp_payload_keep);
                app_tx_next = APP_TX_DRAIN;
            end else begin
                app_tx_next = APP_TX_IDLE;
            end
        end

        default: begin
        end
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        app_tx_reg <= APP_TX_IDLE;
        payload_remain_reg <= 'b0;
        frame_remain_reg   <= 'b0;
    end else begin
        app_tx_reg <= app_tx_next;
        payload_remain_reg <= payload_remain_next;
        frame_remain_reg   <= frame_remain_next;
    end
end

//-------------------------------------------------------------------------

localparam  OUTPUT_FIFO_ADDR_WIDTH = 9;

reg [63:0] app_rx_axis_tdata_reg = 'b0;
reg [7:0]  app_rx_axis_tkeep_reg = 'b0;
reg        app_rx_axis_tlast_reg = 'b0;
reg        app_rx_axis_tuser_reg = 'b0;
reg        app_rx_axis_tvalid_reg= 'b0;

(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [63:0] out_fifo_wdata[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [7:0]  out_fifo_wstrb[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg  out_fifo_eop[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg  out_fifo_tuser[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];

reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_wr_ptr_reg = 0;
reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_rd_ptr_reg = 0;

wire out_fifo_full = out_fifo_wr_ptr_reg == (out_fifo_rd_ptr_reg ^ {1'b1, {OUTPUT_FIFO_ADDR_WIDTH{1'b0}}});
wire out_fifo_empty = out_fifo_wr_ptr_reg == out_fifo_rd_ptr_reg;

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
