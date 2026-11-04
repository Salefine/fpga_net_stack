/****************************************************************************
 * @file    ip_tx.v
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

module ip_tx(
    input  wire [7:0]    ip_send_type,
    input  wire [31:0]   src_ip_addr ,
    input  wire [31:0]   dst_ip_addr ,

    input   wire clk,
    input   wire rst,  
	
    /* ip tx axis interface */			
    input   wire [63:0]  ip_tx_axis_tdata ,
    input   wire [7:0]   ip_tx_axis_tkeep ,
    input   wire         ip_tx_axis_tvalid,		 
    input   wire         ip_tx_axis_tlast ,
    output  wire         ip_tx_axis_tready,

    /* tx axis interface to frame */			
    output wire [63:0]   frame_tx_axis_tdata ,
    output wire [7:0]    frame_tx_axis_tkeep ,
    output wire          frame_tx_axis_tvalid,	
    output wire          frame_tx_axis_tlast ,
    input  wire          frame_tx_axis_tready
);

reg [3:0]ip_version = 4'h4;
reg [3:0]header_len = 4'h5;
reg [7:0] TTL = 8'hff;
reg [15:0] identification = 0;
/*---------------------------------------------------------------------------------------
 * Count the number of bytes of network data packets
 *
 */

reg [15:0] ip_payload_length_reg      = 16'd0;
reg [15:0] ip_payload_length_temp_reg = 16'd0;

// 
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
        ip_payload_length_reg      <= 16'd0;
        ip_payload_length_temp_reg <= 16'd0;
    end
    else if (ip_tx_axis_tvalid && ip_tx_axis_tready) begin
        if (ip_tx_axis_tlast) begin
            ip_payload_length_reg <= ip_payload_length_temp_reg + count_valid_bytes(ip_tx_axis_tkeep);
            ip_payload_length_temp_reg <= 16'd0;
            
        end
        else begin
            ip_payload_length_temp_reg <= ip_payload_length_temp_reg + count_valid_bytes(ip_tx_axis_tkeep);
        end
    end
end

//-------------------------------------------------------------------------------
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

wire [73:0] ip_payload_init = {ip_tx_axis_tlast,ip_tx_axis_tvalid,ip_tx_axis_tkeep,ip_tx_axis_tdata};
wire ip_payload_fifo_alfull;
wire ip_payload_fifo_empty;
wire [73:0]ip_payload_fifo_dout;
reg  [73:0]ip_payload_fifo_dout_reg = 'b0;
reg ip_payload_fifo_rden_next = 'b0;

wire ip_desc_fifo_alfull;
wire ip_desc_fifo_empty;
wire [15:0] ip_desc_length;
wire [7:0] ip_type;
reg ip_desc_fifo_rden_next,ip_desc_fifo_rden_reg = 'b0;
reg ip_desc_fifo_wren_next,ip_desc_fifo_wren_reg = 'b0;

// backpressure the ingress while the payload buffer is almost full
assign ip_tx_axis_tready = ~ip_payload_fifo_alfull;

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
)ip_payload_fifo (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      .almost_full          (ip_payload_fifo_alfull),   
      .dout                 (ip_payload_fifo_dout),      
      .empty                (ip_payload_fifo_empty),                 
      .din                  (ip_payload_init),              
      .rd_en                (ip_payload_fifo_rden_next),               
      .rst                  (rst),                  
      .wr_clk               (clk),              
      .wr_en                (ip_tx_axis_tready & ip_tx_axis_tvalid)           
);

