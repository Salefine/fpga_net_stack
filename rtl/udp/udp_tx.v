/****************************************************************************
 * @file    udp_tx.v
 * @brief  
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.0
 * @date    2026-10-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.0      |    zzhi          | udp tx                 |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2026 zzhi
 * ***************************************************************************/

`resetall
`timescale 1ns / 1ps
`default_nettype none

module udp_tx(
    input  wire [31:0]src_ip_addr,     //source ip address
    input  wire [31:0]dst_ip_addr,     //destination ip address
                                           
    input  wire [15:0]udp_src_port,    //udp source port
    input  wire [15:0]udp_dst_port,    //udp destination port

    input  wire configure_done,
          
	input  wire clk,
    input  wire rst,
	/* udp tx axis interface */		  
    input  wire [63:0]   udp_tx_axis_tdata ,
    input  wire [7:0]    udp_tx_axis_tkeep ,
    input  wire          udp_tx_axis_tvalid,		 
    input  wire          udp_tx_axis_tlast ,
    output wire          udp_tx_axis_tready,
	/* tx axis interface to ip */
	output wire [63:0]   ip_tx_axis_tdata ,
    output wire [7:0]    ip_tx_axis_tkeep ,
    output wire          ip_tx_axis_tvalid,		 
    output wire          ip_tx_axis_tlast ,
    input  wire          ip_tx_axis_tready
);


/*---------------------------------------------------------------------------------------
 * Count the number of bytes of network data packets
 *
 */

reg [15:0] udp_payload_length_reg      = 16'd0;
reg [15:0] udp_payload_length_temp_reg = 16'd0;

// 统计 tkeep 中有效字节的数量
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

always @(posedge clk) begin
    if (rst) begin
        udp_payload_length_reg      <= 16'd0;
        udp_payload_length_temp_reg <= 16'd0;
    end
    else if (udp_tx_axis_tvalid && udp_tx_axis_tready) begin
        if (udp_tx_axis_tlast) begin
            // 当前帧最后一个数据拍成功握手
            // 输出完整帧长度，并清零当前帧累计长度
            udp_payload_length_reg <= udp_payload_length_temp_reg + count_valid_bytes(udp_tx_axis_tkeep);
            udp_payload_length_temp_reg <= 16'd0;
        end
        else begin
            // 累计当前帧已传输的有效字节数
            udp_payload_length_temp_reg <= udp_payload_length_temp_reg + count_valid_bytes(udp_tx_axis_tkeep);
        end
    end
end

//------------------------------------------data cache--------------------------------------
localparam      WIDTH               = 74    ;	
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

reg udp_payload_fifo_rden_next;

reg  [15:0]  checksum_payload0  = 0;
reg  [15:0]  checksum_payload1  = 0;
reg  [15:0]  checksum_payload2  = 0;
reg  [15:0]  checksum_payload3  = 0;
reg  [15:0]  checksum_temp_load0= 0;
reg  [15:0]  checksum_temp_load1= 0;
reg  [15:0]  checksum_temp_load2= 0;
reg  [15:0]  checksum_temp_load3= 0;


wire [73:0] udp_payload_init = {udp_tx_axis_tlast,udp_tx_axis_tvalid,udp_tx_axis_tkeep,udp_tx_axis_tdata};
wire udp_payload_fifo_alfull;
wire udp_payload_fifo_empty;
wire [73:0]udp_payload_fifo_dout;
wire udp_checksum_fifo_alful;

// accept payload beats while the frame buffer has space
assign udp_tx_axis_tready = configure_done & ~udp_payload_fifo_alfull & ~udp_checksum_fifo_alful;

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
      .almost_full          (udp_payload_fifo_alfull),   
      .dout                 (udp_payload_fifo_dout),      
      .empty                (udp_payload_fifo_empty),                 
      .din                  (udp_payload_init),              
      .rd_en                (udp_payload_fifo_rden_next),               
      .rst                  (rst),                  
      .wr_clk               (clk),              
      .wr_en                (udp_tx_axis_tready & udp_tx_axis_tvalid)           
);

always @(posedge  clk) begin
    if (rst) begin
        checksum_temp_load0<= 0;
        checksum_temp_load1<= 0;
        checksum_temp_load2<= 0;
        checksum_temp_load3<= 0;
        checksum_payload0  <= 0;
        checksum_payload1  <= 0;
        checksum_payload2  <= 0;
        checksum_payload3  <= 0;
    end
    else if (udp_tx_axis_tready & udp_tx_axis_tvalid) begin
        if (udp_tx_axis_tlast) begin
            case (udp_tx_axis_tkeep)
                8'b00000001: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {udp_tx_axis_tdata[7:0], 8'h00});
                    checksum_payload1 <= checksum_temp_load1;
                    checksum_payload2 <= checksum_temp_load2;
                    checksum_payload3 <= checksum_temp_load3;
                end
                8'b00000011: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {udp_tx_axis_tdata[7:0], udp_tx_axis_tdata[15:8]});        
                    checksum_payload1 <= checksum_temp_load1;
                    checksum_payload2 <= checksum_temp_load2;
                    checksum_payload3 <= checksum_temp_load3;          
                end
                8'b00000111: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {udp_tx_axis_tdata[7:0]  , udp_tx_axis_tdata[15:8]});  
                    checksum_payload1 <= checksum_gen(checksum_temp_load1, {udp_tx_axis_tdata[23:16], 8'h0});          
                    checksum_payload2 <= checksum_temp_load2;
                    checksum_payload3 <= checksum_temp_load3;                   
                end
                8'b00001111: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {udp_tx_axis_tdata[7:0]  , udp_tx_axis_tdata[15:8]});  
                    checksum_payload1 <= checksum_gen(checksum_temp_load1, {udp_tx_axis_tdata[23:16], udp_tx_axis_tdata[31:24]}); 
                    checksum_payload2 <= checksum_temp_load2;
                    checksum_payload3 <= checksum_temp_load3;                            
                end
                8'b00011111: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {udp_tx_axis_tdata[7:0]  , udp_tx_axis_tdata[15:8]});  
                    checksum_payload1 <= checksum_gen(checksum_temp_load1, {udp_tx_axis_tdata[23:16], udp_tx_axis_tdata[31:24]}); 
                    checksum_payload2 <= checksum_gen(checksum_temp_load2, {udp_tx_axis_tdata[39:32], 8'h00});      
                    checksum_payload3 <= checksum_temp_load3;                  
                end
                8'b00111111: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {udp_tx_axis_tdata[7:0]  , udp_tx_axis_tdata[15:8]});  
                    checksum_payload1 <= checksum_gen(checksum_temp_load1, {udp_tx_axis_tdata[23:16], udp_tx_axis_tdata[31:24]}); 
                    checksum_payload2 <= checksum_gen(checksum_temp_load2, {udp_tx_axis_tdata[39:32], udp_tx_axis_tdata[47:40]});       
                    checksum_payload3 <= checksum_temp_load3;                     
                end
                8'b01111111: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {udp_tx_axis_tdata[7:0]  , udp_tx_axis_tdata[15:8]});  
                    checksum_payload1 <= checksum_gen(checksum_temp_load1, {udp_tx_axis_tdata[23:16], udp_tx_axis_tdata[31:24]}); 
                    checksum_payload2 <= checksum_gen(checksum_temp_load2, {udp_tx_axis_tdata[39:32], udp_tx_axis_tdata[47:40]}); 
                    checksum_payload3 <= checksum_gen(checksum_temp_load3, {udp_tx_axis_tdata[55:48], 8'h00});                       
                end
                8'b11111111: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {udp_tx_axis_tdata[7:0]  , udp_tx_axis_tdata[15:8]});  
                    checksum_payload1 <= checksum_gen(checksum_temp_load1, {udp_tx_axis_tdata[23:16], udp_tx_axis_tdata[31:24]}); 
                    checksum_payload2 <= checksum_gen(checksum_temp_load2, {udp_tx_axis_tdata[39:32], udp_tx_axis_tdata[47:40]});   
                    checksum_payload3 <= checksum_gen(checksum_temp_load3, {udp_tx_axis_tdata[55:48], udp_tx_axis_tdata[63:56]});                    
                end                
                default: begin
                end
            endcase
            checksum_temp_load0<= 0;
            checksum_temp_load1<= 0;
            checksum_temp_load2<= 0;
            checksum_temp_load3<= 0;
        end
        else begin
            checksum_temp_load0 <= checksum_gen(checksum_temp_load0, {udp_tx_axis_tdata[7:0]   , udp_tx_axis_tdata[15:8]});     
            checksum_temp_load1 <= checksum_gen(checksum_temp_load1, {udp_tx_axis_tdata[23:16] , udp_tx_axis_tdata[31:24]});     
            checksum_temp_load2 <= checksum_gen(checksum_temp_load2, {udp_tx_axis_tdata[39:32] , udp_tx_axis_tdata[47:40]});     
            checksum_temp_load3 <= checksum_gen(checksum_temp_load3, {udp_tx_axis_tdata[55:48] , udp_tx_axis_tdata[63:56]});     
        end
    end
end

wire [15:0] checksum_payload_fifo0;
wire [15:0] checksum_payload_fifo1;
wire [15:0] checksum_payload_fifo2;
wire [15:0] checksum_payload_fifo3;
wire [15:0] checksum_payload_length;
wire udp_checksum_fifo_empty;
reg udp_checksum_fifo_wren = 'b0;
reg udp_checksum_fifo_rden_next;
wire [4:0] udp_desc_fifo_count;   // occupancy guard: see CKS_STATE_IDLE

always @(posedge clk) begin
    if (rst) begin
        udp_checksum_fifo_wren <= 'b0;
    end
    else begin
        // one write-enable pulse per completed frame, directly registered
        // from the tlast handshake.  The previous sticky implementation
        // cleared the flag with priority over a new tlast, so a frame whose
        // tlast landed exactly one cycle after the previous frame's tlast
        // (back-to-back single-beat frames on a continuous stream) lost its
        // descriptor and permanently shifted UDP length/checksum onto the
        // following frames.
        udp_checksum_fifo_wren <= udp_tx_axis_tvalid & udp_tx_axis_tready & udp_tx_axis_tlast;
    end
end

xpm_fifo_sync #(
      .CASCADE_HEIGHT       (CASCADE_HEIGHT      ),       
      .DOUT_RESET_VALUE     (DOUT_RESET_VALUE    ),    
      .ECC_MODE             (ECC_MODE            ),     
      .FIFO_MEMORY_TYPE     (FIFO_MEMORY_TYPE    ),
      .FIFO_READ_LATENCY    (1                  ),   
      .FIFO_WRITE_DEPTH     (16), 
      .FULL_RESET_VALUE     (FULL_RESET_VALUE    ),     
      .PROG_EMPTY_THRESH    (PROG_EMPTY_THRESH   ),   
      .PROG_FULL_THRESH     (PROG_FULL_THRESH    ),   
      .RD_DATA_COUNT_WIDTH  (5 ),  
      .READ_DATA_WIDTH      (80),   
      .READ_MODE            ("std"               ),        
      .SIM_ASSERT_CHK       (SIM_ASSERT_CHK      ),        
      .USE_ADV_FEATURES     (USE_ADV_FEATURES    ), 
      .WAKEUP_TIME          (WAKEUP_TIME         ),          
      .WRITE_DATA_WIDTH     (80),     
      .WR_DATA_COUNT_WIDTH  (5 )    
)udp_checksum_fifo (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      .almost_full          (udp_checksum_fifo_alful),   
      .dout                 ({checksum_payload_length,
                                checksum_payload_fifo3,
                                checksum_payload_fifo2,
                                checksum_payload_fifo1,
                                checksum_payload_fifo0}),      
      .empty                (udp_checksum_fifo_empty),                 
      .din                  ({udp_payload_length_reg + 4'h8,
                                checksum_payload3,
                                checksum_payload2,
                                checksum_payload1,
                                checksum_payload0}),              
      .rd_en                (udp_checksum_fifo_rden_next),               
      .rst                  (rst),                  
      .wr_clk               (clk),              
      .wr_en                (udp_checksum_fifo_wren)           
);

//--------------------------------------calcute checksum------------------------

localparam  [3:0] CKS_STATE_IDLE = 4'b0001;
localparam  [3:0] CKS_STATE_WAIT = 4'b0010;
localparam  [3:0] CKS_STATE_CAL0 = 4'b0100;
localparam  [3:0] CKS_STATE_CAL1 = 4'b1000;

reg [3:0] cks_state_next, cks_state_reg = CKS_STATE_IDLE;
reg [15:0] checksum_payload4_next,checksum_payload4_reg = 'b0;
reg [15:0] checksum_payload5_next,checksum_payload5_reg = 'b0;
reg [15:0] checksum_payload6_next,checksum_payload6_reg = 'b0;
reg [15:0] checksum_payload7_next,checksum_payload7_reg = 'b0;

reg [15:0] checksum_header0_next, checksum_header0_reg = 'b0;
reg [15:0] checksum_header1_next, checksum_header1_reg = 'b0;
reg [15:0] checksum_header2_next, checksum_header2_reg = 'b0;
reg [15:0] checksum_header3_next, checksum_header3_reg = 'b0;
reg [15:0] checksum_header4_next, checksum_header4_reg = 'b0;
reg [15:0] checksum_header5_next, checksum_header5_reg = 'b0;
reg [15:0] checksum_header6_next, checksum_header6_reg = 'b0;
reg [15:0] checksum_header7_next, checksum_header7_reg = 'b0;

reg [15:0] checksum_payload_next, checksum_payload_reg   = 0;
reg  udp_desc_fifo_wr_next,udp_desc_fifo_wr_reg = 'b0;
//wire udp_desc_fifo_alful;
reg [31:0] udp_desc_fifo_din = 'b0;
reg udp_desc_dout_rden_next, udp_desc_dout_rden_reg = 'b0;
wire udp_desc_fifo_empty;
wire [15:0] udp_desc_fifo_length,udp_desc_fifo_checksum;

always @(*) begin
    cks_state_next = cks_state_reg;
    udp_checksum_fifo_rden_next = 'b0;
    //-------------------------------------------------------
    checksum_payload4_next = checksum_payload4_reg;
    checksum_payload5_next = checksum_payload5_reg;
    checksum_payload6_next = checksum_payload6_reg;
    //-------------------------------------------------------
    checksum_header0_next = checksum_header0_reg;
    checksum_header1_next = checksum_header1_reg;
    checksum_header2_next = checksum_header2_reg;
    checksum_header3_next = checksum_header3_reg;
    checksum_header4_next = checksum_header4_reg;
    checksum_header5_next = checksum_header5_reg;
    //-------------------------------------------------------
    checksum_payload_next = checksum_payload_reg;

    udp_desc_fifo_wr_next = 0;

    case (cks_state_reg)
        CKS_STATE_IDLE : begin
            // Only pull the next checksum entry when the descriptor FIFO has
            // room.  udp_desc_fifo is 16 deep but the output FSM consumes one
            // entry per ~4 cycles minimum, so a stream of small frames can
            // complete faster than descriptors drain; writing while full
            // silently drops the entry and permanently shifts the UDP
            // length/checksum onto the following frame (Wireshark then
            // reports "Bad UDP length").  Stalling here backs up into
            // udp_checksum_fifo, whose almost-full already throttles the
            // app interface, so no data can be lost.
            if (~udp_checksum_fifo_empty && (udp_desc_fifo_count < 16'd12)) begin
                cks_state_next = CKS_STATE_WAIT;
                udp_checksum_fifo_rden_next = 1'b1;
            end
        end

        CKS_STATE_WAIT : begin
            //------------------------------payload
            checksum_payload4_next = checksum_gen(checksum_payload_fifo0,checksum_payload_fifo1);
            checksum_payload5_next = checksum_gen(checksum_payload_fifo2,checksum_payload_fifo3);
            //------------------------------header
            checksum_header0_next = checksum_gen(src_ip_addr[15:0]  , src_ip_addr[31:16]);
            checksum_header1_next = checksum_gen(dst_ip_addr[15:0]  , dst_ip_addr[31:16]);
            checksum_header2_next = checksum_gen(
                checksum_gen({8'h0000, 8'd17}  , checksum_payload_length),
                checksum_payload_length);
            checksum_header3_next = checksum_gen(udp_src_port , udp_dst_port);

            cks_state_next = CKS_STATE_CAL0;
        end

        CKS_STATE_CAL0 : begin   
            //------------------------------- payload
            checksum_payload6_next = checksum_gen(checksum_payload4_reg , checksum_payload5_reg);
            //------------------------------- header
            checksum_header4_next = checksum_gen(checksum_header0_reg , checksum_header1_reg);
            checksum_header5_next = checksum_gen(checksum_header2_reg , checksum_header3_reg);

            cks_state_next = CKS_STATE_CAL1;
        end

        CKS_STATE_CAL1 : begin
            //------------------------------- checksum
            checksum_payload_next = ~checksum_gen(checksum_payload6_reg,
                                    checksum_gen(checksum_header5_reg,checksum_header4_reg));
            if (checksum_payload_next == 16'd0) begin
                checksum_payload_next = 16'hFFFF;
            end
            udp_desc_fifo_wr_next = 1'b1;
            cks_state_next = CKS_STATE_IDLE;
        end
        default: begin
        end
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        cks_state_reg <= CKS_STATE_IDLE;

        checksum_payload4_reg <= 'b0;
        checksum_payload5_reg <= 'b0;
        checksum_payload6_reg <= 'b0;

        checksum_header0_reg <= 'b0;
        checksum_header1_reg <= 'b0;
        checksum_header2_reg <= 'b0;
        checksum_header3_reg <= 'b0;
        checksum_header4_reg <= 'b0;
        checksum_header5_reg <= 'b0;

        checksum_payload_reg <= 'b0;
        udp_desc_fifo_wr_reg <= 'b0;
    end
    else begin
        cks_state_reg <= cks_state_next;

        checksum_payload4_reg <= checksum_payload4_next;
        checksum_payload5_reg <= checksum_payload5_next;
        checksum_payload6_reg <= checksum_payload6_next;

        checksum_header0_reg <= checksum_header0_next;
        checksum_header1_reg <= checksum_header1_next;
        checksum_header2_reg <= checksum_header2_next;
        checksum_header3_reg <= checksum_header3_next;
        checksum_header4_reg <= checksum_header4_next;
        checksum_header5_reg <= checksum_header5_next;

        checksum_payload_reg <= checksum_payload_next;
        udp_desc_fifo_wr_reg <= udp_desc_fifo_wr_next;
    end
end

xpm_fifo_sync #(
      .CASCADE_HEIGHT       (CASCADE_HEIGHT      ),       
      .DOUT_RESET_VALUE     (DOUT_RESET_VALUE    ),    
      .ECC_MODE             (ECC_MODE            ),     
      .FIFO_MEMORY_TYPE     (FIFO_MEMORY_TYPE    ),
      .FIFO_READ_LATENCY    (1                  ),   
      .FIFO_WRITE_DEPTH     (16), 
      .FULL_RESET_VALUE     (FULL_RESET_VALUE    ),     
      .PROG_EMPTY_THRESH    (PROG_EMPTY_THRESH   ),   
      .PROG_FULL_THRESH     (PROG_FULL_THRESH    ),   
      .RD_DATA_COUNT_WIDTH  (5 ),  
      .READ_DATA_WIDTH      (32),   
      .READ_MODE            ("std"               ),        
      .SIM_ASSERT_CHK       (SIM_ASSERT_CHK      ),        
      .USE_ADV_FEATURES     (USE_ADV_FEATURES    ), 
      .WAKEUP_TIME          (WAKEUP_TIME         ),          
      .WRITE_DATA_WIDTH     (32),     
      .WR_DATA_COUNT_WIDTH  (5 )    
)udp_desc_fifo (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      //.almost_full          (udp_desc_fifo_alful),   
      .dout                 ({udp_desc_fifo_length,udp_desc_fifo_checksum}),      
      .empty                (udp_desc_fifo_empty),     
      .wr_data_count        (udp_desc_fifo_count),
      .din                  ({checksum_payload_length,checksum_payload_reg}),              
      .rd_en                (udp_desc_dout_rden_reg),               
      .rst                  (rst),                  
      .wr_clk               (clk),              
      .wr_en                (udp_desc_fifo_wr_reg)           
);

//-------------------------------------------------------------------------------
localparam IP_PACKET_IDLE = 4'b0001;
localparam IP_PACKET_WAIT = 4'b0010;
localparam IP_PACKET_DATA = 4'b0100;
localparam IP_PACKET_ENDL = 4'b1000;

reg [3:0]ip_state_next, ip_state_reg = IP_PACKET_IDLE; 
reg [63:0] ip_tx_axis_tdata_init;
reg [7:0]  ip_tx_axis_tkeep_init;
reg        ip_tx_axis_tlast_init;
reg        ip_tx_axis_tvalid_init;
wire       ip_tx_axis_tready_init;

always @(*) begin
    ip_state_next = ip_state_reg;
    udp_desc_dout_rden_next = 'b0;
    udp_payload_fifo_rden_next = 'b0;

    // idle defaults: no valid output beat (full assignment avoids latches)
    ip_tx_axis_tdata_init  = 64'd0;
    ip_tx_axis_tkeep_init  = 8'd0;
    ip_tx_axis_tlast_init  = 1'b0;
    ip_tx_axis_tvalid_init = 1'b0;

    case (ip_state_reg)
        IP_PACKET_IDLE : begin
            if (~udp_desc_fifo_empty) begin
                ip_state_next = IP_PACKET_WAIT;
                udp_desc_dout_rden_next = 1'b1;
            end else begin
                ip_state_next = IP_PACKET_IDLE;
            end
        end

        // wait for downstream ready and payload availability; desc
        // length/checksum are already valid in this state
        IP_PACKET_WAIT : begin
            if (ip_tx_axis_tready_init && !udp_payload_fifo_empty) begin
                ip_state_next = IP_PACKET_DATA;
            end else begin
                ip_state_next = IP_PACKET_WAIT;
            end
        end

        // 8-byte UDP header (src/dst port, length, checksum);
        // hold the beat until the output path accepts it
        IP_PACKET_DATA : begin
            ip_tx_axis_tdata_init = {
                udp_desc_fifo_checksum[7:0], udp_desc_fifo_checksum[15:8],
                udp_desc_fifo_length[7:0],   udp_desc_fifo_length[15:8],
                udp_dst_port[7:0],           udp_dst_port[15:8],
                udp_src_port[7:0],           udp_src_port[15:8]
            };
            ip_tx_axis_tkeep_init  = 8'hff;
            ip_tx_axis_tlast_init  = 1'b0;
            ip_tx_axis_tvalid_init = 1'b1;
            if (ip_tx_axis_tready_init) begin
                ip_state_next = IP_PACKET_ENDL;
            end else begin
                ip_state_next = IP_PACKET_DATA;
            end
        end

        // stream payload from the FWFT FIFO; pop exactly one word per
        // accepted beat so no data is dropped under backpressure
        IP_PACKET_ENDL : begin
            ip_tx_axis_tdata_init  = udp_payload_fifo_dout[63:0];
            ip_tx_axis_tkeep_init  = udp_payload_fifo_dout[71:64];
            ip_tx_axis_tvalid_init = udp_payload_fifo_dout[72];
            ip_tx_axis_tlast_init  = udp_payload_fifo_dout[73];
            if (ip_tx_axis_tvalid_init && ip_tx_axis_tready_init) begin
                udp_payload_fifo_rden_next = 1'b1;
                if (ip_tx_axis_tlast_init) begin
                    ip_state_next = IP_PACKET_IDLE;
                end else begin
                    ip_state_next = IP_PACKET_ENDL;
                end
            end else begin
                ip_state_next = IP_PACKET_ENDL;
            end
        end
        default: begin
            
        end
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        ip_state_reg <= IP_PACKET_IDLE;
        udp_desc_dout_rden_reg <= 'b0;
    end else begin
        ip_state_reg <= ip_state_next;
        udp_desc_dout_rden_reg <= udp_desc_dout_rden_next;
    end
end

//-------------------------------------------------------------------------------

localparam  OUTPUT_FIFO_ADDR_WIDTH = 9;

reg [63:0] ip_tx_axis_tdata_reg;
reg [7:0]  ip_tx_axis_tkeep_reg;
reg        ip_tx_axis_tlast_reg;
reg        ip_tx_axis_tvalid_reg;

(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [63:0] out_fifo_wdata[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [7:0]  out_fifo_wstrb[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg                      out_fifo_eop[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];

reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_wr_ptr_reg = 0;
reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_rd_ptr_reg = 0;

wire out_fifo_full = out_fifo_wr_ptr_reg == (out_fifo_rd_ptr_reg ^ {1'b1, {OUTPUT_FIFO_ADDR_WIDTH{1'b0}}});
wire out_fifo_empty = out_fifo_wr_ptr_reg == out_fifo_rd_ptr_reg;

assign ip_tx_axis_tready_init = !out_fifo_full;


always @(posedge clk) begin
    ip_tx_axis_tvalid_reg <= ip_tx_axis_tvalid_reg && !ip_tx_axis_tready;

    if (!out_fifo_full && ip_tx_axis_tvalid_init) begin
        out_fifo_wdata[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= ip_tx_axis_tdata_init;
        out_fifo_wstrb[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= ip_tx_axis_tkeep_init;
        out_fifo_eop[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= ip_tx_axis_tlast_init;     

        out_fifo_wr_ptr_reg <= out_fifo_wr_ptr_reg + 1;
    end

    if (!out_fifo_empty && (!ip_tx_axis_tvalid_reg || ip_tx_axis_tready)) begin
        ip_tx_axis_tdata_reg <= out_fifo_wdata[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        ip_tx_axis_tkeep_reg <= out_fifo_wstrb[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        ip_tx_axis_tlast_reg <= out_fifo_eop[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        ip_tx_axis_tvalid_reg <= 1'b1;
        out_fifo_rd_ptr_reg <= out_fifo_rd_ptr_reg + 1;
    end

    if (rst) begin
        out_fifo_wr_ptr_reg <= 0;
        out_fifo_rd_ptr_reg <= 0;
        ip_tx_axis_tvalid_reg <= 1'b0;
    end
end

assign ip_tx_axis_tdata  = ip_tx_axis_tdata_reg;
assign ip_tx_axis_tkeep  = ip_tx_axis_tkeep_reg;
assign ip_tx_axis_tvalid = ip_tx_axis_tvalid_reg;
assign ip_tx_axis_tlast  = ip_tx_axis_tlast_reg;

endmodule

`resetall