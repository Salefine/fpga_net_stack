/****************************************************************************
 * @file    udp_tx_100g.sv
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
`default_nettype wire

`include "define.svh"
`include "axis_if.sv"

module udp_tx_100g (
    input  logic [31:0]src_ip_addr,     //source ip address
    input  logic [31:0]dst_ip_addr,     //destination ip address
                                           
    input  logic [15:0]udp_src_port,    //udp source port
    input  logic [15:0]udp_dst_port,    //udp destination port

    input  logic configure_done,
          
	input  logic clk,
    input  logic rst,
	/* udp tx axis interface */		  
    axis_if.slave  app_tx_axis_if,
	/* tx axis interface to ip */
	axis_if.master udp_tx_axis_if  
);

logic udp_checksum_fifo_wren;
logic [15:0] udp_payload_length_reg      = 16'd0;
logic [15:0] udp_payload_length_temp_reg = 16'd0;

always_ff@(posedge clk)begin
    if (rst) begin
        udp_payload_length_reg      <= 16'd0;
        udp_payload_length_temp_reg <= 16'd0;
    end
    else if (app_tx_axis_if.tvalid && app_tx_axis_if.tready) begin
        if (app_tx_axis_if.tlast) begin
            // 当前帧最后一个数据拍成功握手
            // 输出完整帧长度，并清零当前帧累计长度
            udp_payload_length_reg <= udp_payload_length_temp_reg + count_valid_bytes(app_tx_axis_if.tkeep);
            udp_payload_length_temp_reg <= 16'd0;
        end
        else begin
            // 累计当前帧已传输的有效字节数
            udp_payload_length_temp_reg <= udp_payload_length_temp_reg + count_valid_bytes(app_tx_axis_if.tkeep);
        end
    end    
end


//------------------------------------------data cache--------------------------------------
localparam      WIDTH               = 512+64+2;	
localparam      DEPTH               = 8;   	
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

wire [WIDTH-1:0] udp_payload_init = {app_tx_axis_if.tlast,app_tx_axis_if.tvalid,app_tx_axis_if.tkeep,app_tx_axis_if.tdata};
wire udp_payload_fifo_alfull;
wire udp_payload_fifo_empty;
wire [WIDTH-1:0]udp_payload_fifo_dout;
wire udp_checksum_fifo_alful;

// accept payload beats while the frame buffer has space
assign app_tx_axis_if.tready = configure_done & ~udp_payload_fifo_alfull & 
                               ~udp_checksum_fifo_alful & ~udp_checksum_fifo_wren;

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
      .wr_en                (app_tx_axis_if.tready & app_tx_axis_if.tvalid)           
);

//------------------------------------------checksum cache--------------------------------------
logic [15:0] checksum_temp_load[0:31];
logic [15:0] checksum_payload[0:31];

