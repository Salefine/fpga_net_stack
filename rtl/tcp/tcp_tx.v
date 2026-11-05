/****************************************************************************
 * @file    tcp_tx.v
 * @brief  
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.0
 * @date    2026-10-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.0      |    zzhi          | tcp server             |
 * |               |   v1.1      |    zzhi          | 数据包组包发送: TCP头  |
 * |               |             |                  | 3拍(port/seq, ack/    |
 * |               |             |                  | doff/flags/win, cksum)|
 * |               |             |                  | 第3拍含4B padding,     |
 * |               |             |                  | offset=6(24B), 完整   |
 * |               |             |                  | RFC793校验和           |
 * |               |   v1.2      |    zzhi          | 重传: tcp_ack_ok等待  |
 * |               |             |                  | ACK, 超时自动重传,     |
 * |               |             |                  | stop-and-wait单包在途   |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2026 zzhi
 * ***************************************************************************/

`resetall
`timescale 1ns / 1ps
`default_nettype none

module tcp_tx #(
    parameter integer RETRANSMIT_RETRY_COUNT = 4,          //超时重传次数(0=不重传,超时即放弃)
    parameter integer RETRANSMIT_TIMEOUT     = 125000000   //重传超时周期数(125MHz下约1s)
)(
    input  wire [31:0]src_ip_addr,     //source ip address
    input  wire [31:0]dst_ip_addr,     //destination ip address
                                           
    input  wire [15:0]tcp_src_port,    //tcp source port
    input  wire [15:0]tcp_dst_port,    //tcp destination port

    //tcp建立连接信号
    input  wire tcp_linkup,
    //数据包发送后等待的ACK应答: 1拍脉冲表示"在途数据段已被client确认"
    //(纯ACK或数据段携带的ACK均可), 由tcp_ctrl根据client ACK号判定后给出;
    //超时未确认则由本模块自动重传
    input  wire tcp_ack_ok,
    //seq number
    input  wire [31:0] tcp_tx_seq,
    //ack number
    input  wire [31:0] tcp_tx_ack,
    //窗口大小
    input  wire [15:0] tcp_tx_window,
    //在途/最近发送段的负载字节数(供tcp_ctrl在ACK确认后推进发送序号)
    output wire [15:0] tcp_tx_len,
          
	input  wire clk,
    input  wire rst,

    //----------------------------ctrl--------------------

	/* tcp tx axis interface */		  
    input  wire [63:0]   app_tx_axis_tdata ,
    input  wire [7:0]    app_tx_axis_tkeep ,
    input  wire          app_tx_axis_tvalid,		 
    input  wire          app_tx_axis_tlast ,
    output wire          app_tx_axis_tready,
	/* tx axis interface to ip */
	output wire [63:0]   tcp_tx_axis_tdata ,
    output wire [7:0]    tcp_tx_axis_tkeep ,
    output wire          tcp_tx_axis_tvalid,		 
    output wire          tcp_tx_axis_tlast ,
    input  wire          tcp_tx_axis_tready
);
//--------------------------------------------------------------------------
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

//-----------------------------------------------------------------------------

reg [15:0] tcp_length_reg      = 16'd0;
reg [15:0] tcp_length_temp_reg = 16'd0;

//在途/最近发送段的负载字节数: tcp_ctrl据此在ACK确认后推进发送序号
assign tcp_tx_len = tcp_length_reg;

always @(posedge clk) begin
    if (rst) begin
        tcp_length_reg      <= 16'd0;
        tcp_length_temp_reg <= 16'd0;
    end
    else if (app_tx_axis_tvalid && app_tx_axis_tready) begin
        if (app_tx_axis_tlast) begin
            tcp_length_reg <= tcp_length_temp_reg + count_valid_bytes(app_tx_axis_tkeep);
            tcp_length_temp_reg <= 16'd0;
        end
        else begin
            tcp_length_temp_reg <= tcp_length_temp_reg + count_valid_bytes(app_tx_axis_tkeep);
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

reg tcp_payload_fifo_rden_next;

wire [73:0] tcp_payload_init = {app_tx_axis_tlast,app_tx_axis_tvalid,app_tx_axis_tkeep,app_tx_axis_tdata};
wire tcp_payload_fifo_alfull;
wire tcp_payload_fifo_empty;
wire [73:0]tcp_payload_fifo_dout;
wire tcp_checksum_fifo_alful;

//stop-and-wait: 一包在途等待ACK期间背压应用侧, 防止下一包覆盖重传缓冲
reg tx_busy_reg = 1'b0;

assign app_tx_axis_tready = tcp_linkup & ~tcp_payload_fifo_alfull & ~tcp_checksum_fifo_alful & ~tx_busy_reg;

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
)tcp_payload_fifo (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      .almost_full          (tcp_payload_fifo_alfull),   
      .dout                 (tcp_payload_fifo_dout),      
      .empty                (tcp_payload_fifo_empty),                 
      .din                  (tcp_payload_init),              
      .rd_en                (tcp_payload_fifo_rden_next),               
      .rst                  (rst),                  
      .wr_clk               (clk),              
      .wr_en                (app_tx_axis_tready & app_tx_axis_tvalid)           
);

//--------------------------重传缓冲(仅存载荷)--------------------------
localparam  RETX_RAM_DEPTH = 2048;   //与payload FIFO同深, 缓存一整包
localparam  RETX_RAM_AW    = 11;

(* ram_style = "block" *)
reg [72:0] retx_ram [0:RETX_RAM_DEPTH-1];   //{tlast, tkeep, tdata}

reg [RETX_RAM_AW-1:0] retx_wr_addr = 0;
reg ack_latched_reg = 1'b0;   //busy期间收到过tcp_ack_ok

always @(posedge clk) begin
    if (rst) begin
        retx_wr_addr <= 0;
    end
    else if (app_tx_axis_tvalid & app_tx_axis_tready) begin
        retx_ram[retx_wr_addr] <= {app_tx_axis_tlast, app_tx_axis_tkeep, app_tx_axis_tdata};
        if (app_tx_axis_tlast)
            retx_wr_addr <= 0;
        else
            retx_wr_addr <= retx_wr_addr + 1'b1;
    end
end

reg  [15:0]  checksum_payload0  = 0;
reg  [15:0]  checksum_payload1  = 0;
reg  [15:0]  checksum_payload2  = 0;
reg  [15:0]  checksum_payload3  = 0;
reg  [15:0]  checksum_temp_load0= 0;
reg  [15:0]  checksum_temp_load1= 0;
reg  [15:0]  checksum_temp_load2= 0;
reg  [15:0]  checksum_temp_load3= 0;

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
    else if (app_tx_axis_tready & app_tx_axis_tvalid) begin
        if (app_tx_axis_tlast) begin
            case (app_tx_axis_tkeep)
                8'b00000001: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {app_tx_axis_tdata[7:0], 8'h00});
                    checksum_payload1 <= checksum_temp_load1;
                    checksum_payload2 <= checksum_temp_load2;
                    checksum_payload3 <= checksum_temp_load3;
                end
                8'b00000011: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {app_tx_axis_tdata[7:0], app_tx_axis_tdata[15:8]});        
                    checksum_payload1 <= checksum_temp_load1;
                    checksum_payload2 <= checksum_temp_load2;
                    checksum_payload3 <= checksum_temp_load3;          
                end
                8'b00000111: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {app_tx_axis_tdata[7:0]  , app_tx_axis_tdata[15:8]});  
                    checksum_payload1 <= checksum_gen(checksum_temp_load1, {app_tx_axis_tdata[23:16], 8'h0});          
                    checksum_payload2 <= checksum_temp_load2;
                    checksum_payload3 <= checksum_temp_load3;                   
                end
                8'b00001111: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {app_tx_axis_tdata[7:0]  , app_tx_axis_tdata[15:8]});  
                    checksum_payload1 <= checksum_gen(checksum_temp_load1, {app_tx_axis_tdata[23:16], app_tx_axis_tdata[31:24]}); 
                    checksum_payload2 <= checksum_temp_load2;
                    checksum_payload3 <= checksum_temp_load3;                            
                end
                8'b00011111: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {app_tx_axis_tdata[7:0]  , app_tx_axis_tdata[15:8]});  
                    checksum_payload1 <= checksum_gen(checksum_temp_load1, {app_tx_axis_tdata[23:16], app_tx_axis_tdata[31:24]}); 
                    checksum_payload2 <= checksum_gen(checksum_temp_load2, {app_tx_axis_tdata[39:32], 8'h00});      
                    checksum_payload3 <= checksum_temp_load3;                  
                end
                8'b00111111: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {app_tx_axis_tdata[7:0]  , app_tx_axis_tdata[15:8]});  
                    checksum_payload1 <= checksum_gen(checksum_temp_load1, {app_tx_axis_tdata[23:16], app_tx_axis_tdata[31:24]}); 
                    checksum_payload2 <= checksum_gen(checksum_temp_load2, {app_tx_axis_tdata[39:32], app_tx_axis_tdata[47:40]});       
                    checksum_payload3 <= checksum_temp_load3;                     
                end
                8'b01111111: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {app_tx_axis_tdata[7:0]  , app_tx_axis_tdata[15:8]});  
                    checksum_payload1 <= checksum_gen(checksum_temp_load1, {app_tx_axis_tdata[23:16], app_tx_axis_tdata[31:24]}); 
                    checksum_payload2 <= checksum_gen(checksum_temp_load2, {app_tx_axis_tdata[39:32], app_tx_axis_tdata[47:40]}); 
                    checksum_payload3 <= checksum_gen(checksum_temp_load3, {app_tx_axis_tdata[55:48], 8'h00});                       
                end
                8'b11111111: begin
                    checksum_payload0 <= checksum_gen(checksum_temp_load0, {app_tx_axis_tdata[7:0]  , app_tx_axis_tdata[15:8]});  
                    checksum_payload1 <= checksum_gen(checksum_temp_load1, {app_tx_axis_tdata[23:16], app_tx_axis_tdata[31:24]}); 
                    checksum_payload2 <= checksum_gen(checksum_temp_load2, {app_tx_axis_tdata[39:32], app_tx_axis_tdata[47:40]});   
                    checksum_payload3 <= checksum_gen(checksum_temp_load3, {app_tx_axis_tdata[55:48], app_tx_axis_tdata[63:56]});                    
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
            checksum_temp_load0 <= checksum_gen(checksum_temp_load0, {app_tx_axis_tdata[7:0]   , app_tx_axis_tdata[15:8]});     
            checksum_temp_load1 <= checksum_gen(checksum_temp_load1, {app_tx_axis_tdata[23:16] , app_tx_axis_tdata[31:24]});     
            checksum_temp_load2 <= checksum_gen(checksum_temp_load2, {app_tx_axis_tdata[39:32] , app_tx_axis_tdata[47:40]});     
            checksum_temp_load3 <= checksum_gen(checksum_temp_load3, {app_tx_axis_tdata[55:48] , app_tx_axis_tdata[63:56]});     
        end
    end
end

wire [15:0] checksum_payload_fifo0;
wire [15:0] checksum_payload_fifo1;
wire [15:0] checksum_payload_fifo2;
wire [15:0] checksum_payload_fifo3;
wire [15:0] checksum_payload_length;
wire tcp_checksum_fifo_empty;
reg tcp_checksum_fifo_wren = 'b0;
reg tcp_checksum_fifo_rden_next;

always @(posedge clk) begin
    if (rst) begin
        tcp_checksum_fifo_wren <= 'b0;
    end
    else if (tcp_checksum_fifo_wren) begin
        tcp_checksum_fifo_wren <= 'b0;
    end
    else if (app_tx_axis_tvalid & app_tx_axis_tready & app_tx_axis_tlast) begin
        tcp_checksum_fifo_wren <= 1'b1;
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
)tcp_checksum_fifo (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      .almost_full          (tcp_checksum_fifo_alful),   
      .dout                 ({checksum_payload_length,
                                checksum_payload_fifo3,
                                checksum_payload_fifo2,
                                checksum_payload_fifo1,
                                checksum_payload_fifo0}),      
      .empty                (tcp_checksum_fifo_empty),                 
      .din                  ({tcp_length_reg + 16'd24,
                                checksum_payload3,
                                checksum_payload2,
                                checksum_payload1,
                                checksum_payload0}),              
      .rd_en                (tcp_checksum_fifo_rden_next),               
      .rst                  (rst),                  
      .wr_clk               (clk),              
      .wr_en                (tcp_checksum_fifo_wren)           
);

localparam  [5:0] s0 = 6'b000001;
localparam  [5:0] s1 = 6'b000010;
localparam  [5:0] s2 = 6'b000100;
localparam  [5:0] s3 = 6'b001000;
localparam  [5:0] cks_s4 = 6'b010000;
localparam  [5:0] cks_s5 = 6'b100000;

reg [5:0] cks_state_next, cks_state_reg = s0;
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
reg [15:0] checksum_header8_next, checksum_header8_reg = 'b0;

reg [15:0] checksum_payload_next, checksum_payload_reg   = 0;
reg  tcp_desc_fifo_wr_next , tcp_desc_fifo_wr_reg = 'b0;
wire tcp_desc_fifo_alful;
reg [31:0] tcp_desc_fifo_din = 'b0;
reg  tcp_desc_dout_rden_next, tcp_desc_dout_rden_reg = 'b0;
wire tcp_desc_fifo_empty;
wire [15:0] tcp_desc_fifo_length,tcp_desc_fifo_checksum;

always @(*) begin
    cks_state_next = cks_state_reg;
    tcp_checksum_fifo_rden_next = 'b0;
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
    checksum_header6_next = checksum_header6_reg;
    checksum_header7_next = checksum_header7_reg;
    checksum_header8_next = checksum_header8_reg;
    //-------------------------------------------------------
    checksum_payload_next = checksum_payload_reg;

    tcp_desc_fifo_wr_next = 0;

    case (cks_state_reg)
        s0 : begin
            if (~tcp_checksum_fifo_empty) begin
                cks_state_next = s1;
                tcp_checksum_fifo_rden_next = 1'b1;
            end
        end

        // 第1级：伪首部、TCP头字段、负载，两两合并成8个16位累加器
        s1 : begin
            //------------------------------payload
            checksum_payload4_next = checksum_gen(checksum_payload_fifo0,checksum_payload_fifo1);
            checksum_payload5_next = checksum_gen(checksum_payload_fifo2,checksum_payload_fifo3);
            //------------------------------伪首部
            checksum_header0_next = checksum_gen(src_ip_addr[15:0]  , src_ip_addr[31:16]);
            checksum_header1_next = checksum_gen(dst_ip_addr[15:0]  , dst_ip_addr[31:16]);
            checksum_header2_next = checksum_gen({8'h0000, 8'd6}  , checksum_payload_length);
            //------------------------------TCP头字段
            checksum_header3_next = checksum_gen(tcp_src_port , tcp_dst_port);
            checksum_header4_next = checksum_gen(tcp_tx_seq[15:0] , tcp_tx_seq[31:16]);
            checksum_header5_next = checksum_gen(tcp_tx_ack[15:0] , tcp_tx_ack[31:16]);
            checksum_header6_next = checksum_gen({8'h60, 8'h18} , tcp_tx_window);
            checksum_header7_next = 16'h0000;   //checksum/urgent字段在计算时为0

            cks_state_next = s2;
        end

        // 第2级：8个累加器 -> 4个
        s2 : begin   
            //------------------------------- payload
            checksum_payload6_next = checksum_gen(checksum_payload4_reg , checksum_payload5_reg);
            //------------------------------- header
            checksum_header0_next = checksum_gen(checksum_header0_reg , checksum_header1_reg);
            checksum_header1_next = checksum_gen(checksum_header2_reg , checksum_header3_reg);
            checksum_header2_next = checksum_gen(checksum_header4_reg , checksum_header5_reg);
            checksum_header3_next = checksum_gen(checksum_header6_reg , checksum_header7_reg);

            cks_state_next = s3;
        end

        // 第3级：4个 -> 2个
        s3 : begin
            checksum_header4_next = checksum_gen(checksum_header0_reg , checksum_header1_reg);
            checksum_header5_next = checksum_gen(checksum_header2_reg , checksum_header3_reg);

            cks_state_next = cks_s4;
        end

        // 第5级：头和折叠(时序优化：原第4级中两级checksum_gen级联是
        // tcp_tx的关键路径，拆成两拍)
        cks_s4 : begin
            checksum_header8_next = checksum_gen(checksum_header5_reg , checksum_header4_reg);
            cks_state_next = cks_s5;
        end

        // 第6级：最终校验和 = ~(负载和 + 头和)
        cks_s5 : begin
            checksum_payload_next = ~checksum_gen(checksum_payload6_reg, checksum_header8_reg);
            if (checksum_payload_next == 16'd0) begin
                checksum_payload_next = 16'hFFFF;
            end
            tcp_desc_fifo_wr_next = 1'b1;
            cks_state_next = s0;
        end
        default: begin
        end
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        cks_state_reg <= s0;

        checksum_payload4_reg <= 'b0;
        checksum_payload5_reg <= 'b0;
        checksum_payload6_reg <= 'b0;

        checksum_header0_reg <= 'b0;
        checksum_header1_reg <= 'b0;
        checksum_header2_reg <= 'b0;
        checksum_header3_reg <= 'b0;
        checksum_header4_reg <= 'b0;
        checksum_header5_reg <= 'b0;
        checksum_header6_reg <= 'b0;
        checksum_header7_reg <= 'b0;
        checksum_header8_reg <= 'b0;

        checksum_payload_reg <= 'b0;
        tcp_desc_fifo_wr_reg <= 'b0;
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
        checksum_header6_reg <= checksum_header6_next;
        checksum_header7_reg <= checksum_header7_next;
        checksum_header8_reg <= checksum_header8_next;

        checksum_payload_reg <= checksum_payload_next;
        tcp_desc_fifo_wr_reg <= tcp_desc_fifo_wr_next;
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
)tcp_desc_fifo (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      .almost_full          (tcp_desc_fifo_alful),   
      .dout                 ({tcp_desc_fifo_length,tcp_desc_fifo_checksum}),      
      .empty                (tcp_desc_fifo_empty),                 
      .din                  ({checksum_payload_length,checksum_payload_reg}),              
      .rd_en                (tcp_desc_dout_rden_reg),               
      .rst                  (rst),                  
      .wr_clk               (clk),              
      .wr_en                (tcp_desc_fifo_wr_reg)           
);


//-------------------------------------------------------------------------------

localparam s4 = 6'b000001;
localparam s5 = 6'b000010;
localparam s6 = 6'b000100;
localparam s7 = 6'b001000;
localparam s8 = 6'b010000;
localparam s9 = 6'b100000;

reg [5:0]ip_state_next, ip_state_reg = s4; 
reg [63:0] ip_tx_axis_tdata_init;
reg [7:0]  ip_tx_axis_tkeep_init;
reg        ip_tx_axis_tlast_init;
reg        ip_tx_axis_tvalid_init;
wire       ip_tx_axis_tready_init;

always @(*) begin
    ip_state_next = ip_state_reg;
    tcp_desc_dout_rden_next = 'b0;
    tcp_payload_fifo_rden_next = 'b0;

    // idle defaults: no valid output beat (full assignment avoids latches)
    ip_tx_axis_tdata_init  = 64'd0;
    ip_tx_axis_tkeep_init  = 8'd0;
    ip_tx_axis_tlast_init  = 1'b0;
    ip_tx_axis_tvalid_init = 1'b0;

    case (ip_state_reg)
        s4 : begin
            if (~tcp_desc_fifo_empty) begin
                ip_state_next = s5;
                tcp_desc_dout_rden_next = 1'b1;
            end else begin
                ip_state_next = s4;
            end
        end

        // wait for downstream ready and payload availability; desc
        // length/checksum are already valid in this state
        s5 : begin
            if (ip_tx_axis_tready_init && !tcp_payload_fifo_empty) begin
                ip_state_next = s6;
            end else begin
                ip_state_next = s5;
            end
        end

        // TCP头第1拍(字节0~7): src_port, dst_port, seq
        s6 : begin
            if (ip_tx_axis_tready_init) begin
                ip_tx_axis_tdata_init = {
                    tcp_tx_seq[7:0]   , tcp_tx_seq[15:8],
                    tcp_tx_seq[23:16] , tcp_tx_seq[31:24],
                    tcp_dst_port[7:0] , tcp_dst_port[15:8],
                    tcp_src_port[7:0] , tcp_src_port[15:8]
                };
                ip_tx_axis_tkeep_init  = 8'hff;
                ip_tx_axis_tlast_init  = 1'b0;
                ip_tx_axis_tvalid_init = 1'b1;   
                ip_state_next = s7;            
            end else begin
               ip_state_next = s6;
            end
        end

        // TCP头第2拍(字节8~15): ack, data offset+reserved, flags, window
        // flags固定PSH|ACK(0x18)，data offset=6(0x60): 20B首部+4B padding对齐64bit
        s7 : begin
            if (ip_tx_axis_tready_init) begin
                ip_tx_axis_tdata_init = {
                    tcp_tx_window[7:0], tcp_tx_window[15:8],
                    8'h18,                //flags: PSH|ACK
                    4'h6, 4'h0,           //data offset=6, reserved=0
                    tcp_tx_ack[7:0]  , tcp_tx_ack[15:8],
                    tcp_tx_ack[23:16], tcp_tx_ack[31:24]
                };
                ip_tx_axis_tkeep_init  = 8'hff;
                ip_tx_axis_tlast_init  = 1'b0;
                ip_tx_axis_tvalid_init = 1'b1;   
                ip_state_next = s8;            
            end else begin
               ip_state_next = s7;
            end
        end

        // TCP头第3拍(字节16~19): checksum, urgent pointer(0)
        s8 : begin
            if (ip_tx_axis_tready_init) begin
                ip_tx_axis_tdata_init = {
                    32'h0,                 //padding
                    16'h0,                 //urgent pointer
                    tcp_desc_fifo_checksum[7:0], tcp_desc_fifo_checksum[15:8]
                };
                ip_tx_axis_tkeep_init  = 8'hff;   //低4字节首部 + 高4字节padding
                ip_tx_axis_tlast_init  = 1'b0;
                ip_tx_axis_tvalid_init = 1'b1;   
                ip_state_next = s9;            
            end else begin
               ip_state_next = s8;
            end
        end

        // 从FWFT FIFO流式输出负载；每接受一拍才弹出一拍，背压时不丢数据
        s9 : begin
            ip_tx_axis_tdata_init  = tcp_payload_fifo_dout[63:0];
            ip_tx_axis_tkeep_init  = tcp_payload_fifo_dout[71:64];
            ip_tx_axis_tvalid_init = tcp_payload_fifo_dout[72];
            ip_tx_axis_tlast_init  = tcp_payload_fifo_dout[73];
            if (ip_tx_axis_tvalid_init && ip_tx_axis_tready_init) begin
                tcp_payload_fifo_rden_next = 1'b1;
                if (ip_tx_axis_tlast_init) begin
                    ip_state_next = s4;      //本包结束，回IDLE等下一个描述符
                end else begin
                    ip_state_next = s9;
                end
            end else begin
                ip_state_next = s9;
            end
        end
        default: begin
            
        end
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        ip_state_reg <= s4;
        tcp_desc_dout_rden_reg <= 'b0;
    end else begin
        ip_state_reg <= ip_state_next;
        tcp_desc_dout_rden_reg <= tcp_desc_dout_rden_next;
    end
end

//--------------------捕获发送中的首部(供重传)与段结束脉冲--------------------
reg [63:0] retx_hdr1_reg = 64'd0;
reg [63:0] retx_hdr2_reg = 64'd0;
reg [63:0] retx_hdr3_reg = 64'd0;

always @(posedge clk) begin
    if (ip_state_reg == s6 && ip_tx_axis_tready_init)
        retx_hdr1_reg <= ip_tx_axis_tdata_init;
    if (ip_state_reg == s7 && ip_tx_axis_tready_init)
        retx_hdr2_reg <= ip_tx_axis_tdata_init;
    if (ip_state_reg == s8 && ip_tx_axis_tready_init)
        retx_hdr3_reg <= ip_tx_axis_tdata_init;
end

//本包最后一拍被下游接收(发送完成), 启动重传定时
wire seg_sent = (ip_state_reg == s9) && ip_tx_axis_tvalid_init &&
                ip_tx_axis_tready_init && ip_tx_axis_tlast_init;

//------------------------------重传状态机------------------------------
localparam RXS_IDLE = 3'd0;
localparam RXS_WAIT = 3'd1;
localparam RXS_H1   = 3'd2;
localparam RXS_H2   = 3'd3;
localparam RXS_H3   = 3'd4;
localparam RXS_PF   = 3'd5;   //块RAM读端口预取一拍
localparam RXS_DATA = 3'd6;

reg [2:0]  retx_state_next, retx_state_reg = RXS_IDLE;
reg [31:0] retx_timer_next, retx_timer_reg = 32'd0;
reg [7:0]  retx_retry_next, retx_retry_reg = 8'd0;
reg [RETX_RAM_AW-1:0] retx_rd_addr_next, retx_rd_addr_reg = 0;
reg [72:0] retx_rd_dout = 73'd0;

reg [63:0] replay_tdata;
reg [7:0]  replay_tkeep;
reg        replay_tlast;
reg        replay_tvalid;

wire replay_emit = (retx_state_reg == RXS_H1) || (retx_state_reg == RXS_H2) ||
                   (retx_state_reg == RXS_H3) || (retx_state_reg == RXS_DATA);

//ACK被消费(确认)或重传次数耗尽(放弃), 都结束本包的等待
wire tx_seg_done = (retx_state_reg == RXS_WAIT) && (retx_state_next == RXS_IDLE);

//out_fifo_full在模块底部赋值, 此处前置声明供重传状态机引用
wire out_fifo_full;

//块RAM读端口(寄存器输出, 1拍读延迟)
//注意: 采样下一拍地址retx_rd_addr_next, 否则beat接收当拍地址尚未递增,
//同一beat会在dout上多停留一拍, 多拍负载重放时每拍都会被重复发送一次
always @(posedge clk) begin
    retx_rd_dout <= retx_ram[retx_rd_addr_next];
end

always @(*) begin
    retx_state_next   = retx_state_reg;
    retx_timer_next   = retx_timer_reg;
    retx_retry_next   = retx_retry_reg;
    retx_rd_addr_next = retx_rd_addr_reg;

    replay_tdata  = 64'd0;
    replay_tkeep  = 8'd0;
    replay_tlast  = 1'b0;
    replay_tvalid = 1'b0;

    case (retx_state_reg)
        RXS_IDLE : begin
            if (seg_sent) begin
                retx_state_next = RXS_WAIT;
                retx_timer_next = RETRANSMIT_TIMEOUT;
                retx_retry_next = RETRANSMIT_RETRY_COUNT;
            end
        end

        RXS_WAIT : begin
            if (ack_latched_reg) begin
                retx_state_next = RXS_IDLE;
                retx_timer_next = 32'd0;
            end
            else if (retx_timer_reg != 32'd0) begin
                retx_timer_next = retx_timer_reg - 1'b1;
            end
            else begin
                if (retx_retry_reg != 8'd0) begin
                    retx_retry_next = retx_retry_reg - 1'b1;
                    retx_state_next = RXS_H1;
                end
                else begin
                    retx_state_next = RXS_IDLE;   //重传次数耗尽, 放弃
                end
            end
        end

        RXS_H1 : begin
            replay_tdata  = retx_hdr1_reg;
            replay_tkeep  = 8'hff;
            replay_tvalid = 1'b1;
            if (!out_fifo_full)
                retx_state_next = RXS_H2;
        end

        RXS_H2 : begin
            replay_tdata  = retx_hdr2_reg;
            replay_tkeep  = 8'hff;
            replay_tvalid = 1'b1;
            if (!out_fifo_full)
                retx_state_next = RXS_H3;
        end

        RXS_H3 : begin
            replay_tdata  = retx_hdr3_reg;
            replay_tkeep  = 8'hff;
            replay_tvalid = 1'b1;
            if (!out_fifo_full) begin
                retx_rd_addr_next = 0;
                retx_state_next   = RXS_PF;
            end
        end

        RXS_PF : begin
            retx_state_next = RXS_DATA;
        end

        RXS_DATA : begin
            replay_tdata  = retx_rd_dout[63:0];
            replay_tkeep  = retx_rd_dout[71:64];
            replay_tlast  = retx_rd_dout[72];
            replay_tvalid = 1'b1;
            if (!out_fifo_full) begin
                if (replay_tlast) begin
                    retx_timer_next = RETRANSMIT_TIMEOUT;
                    retx_state_next = RXS_WAIT;
                end
                else begin
                    retx_rd_addr_next = retx_rd_addr_reg + 1'b1;
                    retx_state_next   = RXS_DATA;
                end
            end
        end

        default : begin
        end
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        retx_state_reg  <= RXS_IDLE;
        retx_timer_reg  <= 32'd0;
        retx_retry_reg  <= 8'd0;
        retx_rd_addr_reg <= 0;
    end
    else begin
        retx_state_reg  <= retx_state_next;
        retx_timer_reg  <= retx_timer_next;
        retx_retry_reg  <= retx_retry_next;
        retx_rd_addr_reg <= retx_rd_addr_next;
    end
end

//在途包控制: busy期间背压应用侧; ACK锁存供重传状态机消费
always @(posedge clk) begin
    if (rst) begin
        tx_busy_reg     <= 1'b0;
        ack_latched_reg <= 1'b0;
    end
    else begin
        //应用侧推完一整包(tlast)即置busy; ACK消费或放弃时清除
        if (app_tx_axis_tvalid & app_tx_axis_tready & app_tx_axis_tlast)
            tx_busy_reg <= 1'b1;
        else if (tx_seg_done)
            tx_busy_reg <= 1'b0;

        //busy期间收到ACK则锁存, 由重传状态机消费
        //(先清后置: 消费/放弃的当拍若ack电平仍高, 不得遗留到下一包)
        if (tx_seg_done)
            ack_latched_reg <= 1'b0;
        else if (tcp_ack_ok & tx_busy_reg)
            ack_latched_reg <= 1'b1;
    end
end
//-------------------------------------------------------------------------------

localparam  OUTPUT_FIFO_ADDR_WIDTH = 9;

reg [63:0] tcp_tx_axis_tdata_reg;
reg [7:0]  tcp_tx_axis_tkeep_reg;
reg        tcp_tx_axis_tlast_reg;
reg        tcp_tx_axis_tvalid_reg;

(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [63:0] out_fifo_wdata[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [7:0]  out_fifo_wstrb[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg                      out_fifo_eop[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];

reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_wr_ptr_reg = 0;
reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_rd_ptr_reg = 0;

assign out_fifo_full = out_fifo_wr_ptr_reg == (out_fifo_rd_ptr_reg ^ {1'b1, {OUTPUT_FIFO_ADDR_WIDTH{1'b0}}});
wire   out_fifo_empty = out_fifo_wr_ptr_reg == out_fifo_rd_ptr_reg;

//组包状态机的下游ready来自输出skid FIFO
assign ip_tx_axis_tready_init = !out_fifo_full;

//正常发送路径与重传回放路径二选一写入out_fifo(互斥: 重传仅在本包发送完成后)
wire [63:0] out_axis_tdata  = replay_emit ? replay_tdata  : ip_tx_axis_tdata_init;
wire [7:0]  out_axis_tkeep  = replay_emit ? replay_tkeep  : ip_tx_axis_tkeep_init;
wire        out_axis_tlast  = replay_emit ? replay_tlast  : ip_tx_axis_tlast_init;
wire        out_axis_tvalid = replay_emit ? replay_tvalid : ip_tx_axis_tvalid_init;


always @(posedge clk) begin
    tcp_tx_axis_tvalid_reg <= tcp_tx_axis_tvalid_reg && !tcp_tx_axis_tready;

    if (!out_fifo_full && out_axis_tvalid) begin
        out_fifo_wdata[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= out_axis_tdata;
        out_fifo_wstrb[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= out_axis_tkeep;
        out_fifo_eop[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]]   <= out_axis_tlast;     

        out_fifo_wr_ptr_reg <= out_fifo_wr_ptr_reg + 1;
    end

    if (!out_fifo_empty && (!tcp_tx_axis_tvalid_reg || tcp_tx_axis_tready)) begin
        tcp_tx_axis_tdata_reg <= out_fifo_wdata[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        tcp_tx_axis_tkeep_reg <= out_fifo_wstrb[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        tcp_tx_axis_tlast_reg <= out_fifo_eop[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        tcp_tx_axis_tvalid_reg <= 1'b1;
        out_fifo_rd_ptr_reg <= out_fifo_rd_ptr_reg + 1;
    end

    if (rst) begin
        out_fifo_wr_ptr_reg <= 0;
        out_fifo_rd_ptr_reg <= 0;
        tcp_tx_axis_tvalid_reg <= 1'b0;
    end
end

assign tcp_tx_axis_tdata  = tcp_tx_axis_tdata_reg;
assign tcp_tx_axis_tkeep  = tcp_tx_axis_tkeep_reg;
assign tcp_tx_axis_tvalid = tcp_tx_axis_tvalid_reg;
assign tcp_tx_axis_tlast  = tcp_tx_axis_tlast_reg;

endmodule

`resetall