xpm_fifo_sync #(
      .CASCADE_HEIGHT       (CASCADE_HEIGHT      ),       
      .DOUT_RESET_VALUE     (DOUT_RESET_VALUE    ),    
      .ECC_MODE             (ECC_MODE            ),     
      .FIFO_MEMORY_TYPE     (FIFO_MEMORY_TYPE    ),
      .FIFO_READ_LATENCY    (1                  ),   
      .FIFO_WRITE_DEPTH     (FIFO_WRITE_DEPTH    ),  
      .FULL_RESET_VALUE     (FULL_RESET_VALUE    ),     
      .PROG_EMPTY_THRESH    (PROG_EMPTY_THRESH   ),   
      .PROG_FULL_THRESH     (PROG_FULL_THRESH    ),   
      .RD_DATA_COUNT_WIDTH  (RD_DATA_COUNT_WIDTH ),  
      .READ_DATA_WIDTH      (24),   
      .READ_MODE            ("std"),        
      .SIM_ASSERT_CHK       (SIM_ASSERT_CHK      ),        
      .USE_ADV_FEATURES     (USE_ADV_FEATURES    ), 
      .WAKEUP_TIME          (WAKEUP_TIME         ),          
      .WRITE_DATA_WIDTH     (24),     
      .WR_DATA_COUNT_WIDTH  (WR_DATA_COUNT_WIDTH )    
)ip_desc_fifo (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      .almost_full          (ip_desc_fifo_alfull),   
      .dout                 ({ip_desc_length , ip_type}),      
      .empty                (ip_desc_fifo_empty),                 
      .din                  ({ip_payload_length_reg,ip_send_type}),              
      .rd_en                (ip_desc_fifo_rden_reg),               
      .rst                  (rst),                  
      .wr_clk               (clk),              
      .wr_en                (ip_desc_fifo_wren_reg)           
);

always @(*)begin 
    ip_desc_fifo_wren_next = 1'b0;
    if(ip_tx_axis_tvalid & ip_tx_axis_tlast & ip_tx_axis_tready)begin 
        ip_desc_fifo_wren_next = 1'b1;
    end
end

always @(posedge clk)begin 
    if(rst)begin 
        ip_desc_fifo_wren_reg <= 'b0;
    end
    else begin 
        ip_desc_fifo_wren_reg <= ip_desc_fifo_wren_next;
    end
end

always @(posedge clk)begin 
    // Latch the popped payload word only when the FIFO is actually read.
    // An unconditional latch would overwrite the "previous word" state with
    // the (unpopped) head word while back-pressured in IP_SEND_DAT0, dropping
    // 4 payload bytes when the output FIFO fills mid-packet.
    if (ip_payload_fifo_rden_next)
        ip_payload_fifo_dout_reg <= ip_payload_fifo_dout;
end
//-------------------------------------------------------------------------------

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

localparam IP_STATE_IDLE = 6'b000001,
           IP_STATE_CAL0 = 6'b000010,
           IP_STATE_CAL1 = 6'b000100,
           IP_STATE_CAL2 = 6'b001000,
           IP_STATE_CAL3 = 6'b010000,
           IP_STATE_WAIT = 6'b100000;

reg [5:0] ip_state_next, ip_state_reg = IP_STATE_IDLE;

reg [15:0] ip_checksum_header0_next,ip_checksum_header0_reg;
reg [15:0] ip_checksum_header1_next,ip_checksum_header1_reg;
reg [15:0] ip_checksum_header2_next,ip_checksum_header2_reg;
reg [15:0] ip_checksum_header3_next,ip_checksum_header3_reg;
reg [15:0] ip_checksum_header4_next,ip_checksum_header4_reg;
reg [15:0] ip_checksum_header5_next,ip_checksum_header5_reg;
reg [15:0] ip_checksum_header6_next,ip_checksum_header6_reg;
reg [15:0] ip_checksum_header7_next,ip_checksum_header7_reg;
reg [15:0] ip_checksum_header8_next,ip_checksum_header8_reg;
reg [15:0] ip_checksum_header9_next,ip_checksum_header9_reg;

wire ip_header_alful;
wire ip_header_empty;
reg ip_header_rden_next, ip_header_rden_reg = 'b0;
reg ip_header_wren_next, ip_header_wren_reg = 'b0;
reg [55:0] ip_header_din_next,ip_header_din_reg = 'b0;
wire [15:0] ip_header_length;
wire [7:0]  ip_header_type;
wire [15:0] ip_header_checksum;
wire [15:0] ip_header_idcode;