always_ff @(posedge clk)begin
    if(rst)begin 
        for (integer i = 0; i < 32; i = i + 1) begin
            checksum_temp_load[i] <= 16'b0;
            checksum_payload[i] <= 16'b0;
        end
    end
    else if (app_tx_axis_if.tvalid & app_tx_axis_if.tready) begin
        if(app_tx_axis_if.tlast)begin
            for (integer k = 0; k < 32; k = k + 1) begin
                case ({app_tx_axis_if.tkeep[2*k+1],app_tx_axis_if.tkeep[2*k]})
                    2'b00: checksum_payload[k] <= checksum_temp_load[k];
                    2'b01: checksum_payload[k] <= calc_checksum(checksum_temp_load[k],
                                                {app_tx_axis_if.tdata[k*16+:8],8'b0});
                    2'b10: checksum_payload[k] <= calc_checksum(checksum_temp_load[k],
                                                {8'b0,app_tx_axis_if.tdata[k*16+:8]});
                    2'b11: checksum_payload[k] <= calc_checksum(checksum_temp_load[k],
                                                {app_tx_axis_if.tdata[k*16+:8], app_tx_axis_if.tdata[(k*2+1)*8+:8]});
                    default: checksum_payload[k] <= checksum_temp_load[k];
                endcase
            end
        end
        else begin 
            for (integer j = 0; j < 32; j = j + 1) begin
                checksum_temp_load[j] <= calc_checksum(checksum_temp_load[j],
                {app_tx_axis_if.tdata[j*16+:8],app_tx_axis_if.tdata[(j*2+1)*8+:8]});
            end
        end
    end
end

logic [511:0] udp_checksum_fifo_din;
logic [511:0] udp_checksum_fifo_dout;
logic udp_checksum_fifo_empty;
logic udp_checksum_fifo_rden_next;
logic [15:0] checksum_payload_length;

always_ff @(posedge clk) begin
    if (rst) begin
        udp_checksum_fifo_wren <= 'b0;
    end
    else begin
        udp_checksum_fifo_wren <= app_tx_axis_if.tvalid & app_tx_axis_if.tready & app_tx_axis_if.tlast;
    end
end

always_comb begin
    udp_checksum_fifo_din = {checksum_payload[31],checksum_payload[30],checksum_payload[29],checksum_payload[28],
                             checksum_payload[27],checksum_payload[26],checksum_payload[25],checksum_payload[24],
                             checksum_payload[23],checksum_payload[22],checksum_payload[21],checksum_payload[20],
                             checksum_payload[19],checksum_payload[18],checksum_payload[17],checksum_payload[16],
                             checksum_payload[15],checksum_payload[14],checksum_payload[13],checksum_payload[12],
                             checksum_payload[11],checksum_payload[10],checksum_payload[9] ,checksum_payload[8] ,
                             checksum_payload[7] ,checksum_payload[6] ,checksum_payload[5] ,checksum_payload[4] ,
                             checksum_payload[3] ,checksum_payload[2] ,checksum_payload[1] ,checksum_payload[0] };
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
      .READ_DATA_WIDTH      (512),   
      .READ_MODE            ("std"               ),        
      .SIM_ASSERT_CHK       (SIM_ASSERT_CHK      ),        
      .USE_ADV_FEATURES     (USE_ADV_FEATURES    ), 
      .WAKEUP_TIME          (WAKEUP_TIME         ),          
      .WRITE_DATA_WIDTH     (512),     
      .WR_DATA_COUNT_WIDTH  (5 )    
)udp_checksum_fifo (
      .sleep        (0            ), 
      .injectdbiterr(1'b0         ),
      .injectsbiterr(1'b0         ), 
      .almost_full  (udp_checksum_fifo_alful),   
      .dout  ({checksum_payload_length,udp_checksum_fifo_dout}),      
      .empty (udp_checksum_fifo_empty),                 
      .din   ({udp_payload_length_reg + 4'h8,udp_checksum_fifo_din}),              
      .rd_en (udp_checksum_fifo_rden_next),               
      .rst   (rst),                  
      .wr_clk(clk),              
      .wr_en (udp_checksum_fifo_wren)           
);

//--------------------------------------calcute checksum------------------------

typedef enum logic [6:0]{
    IDLE = 7'b0000001,
    WAIT = 7'b0000010,
    CAL0 = 7'b0000100,
    CAL1 = 7'b0001000,
    CAL2 = 7'b0010000,
    CAL3 = 7'b0100000,
    CAL4 = 7'b1000000
}cks_state_t;

cks_state_t cks_state_reg, cks_state_next;

logic [15:0] checksum_header0_next, checksum_header0_reg = 'b0;
logic [15:0] checksum_header1_next, checksum_header1_reg = 'b0;
logic [15:0] checksum_header2_next, checksum_header2_reg = 'b0;
logic [15:0] checksum_header3_next, checksum_header3_reg = 'b0;
logic [15:0] checksum_header4_next, checksum_header4_reg = 'b0;
logic [15:0] checksum_header5_next, checksum_header5_reg = 'b0;
logic [15:0] checksum_header6_next, checksum_header6_reg = 'b0;
logic [15:0] checksum_header7_next, checksum_header7_reg = 'b0;
logic [15:0] checksum_header8_next, checksum_header8_reg = 'b0;
logic [15:0] checksum_header9_next, checksum_header9_reg = 'b0;
logic [15:0] checksum_header10_next, checksum_header10_reg = 'b0;
logic [15:0] checksum_header11_next, checksum_header11_reg = 'b0;
logic [15:0] checksum_header12_next, checksum_header12_reg = 'b0;
logic [15:0] checksum_payload_t_next[0:31];
logic [15:0] checksum_payload_t_reg[0:31];
logic [15:0] checksum_payload_next,checksum_payload_reg='b0;

logic [15:0] checksum_payload_next, checksum_payload_reg   = 0;
logic  udp_desc_fifo_wr_next,udp_desc_fifo_wr_reg = 'b0;
logic [31:0] udp_desc_fifo_din = 'b0;
logic udp_desc_dout_rden_next, udp_desc_dout_rden_reg = 'b0;
logic udp_desc_fifo_empty;
logic [15:0] udp_desc_fifo_length,udp_desc_fifo_checksum;
logic [4:0] udp_desc_fifo_count; 

always_comb begin
    cks_state_next = cks_state_reg;
    udp_checksum_fifo_rden_next = 'b0;
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
    checksum_header9_next = checksum_header9_reg;
    checksum_header10_next = checksum_header10_reg;

    checksum_payload_next = checksum_payload_reg;
    for (integer i = 0; i < 32 ; i++) begin
        checksum_payload_t_next[i] = checksum_payload_t_reg[i];
    end

    case (cks_state_reg)
        IDLE: begin
            if (~udp_checksum_fifo_empty & (udp_desc_fifo_count < 16'd12)) begin
                cks_state_next = WAIT;
                udp_checksum_fifo_rden_next = 1'b1;
            end
            else begin
                udp_checksum_fifo_rden_next = 1'b0;
            end
        end

        WAIT: begin
            //------------------------------- payload----------------------------//
            for (integer k = 0; k < 16; k++) begin
                checksum_payload_t_next[k] = calc_checksum(udp_checksum_fifo_dout[(2*k)*16 +: 16], 
                                                           udp_checksum_fifo_dout[(k*2+1)*16+:16]);
            end
            //------------------------------header-------------------------------//
            checksum_header0_next = calc_checksum(src_ip_addr[15:0]  , src_ip_addr[31:16]);
            checksum_header1_next = calc_checksum(dst_ip_addr[15:0]  , dst_ip_addr[31:16]);
            checksum_header2_next = calc_checksum({8'h0000, 8'd17}  , checksum_payload_length);
            checksum_header3_next = calc_checksum(udp_src_port , udp_dst_port);  
            checksum_header4_next = checksum_payload_length;
            cks_state_next = CAL0;       
        end

        CAL0: begin
            //------------------------------- payload----------------------------//
            for (integer k = 16; k < 24 ; k++) begin
                checksum_payload_t_next[k] = calc_checksum(checksum_payload_t_reg[2*(k-16)], 
                                                           checksum_payload_t_reg[2*(k-16)+1]);
            end
            //------------------------------- header----------------------------//
            checksum_header5_next = calc_checksum(checksum_header0_reg , checksum_header1_reg);
            checksum_header6_next = calc_checksum(checksum_header2_reg , checksum_header3_reg);
            checksum_header7_next = checksum_header4_reg;
            cks_state_next = CAL1;                
        end

        CAL1: begin
            //------------------------------- payload----------------------------//
            for (integer k = 24; k < 28 ; k++) begin
                checksum_payload_t_next[k] = 
                    calc_checksum(
                        checksum_payload_t_reg[2*(k-24)+16], 
                        checksum_payload_t_reg[2*(k-24)+17]
                    );
            end
            //------------------------------- header----------------------------//
            checksum_header8_next = calc_checksum(checksum_header5_reg , checksum_header6_reg);
            checksum_header9_next = checksum_header7_reg;
            cks_state_next = CAL2;       
        end

        CAL2: begin
            //------------------------------- payload----------------------------//
            for (integer k = 28; k < 30; k++) begin
                checksum_payload_t_next[k] =
                    calc_checksum(
                        checksum_payload_t_reg[2*(k-28)+24],
                        checksum_payload_t_reg[2*(k-28)+25]
                    );
            end
            //------------------------------- header----------------------------//
            checksum_header10_next = calc_checksum(checksum_header8_reg , checksum_header9_reg);
            cks_state_next = CAL3;              
        end

        CAL3: begin
            //------------------------------- payload----------------------------//
            for (integer k = 30; k < 31; k++) begin
                checksum_payload_t_next[k] =
                    calc_checksum(
                        checksum_payload_t_reg[28],
                        checksum_payload_t_reg[29]
                    );
            end
            //------------------------------- header----------------------------//
            checksum_header11_next = checksum_header10_reg;
            cks_state_next = CAL4;          
        end

        CAL4: begin
            checksum_payload_next = calc_checksum(checksum_header11_reg,checksum_payload_t_reg[30]);
        end
        default:begin end
    endcase
end

always_ff @(posedge clk) begin
    if (rst) begin
        cks_state_reg <= IDLE;


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
      .dout                 ({udp_desc_fifo_length,udp_desc_fifo_checksum}),      
      .empty                (udp_desc_fifo_empty),     
      .wr_data_count        (udp_desc_fifo_count),
      .din                  ({checksum_payload_length,checksum_payload_reg}),              
      .rd_en                (udp_desc_dout_rden_reg),               
      .rst                  (rst),                  
      .wr_clk               (clk),              
      .wr_en                (udp_desc_fifo_wr_reg)           
);


axis_if.master udp_tx_axis_init;

typedef enum logic [4:0]{
    IDLE = 5'b00001,
    WAIT = 5'b00010,
    DAT0 = 5'b00100,
    DAT1 = 5'b01000,
    DAT2 = 5'b10000
}tx_state_t;

tx_state_t tx_state_next,tx_state_reg=IDLE;
logic fifo_tdata  = udp_payload_fifo_dout[511:0];
logic fifo_tkeep  = udp_payload_fifo_dout[575:512];
logic fifo_tvalid = udp_payload_fifo_dout[576];
logic fifo_tlast  = udp_payload_fifo_dout[577];

logic fifo_tdata_reg = 'b0  
logic fifo_tkeep_reg = 'b0; 
logic fifo_tvalid_reg= 'b0;   
logic fifo_tlast_reg = 'b0;  

always_comb begin 
    udp_tx_axis_init.tvalid = 0;
    udp_tx_axis_init.tdata = 0;
    udp_tx_axis_init.tlast = 0;
    udp_tx_axis_init.tkeep = 0;

    udp_desc_dout_rden_next = 'b0;
    udp_payload_fifo_rden_next = 'b0;

    tx_state_next = tx_state_reg;

    case(tx_state_reg)
        IDLE : begin 
            if (~udp_desc_fifo_empty) begin
                tx_state_next = WAIT;
                udp_desc_dout_rden_next = 1'b1;
            end else begin
                tx_state_next = IDLE;
            end
        end

        // wait for downstream ready and payload availability; desc
        // length/checksum are already valid in this state
        WAIT : begin 
            if (udp_tx_axis_init.tready && !udp_payload_fifo_empty) begin
                tx_state_next = DAT0;
            end else begin
                tx_state_next = WAIT;
            end
        end

        DAT0 : begin 
            udp_tx_axis_init.tdata[63:0] = {
                udp_desc_fifo_checksum[7:0], udp_desc_fifo_checksum[15:8],
                udp_desc_fifo_length[7:0],   udp_desc_fifo_length[15:8],
                udp_dst_port[7:0],           udp_dst_port[15:8],
                udp_src_port[7:0],           udp_src_port[15:8]                
            }
            udp_tx_axis_init.tkeep[7:0] = 8'hff;
            udp_tx_axis_init.tvalid = 1'b1;
            if(~|fifo_tkeep[63:56] & fifo_tlast)begin 
                udp_tx_axis_init.tdata[511:8] = fifo_tdata[447:0];
                udp_tx_axis_init.tkeep[63:8] = fifo_tkeep[55:0];
                udp_tx_axis_init.tlast = 1'b1;
                tx_state_next = IDLE;
            end else begin 
                udp_tx_axis_init.tdata[511:8] = fifo_tdata[447:0];
                udp_tx_axis_init.tkeep[63:8] = fifo_tkeep[55:0];
                udp_tx_axis_init.tlast = 1'b0;
                tx_state_next = IDLE;
            end
            
        end

        DAT1 : begin 

        end

        DAT2 : begin 

        end
    endcase
end

always_ff @(posedge clk) begin
    if (rst) begin
        ip_state_reg <= IP_PACKET_IDLE;
        udp_desc_dout_rden_reg <= 'b0;

        fifo_tdata_reg <= 'b0;
        
    end else begin
        ip_state_reg <= ip_state_next;
        udp_desc_dout_rden_reg <= udp_desc_dout_rden_next;

        fifo_tdata_reg <= fifo_tdata_next;
    end
end

//-------------------------------------------------------------------------------

localparam  OUTPUT_FIFO_ADDR_WIDTH = 8;


axis_if.master udp_tx_axis_reg;

(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
logic [63:0] out_fifo_wdata[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
logic [7:0]  out_fifo_wstrb[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
logic                      out_fifo_eop[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];

logic [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_wr_ptr_reg = 0;
logic [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_rd_ptr_reg = 0;

logic out_fifo_full = out_fifo_wr_ptr_reg == (out_fifo_rd_ptr_reg ^ {1'b1, {OUTPUT_FIFO_ADDR_WIDTH{1'b0}}});
logic out_fifo_empty = out_fifo_wr_ptr_reg == out_fifo_rd_ptr_reg;

assign udp_tx_axis_init.tready = !out_fifo_full;


always_ff @(posedge clk) begin
    udp_tx_axis_reg.tvalid  <= udp_tx_axis_reg.tvalid  && !udp_tx_axis_if.tready;

    if (!out_fifo_full && udp_tx_axis_init.tvalid) begin
        out_fifo_wdata[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= udp_tx_axis_init.tdata;
        out_fifo_wstrb[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= udp_tx_axis_init.tkeep;
        out_fifo_eop[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]]   <= udp_tx_axis_init.tlast;     

        out_fifo_wr_ptr_reg <= out_fifo_wr_ptr_reg + 1;
    end

    if (!out_fifo_empty && (!udp_tx_axis_reg.tvalid || udp_tx_axis_if.tready)) begin
        udp_tx_axis_reg.tdata <= out_fifo_wdata[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        udp_tx_axis_reg.tkeep <= out_fifo_wstrb[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        udp_tx_axis_reg.tlast <= out_fifo_eop[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        udp_tx_axis_reg.tvalid <= 1'b1;
        out_fifo_rd_ptr_reg <= out_fifo_rd_ptr_reg + 1;
    end

    if (rst) begin
        out_fifo_wr_ptr_reg <= 0;
        out_fifo_rd_ptr_reg <= 0;
        udp_tx_axis_reg.tvalid <= 1'b0;
    end
end

assign udp_tx_axis_if.tdata  = udp_tx_axis_reg.tdata;
assign udp_tx_axis_if.tkeep  = udp_tx_axis_reg.tkeep;
assign udp_tx_axis_if.tvalid = udp_tx_axis_reg.tvalid;
assign udp_tx_axis_if.tlast  = udp_tx_axis_reg.tlast;

endmodule

`resetall