always @ * begin
    ip_state_next = ip_state_reg;
    ip_desc_fifo_rden_next = 1'b0;
    ip_header_wren_next = 1'b0;
    ip_header_din_next = ip_header_din_reg;

    ip_checksum_header0_next = ip_checksum_header0_reg;
    ip_checksum_header1_next = ip_checksum_header1_reg;
    ip_checksum_header2_next = ip_checksum_header2_reg;
    ip_checksum_header3_next = ip_checksum_header3_reg;
    ip_checksum_header4_next = ip_checksum_header4_reg;
    ip_checksum_header5_next = ip_checksum_header5_reg;
    ip_checksum_header6_next = ip_checksum_header6_reg;
    ip_checksum_header7_next = ip_checksum_header7_reg;
    ip_checksum_header8_next = ip_checksum_header8_reg;
    ip_checksum_header9_next = ip_checksum_header9_reg;

    case(ip_state_reg)
        IP_STATE_IDLE: begin
            if(~ip_desc_fifo_empty)begin 
                ip_state_next = IP_STATE_WAIT;
                ip_desc_fifo_rden_next = 1'b1;
            end else begin 
                ip_state_next = IP_STATE_IDLE;
            end
        end

        IP_STATE_WAIT : begin 
            ip_state_next = IP_STATE_CAL0;
        end

        IP_STATE_CAL0 : begin 
            ip_checksum_header0_next = checksum_gen(ip_desc_length + 16'd20,16'h4500);
            ip_checksum_header1_next = checksum_gen(identification,16'h4000);
            ip_checksum_header2_next = checksum_gen({TTL,ip_type},16'h0000);
            ip_checksum_header3_next = checksum_gen(src_ip_addr[15:0] ,  src_ip_addr[31:16]);
            ip_checksum_header4_next = checksum_gen(dst_ip_addr[15:0] ,  dst_ip_addr[31:16]);
            ip_state_next = IP_STATE_CAL1;
        end

        IP_STATE_CAL1 : begin
            ip_checksum_header5_next = checksum_gen(ip_checksum_header0_reg, ip_checksum_header1_reg);
            ip_checksum_header6_next = checksum_gen(ip_checksum_header2_reg, ip_checksum_header3_reg);
            ip_checksum_header7_next = ip_checksum_header4_reg;
            ip_state_next = IP_STATE_CAL2;
        end

        IP_STATE_CAL2 : begin 
            ip_checksum_header9_next = checksum_gen(ip_checksum_header5_reg, ip_checksum_header6_reg);
            ip_state_next = IP_STATE_CAL3;
        end    

        IP_STATE_CAL3 : begin 
            ip_checksum_header8_next = ~checksum_gen(ip_checksum_header7_reg, ip_checksum_header9_reg);
            if (ip_checksum_header8_next == 16'd0) begin
                ip_checksum_header8_next = 16'hFFFF;
            end
            ip_header_wren_next = 1'b1;
            ip_header_din_next = {identification,ip_type, ip_desc_length + 16'd20, ip_checksum_header8_next};
            ip_state_next = IP_STATE_IDLE;
        end    
        default : begin 
            ip_state_next = IP_STATE_IDLE;
        end
    endcase
end

always @(posedge clk)begin
    if(rst)begin
        ip_state_reg <= IP_STATE_IDLE;
        ip_desc_fifo_rden_reg <= 'b0;
        ip_header_wren_reg <= 'b0;
        ip_header_din_reg <= 'b0;
        identification <= 'b0;

        ip_checksum_header0_reg <= 'b0;
        ip_checksum_header1_reg <= 'b0;
        ip_checksum_header2_reg <= 'b0;
        ip_checksum_header3_reg <= 'b0;
        ip_checksum_header4_reg <= 'b0;
        ip_checksum_header5_reg <= 'b0;
        ip_checksum_header6_reg <= 'b0;
        ip_checksum_header7_reg <= 'b0;
        ip_checksum_header8_reg <= 'b0;
        ip_checksum_header9_reg <= 'b0;
    end else begin 
        ip_state_reg <= ip_state_next;
        ip_desc_fifo_rden_reg <= ip_desc_fifo_rden_next;
        ip_header_wren_reg <= ip_header_wren_next;
        if(ip_header_wren_reg)begin
           identification <= identification + 1'b1; 
        end 
        ip_header_din_reg <= ip_header_din_next;

        ip_checksum_header0_reg <= ip_checksum_header0_next;
        ip_checksum_header1_reg <= ip_checksum_header1_next;
        ip_checksum_header2_reg <= ip_checksum_header2_next;
        ip_checksum_header3_reg <= ip_checksum_header3_next;
        ip_checksum_header4_reg <= ip_checksum_header4_next;
        ip_checksum_header5_reg <= ip_checksum_header5_next;
        ip_checksum_header6_reg <= ip_checksum_header6_next;
        ip_checksum_header7_reg <= ip_checksum_header7_next;
        ip_checksum_header8_reg <= ip_checksum_header8_next;
        ip_checksum_header9_reg <= ip_checksum_header9_next;
    end
end


xpm_fifo_sync #(
      .CASCADE_HEIGHT       (CASCADE_HEIGHT      ),       
      .DOUT_RESET_VALUE     (DOUT_RESET_VALUE    ),    
      .ECC_MODE             (ECC_MODE            ),     
      .FIFO_MEMORY_TYPE     (FIFO_MEMORY_TYPE    ),
      .FIFO_READ_LATENCY    (1                  ),   
      .FIFO_WRITE_DEPTH     (FIFO_WRITE_DEPTH    ),  
      .FULL_RESET_VALUE     (FULL_RESET_VALUE    ),     
      .PROG_EMPTY_THRESH    (PROG_EMPTY_THRESH   ),   
      .PROG_FULL_THRESH     (PROG_FULL_THRESH    ),   
      .RD_DATA_COUNT_WIDTH  (RD_DATA_COUNT_WIDTH ),  
      .READ_DATA_WIDTH      (56),   
      .READ_MODE            ("std"),        
      .SIM_ASSERT_CHK       (SIM_ASSERT_CHK      ),        
      .USE_ADV_FEATURES     (USE_ADV_FEATURES    ), 
      .WAKEUP_TIME          (WAKEUP_TIME         ),          
      .WRITE_DATA_WIDTH     (56),     
      .WR_DATA_COUNT_WIDTH  (WR_DATA_COUNT_WIDTH )    
)ip_header (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      .almost_full          (ip_header_alful),   
      .dout                 ({ip_header_idcode,ip_header_type,ip_header_length,ip_header_checksum}),      
      .empty                (ip_header_empty),                 
      .din                  (ip_header_din_reg),              
      .rd_en                (ip_header_rden_reg),               
      .rst                  (rst),                  
      .wr_clk               (clk),              
      .wr_en                (ip_header_wren_reg)           
);

//-------------------------------------------------------------------------------

localparam IP_SEND_IDLE = 7'b000_0001,
           IP_SEND_WAIT = 7'b000_0010,
           IP_SEND_DES0 = 7'b000_0100,
           IP_SEND_DES1 = 7'b000_1000, 
           IP_SEND_DES2 = 7'b001_0000,
           IP_SEND_DAT0 = 7'b010_0000,
           IP_SEND_DAT1 = 7'b100_0000; 
reg [6:0] ip_send_next, ip_send_reg = IP_SEND_IDLE;

reg [63:0] frame_tx_axis_tdata_init;
reg [7:0]  frame_tx_axis_tkeep_init;
reg        frame_tx_axis_tlast_init;
reg        frame_tx_axis_tvalid_init;
wire       frame_tx_axis_tready_init;

always @ * begin 
    ip_send_next = ip_send_reg;
    ip_header_rden_next = 1'b0;
    ip_payload_fifo_rden_next = 1'b0;

    frame_tx_axis_tdata_init  = 64'd0;
    frame_tx_axis_tkeep_init  = 8'd0;
    frame_tx_axis_tlast_init  = 1'b0;
    frame_tx_axis_tvalid_init = 1'b0;

    case(ip_send_reg)
        IP_SEND_IDLE : begin 
            if(~ip_header_empty) begin 
                ip_send_next = IP_SEND_WAIT;
                ip_header_rden_next = 1'b1;
            end
        end

        IP_SEND_WAIT : begin 
            ip_send_next = IP_SEND_DES0;
        end
        
        // IPv4 header word 0: version/IHL, TOS, total length, id, flags/frag
        IP_SEND_DES0 : begin 
            if(frame_tx_axis_tready_init) begin 
                frame_tx_axis_tdata_init[7:0]   = {ip_version, header_len};
                frame_tx_axis_tdata_init[15:8]  = 8'h00;
                frame_tx_axis_tdata_init[23:16] = ip_header_length[15:8];
                frame_tx_axis_tdata_init[31:24] = ip_header_length[7:0];
                frame_tx_axis_tdata_init[39:32] = ip_header_idcode[15:8];
                frame_tx_axis_tdata_init[47:40] = ip_header_idcode[7:0];
                frame_tx_axis_tdata_init[55:48] = 8'h40;
                frame_tx_axis_tdata_init[63:56] = 8'h00;

                frame_tx_axis_tkeep_init  = 8'hff;
                frame_tx_axis_tvalid_init = 1'b1;
                frame_tx_axis_tlast_init  = 1'b0;

                ip_send_next = IP_SEND_DES1;
            end
        end

        // IPv4 header word 1: TTL, protocol, header checksum, source address
        IP_SEND_DES1 : begin 
            if(frame_tx_axis_tready_init) begin 
                frame_tx_axis_tdata_init[7:0]   = TTL;
                frame_tx_axis_tdata_init[15:8]  = ip_header_type;
                frame_tx_axis_tdata_init[23:16] = ip_header_checksum[15:8];
                frame_tx_axis_tdata_init[31:24] = ip_header_checksum[7:0];
                frame_tx_axis_tdata_init[39:32] = src_ip_addr[31:24];
                frame_tx_axis_tdata_init[47:40] = src_ip_addr[23:16];
                frame_tx_axis_tdata_init[55:48] = src_ip_addr[15:8];
                frame_tx_axis_tdata_init[63:56] = src_ip_addr[7:0];

                frame_tx_axis_tkeep_init  = 8'hff;
                frame_tx_axis_tvalid_init = 1'b1;
                frame_tx_axis_tlast_init  = 1'b0;

                ip_send_next = IP_SEND_DES2;
            end            
        end

        // IPv4 header word 2: destination address + first 4 payload bytes.
        // Pop one payload word so dout_reg latches it for the 4-byte stagger.
        IP_SEND_DES2 : begin 
            if(frame_tx_axis_tready_init) begin 
                ip_payload_fifo_rden_next = 1'b1;
                frame_tx_axis_tdata_init[7:0]   = dst_ip_addr[31:24];
                frame_tx_axis_tdata_init[15:8]  = dst_ip_addr[23:16];
                frame_tx_axis_tdata_init[23:16] = dst_ip_addr[15:8];
                frame_tx_axis_tdata_init[31:24] = dst_ip_addr[7:0];
                frame_tx_axis_tdata_init[39:32] = ip_payload_fifo_dout[7:0];
                frame_tx_axis_tdata_init[47:40] = ip_payload_fifo_dout[15:8];
                frame_tx_axis_tdata_init[55:48] = ip_payload_fifo_dout[23:16];
                frame_tx_axis_tdata_init[63:56] = ip_payload_fifo_dout[31:24];

                frame_tx_axis_tvalid_init = 1'b1;
                if (ip_payload_fifo_dout[73] && (ip_payload_fifo_dout[71:68] == 4'h0)) begin
                    // single beat, payload ends within the lower 4 bytes
                    frame_tx_axis_tkeep_init = {ip_payload_fifo_dout[67:64], 4'hf};
                    frame_tx_axis_tlast_init = 1'b1;
                    ip_send_next = IP_SEND_IDLE;
                end
                else begin
                    frame_tx_axis_tkeep_init = 8'hff;
                    frame_tx_axis_tlast_init = 1'b0;
                    ip_send_next = ip_payload_fifo_dout[73] ? IP_SEND_DAT1 : IP_SEND_DAT0;
                end
            end              
        end

        // stream payload body: {prev[63:32], curr[31:0]}, one pop per beat
        IP_SEND_DAT0 : begin 
            if(frame_tx_axis_tready_init) begin 
                ip_payload_fifo_rden_next = 1'b1;
                frame_tx_axis_tdata_init[7:0]   = ip_payload_fifo_dout_reg[39:32];
                frame_tx_axis_tdata_init[15:8]  = ip_payload_fifo_dout_reg[47:40];
                frame_tx_axis_tdata_init[23:16] = ip_payload_fifo_dout_reg[55:48];
                frame_tx_axis_tdata_init[31:24] = ip_payload_fifo_dout_reg[63:56];
                frame_tx_axis_tdata_init[39:32] = ip_payload_fifo_dout[7:0];
                frame_tx_axis_tdata_init[47:40] = ip_payload_fifo_dout[15:8];
                frame_tx_axis_tdata_init[55:48] = ip_payload_fifo_dout[23:16];
                frame_tx_axis_tdata_init[63:56] = ip_payload_fifo_dout[31:24];

                frame_tx_axis_tvalid_init = 1'b1;
                if (ip_payload_fifo_dout[73] && (ip_payload_fifo_dout[71:68] == 4'h0)) begin
                    // last word ends within the lower 4 bytes: this is the tail beat
                    frame_tx_axis_tkeep_init = {ip_payload_fifo_dout[67:64], 4'hf};
                    frame_tx_axis_tlast_init = 1'b1;
                    ip_send_next = IP_SEND_IDLE;
                end
                else begin
                    frame_tx_axis_tkeep_init = 8'hff;
                    frame_tx_axis_tlast_init = 1'b0;
                    ip_send_next = ip_payload_fifo_dout[73] ? IP_SEND_DAT1 : IP_SEND_DAT0;
                end
            end    
        end

        // final half-word: {last[63:32], 0}, tkeep from the last word's upper nibble
        IP_SEND_DAT1 : begin 
            if(frame_tx_axis_tready_init) begin 
                frame_tx_axis_tdata_init[7:0]   = ip_payload_fifo_dout_reg[39:32];
                frame_tx_axis_tdata_init[15:8]  = ip_payload_fifo_dout_reg[47:40];
                frame_tx_axis_tdata_init[23:16] = ip_payload_fifo_dout_reg[55:48];
                frame_tx_axis_tdata_init[31:24] = ip_payload_fifo_dout_reg[63:56];
                frame_tx_axis_tdata_init[39:32] = 8'd0;
                frame_tx_axis_tdata_init[47:40] = 8'd0;
                frame_tx_axis_tdata_init[55:48] = 8'd0;
                frame_tx_axis_tdata_init[63:56] = 8'd0;

                frame_tx_axis_tkeep_init  = {4'h0, ip_payload_fifo_dout_reg[71:68]};
                frame_tx_axis_tvalid_init = 1'b1;
                frame_tx_axis_tlast_init  = 1'b1;

                ip_send_next = IP_SEND_IDLE;
            end
        end
        default:begin 
            ip_send_next = IP_SEND_IDLE;
        end
    endcase
end

always @(posedge clk)begin 
    if(rst)begin 
        ip_send_reg <= IP_SEND_IDLE;
        ip_header_rden_reg <= 1'b0;
    end else begin 
        ip_send_reg <= ip_send_next;
        ip_header_rden_reg <= ip_header_rden_next;
    end
end

//-------------------------------------------------------------------------------

localparam  OUTPUT_FIFO_ADDR_WIDTH = 9;

reg [63:0] frame_tx_axis_tdata_reg;
reg [7:0]  frame_tx_axis_tkeep_reg;
reg        frame_tx_axis_tlast_reg;
reg        frame_tx_axis_tvalid_reg;

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

assign frame_tx_axis_tready_init = !out_fifo_full;


always @(posedge clk) begin
    frame_tx_axis_tvalid_reg <= frame_tx_axis_tvalid_reg && !frame_tx_axis_tready;

    if (!out_fifo_full && frame_tx_axis_tvalid_init) begin
        out_fifo_wdata[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= frame_tx_axis_tdata_init;
        out_fifo_wstrb[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= frame_tx_axis_tkeep_init;
        out_fifo_eop[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]]   <= frame_tx_axis_tlast_init;     

        out_fifo_wr_ptr_reg <= out_fifo_wr_ptr_reg + 1;
    end

    if (!out_fifo_empty && (!frame_tx_axis_tvalid_reg || frame_tx_axis_tready)) begin
        frame_tx_axis_tdata_reg <= out_fifo_wdata[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        frame_tx_axis_tkeep_reg <= out_fifo_wstrb[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        frame_tx_axis_tlast_reg <= out_fifo_eop[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        frame_tx_axis_tvalid_reg <= 1'b1;
        out_fifo_rd_ptr_reg <= out_fifo_rd_ptr_reg + 1;
    end

    if (rst) begin
        out_fifo_wr_ptr_reg <= 0;
        out_fifo_rd_ptr_reg <= 0;
        frame_tx_axis_tvalid_reg <= 1'b0;
    end
end

assign frame_tx_axis_tdata = frame_tx_axis_tdata_reg;
assign frame_tx_axis_tkeep = frame_tx_axis_tkeep_reg;
assign frame_tx_axis_tlast = frame_tx_axis_tlast_reg;
assign frame_tx_axis_tvalid= frame_tx_axis_tvalid_reg;

endmodule

`resetall
