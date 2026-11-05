/****************************************************************************
 * @file    icmp_rx.v
 * @brief  
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.0
 * @date    2025-01-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.0      |    zzhi          | icmp receive           |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2025 zzhi
 * ***************************************************************************/

`timescale 1ns/1ps

module icmp_rx#(
    parameter   ICMP_RX_TDATA_WIDTH     =   64,
    parameter   ICMP_RX_TKEEP_WIDTH     =   ICMP_RX_TDATA_WIDTH / 8,
    parameter   ICMP_RX_TOTAL_WIDTH     =   ICMP_RX_TDATA_WIDTH + ICMP_RX_TKEEP_WIDTH + 3
)(
    input   wire    rx_axis_aclk,
    input   wire    rx_axis_aresetn,

    input   [ICMP_RX_TDATA_WIDTH - 1 : 0]ip_rx_axis_tdata,
    input   [ICMP_RX_TKEEP_WIDTH - 1 : 0]ip_rx_axis_tkeep,
    input   wire                         ip_rx_axis_tvalid,
    input   wire                         ip_rx_axis_tlast,
    input   wire                         ip_rx_axis_tuser,
    output  wire                         ip_rx_axis_tready,

    // output  reg                         icmp_not_empty,

    output reg[ICMP_RX_TDATA_WIDTH - 1 : 0]icmp_rx_axis_tdata,
    output reg[ICMP_RX_TKEEP_WIDTH - 1 : 0]icmp_rx_axis_tkeep,
    output  reg                        icmp_rx_axis_tvalid,
    output  reg                        icmp_rx_axis_tlast,
    output  reg                        icmp_rx_axis_tuser,
    input   wire                        icmp_rx_axis_tready
);

reg [3:0]   checksum_count = 0;
reg [15:0]  checksum_payload [0 : ICMP_RX_TKEEP_WIDTH / 2 - 1];
reg [15:0]  checksum_tmpload [0 : ICMP_RX_TKEEP_WIDTH / 2 - 1];
reg [15:0]  checksum         [0 : ICMP_RX_TKEEP_WIDTH / 2 - 1];

integer i;

reg     icmp_payload_wren   =   0;
wire    icmp_payload_rden   ;
wire    icmp_payload_empty       ;
wire    [ICMP_RX_TOTAL_WIDTH - 1 : 0] icmp_payload_dout;
reg     [ICMP_RX_TOTAL_WIDTH - 1 : 0] icmp_payload_din = 0;
/*********************************************************************
 * 1. state machine for receiving icmp data packet
 *********************************************************************/

localparam  RECV_HEADER     =   7'b0000001;
localparam  RECV_DATA       =   7'b0000010;
localparam  RECV_GOOD       =   7'b0000100;
localparam  RECV_FAIL       =   7'b0001000;
localparam  SEND_HEADER     =   7'b0010000;
localparam  SEND_DATA       =   7'b0100000;
localparam  FRAME_BAD       =   7'b1000000;

reg    [6:0]    icmp_recv_state     =   0;
reg    [6:0]    icmp_recv_next_state=   0;

always @(posedge rx_axis_aclk) begin
    if (~rx_axis_aresetn) begin
        icmp_recv_state <= RECV_HEADER;
    end
    else begin
        icmp_recv_state <= icmp_recv_next_state;
    end
end

always @(*) begin
    case (icmp_recv_state)
        RECV_HEADER: begin
            if (ip_rx_axis_tvalid & ip_rx_axis_tready & (~ip_rx_axis_tlast)) begin
                icmp_recv_next_state = RECV_DATA;
            end
            else if (ip_rx_axis_tvalid & ip_rx_axis_tready & ip_rx_axis_tlast) begin
                if (~ip_rx_axis_tuser) begin
                    icmp_recv_next_state = RECV_GOOD;
                end
                else begin
                    icmp_recv_next_state = RECV_FAIL;
                end
            end
            else begin
                icmp_recv_next_state = RECV_HEADER;
            end
        end

        RECV_DATA : begin
            if (ip_rx_axis_tvalid & ip_rx_axis_tready & ip_rx_axis_tlast & (~ip_rx_axis_tuser)) begin
                icmp_recv_next_state = RECV_GOOD;
            end
            else if (ip_rx_axis_tvalid & ip_rx_axis_tready & ip_rx_axis_tlast & (ip_rx_axis_tuser)) begin
                icmp_recv_next_state = RECV_FAIL;
            end
            else begin
                icmp_recv_next_state = RECV_DATA;
            end                
        end

        RECV_GOOD : begin
           if ((checksum_count == 2) && checksum[2] == 16'hffff) begin
                icmp_recv_next_state = SEND_HEADER; 
           end
           else if ((checksum_count == 2) && (checksum[2] != 16'hffff)) begin
                icmp_recv_next_state = FRAME_BAD;
           end
           else begin
                icmp_recv_next_state = RECV_GOOD;
           end
        end

        RECV_FAIL : begin
            icmp_recv_next_state = FRAME_BAD;
        end

        SEND_HEADER : begin
            icmp_recv_next_state = SEND_DATA;
        end

        SEND_DATA : begin
            if (icmp_rx_axis_tvalid & icmp_rx_axis_tlast & icmp_rx_axis_tready) begin
                icmp_recv_next_state = RECV_HEADER;
            end
            else begin
                icmp_recv_next_state = SEND_DATA;
            end            
        end

        FRAME_BAD : begin
            if (icmp_payload_empty) begin
                icmp_recv_next_state = RECV_HEADER;
            end
            else begin
                icmp_recv_next_state = FRAME_BAD;
            end
        end
        default: begin
            icmp_recv_next_state = RECV_HEADER;
        end
    endcase
end

wire    icmp_payload_alful;
// input backpressure: accept beats only while a frame is being parsed and
// the payload FIFO has room.  Beats of a following frame are held off until
// the current reply has been fully handed to icmp_tx, which keeps the FSM
// and the FIFO strictly frame-aligned.
assign ip_rx_axis_tready = ((icmp_recv_state == RECV_HEADER) || (icmp_recv_state == RECV_DATA))
                           && ~icmp_payload_alful;

always @(posedge rx_axis_aclk) begin
    if (~rx_axis_aresetn) begin
        icmp_payload_wren <= 0;
        icmp_payload_din  <= 0;
    end
    else if (ip_rx_axis_tvalid & ip_rx_axis_tready) begin
        icmp_payload_wren <= 1;
        icmp_payload_din  <= {ip_rx_axis_tlast,ip_rx_axis_tuser,ip_rx_axis_tvalid,ip_rx_axis_tdata,ip_rx_axis_tkeep};
    end
    else begin
        icmp_payload_wren <= 0;
        icmp_payload_din  <= 0;
    end
end

// xpm_sync_fifo #(
//     .WIDTH     	(ICMP_RX_TOTAL_WIDTH),
//     .DEPTH     	(11                 ),
//     .FIFO_TYPE 	("fwft"             )
// )
// icmp_payload(
//     .clk         	(rx_axis_aclk           ),
//     .rst         	(~rx_axis_aresetn       ),
//     .wr_en        (icmp_payload_wren      ),
//     .rd_en        (icmp_payload_rden      ),
//     .data         (icmp_payload_din       ),
//     .dout         (icmp_payload_dout      ),
//     .full        	(                       ),
//     .empty       	(icmp_payload_empty     ),
//     .almost_full 	(icmp_payload_alful     )
// );


localparam      FIFO_MEMORY         = "auto";
localparam      USER_ADV_FEATURES   = "1f1f";
localparam      CASCADE_HEIGHT      = 0;
localparam      DOUT_RESET_VALUE    = "0";
localparam      ECC_MODE            = (FIFO_MEMORY == "auto") ? "no_ecc" : "en_ecc";
localparam      FIFO_MEMORY_TYPE    = FIFO_MEMORY;
localparam      FULL_RESET_VALUE    = 0;
localparam      PROG_EMPTY_THRESH   = 10;
localparam      PROG_FULL_THRESH    = 10;
localparam      SIM_ASSERT_CHK      = 1;
localparam      USE_ADV_FEATURES    = USER_ADV_FEATURES;
localparam      WAKEUP_TIME         = (FIFO_MEMORY_TYPE == "auto") ? 0 : 2;


xpm_fifo_sync #(
      .CASCADE_HEIGHT       (CASCADE_HEIGHT      ),       
      .DOUT_RESET_VALUE     (DOUT_RESET_VALUE    ),    
      .ECC_MODE             (ECC_MODE            ),     
      .FIFO_MEMORY_TYPE     (FIFO_MEMORY_TYPE    ),
      .FIFO_READ_LATENCY    (1),   
      .FIFO_WRITE_DEPTH     (128), 
      .FULL_RESET_VALUE     (FULL_RESET_VALUE    ),     
      .PROG_EMPTY_THRESH    (PROG_EMPTY_THRESH   ),   
      .PROG_FULL_THRESH     (PROG_FULL_THRESH    ),   
      .RD_DATA_COUNT_WIDTH  (5 ),  
      .READ_DATA_WIDTH      (ICMP_RX_TOTAL_WIDTH),   
      .READ_MODE            ("fwft"              ),        
      .SIM_ASSERT_CHK       (SIM_ASSERT_CHK      ),        
      .USE_ADV_FEATURES     (USE_ADV_FEATURES    ), 
      .WAKEUP_TIME          (WAKEUP_TIME         ),          
      .WRITE_DATA_WIDTH     (ICMP_RX_TOTAL_WIDTH),     
      .WR_DATA_COUNT_WIDTH  (5 )    
)icmp_fifo (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      .almost_full          (icmp_payload_alful),   
      .dout                 (icmp_payload_dout),      
      .empty                (icmp_payload_empty),     
      .wr_data_count        (icmp_payload_count),
      .din                  (icmp_payload_din),
      .rd_en                (icmp_payload_rden),               
      .rst                  (~rx_axis_aresetn),                  
      .wr_clk               (rx_axis_aclk),              
      .wr_en                (icmp_payload_wren)
);


/***********************************************************************
 * Calculate the checksum for the received icmp data packets
 ***********************************************************************/
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

always @(posedge rx_axis_aclk) begin
    if (~rx_axis_aresetn) begin
        for (i = 0; i < ICMP_RX_TKEEP_WIDTH/2; i = i + 1) begin
            checksum_tmpload[i]  <= 0;
            checksum_payload[i]  <= 0;         
        end
    end
    else if (ip_rx_axis_tvalid & ip_rx_axis_tready) begin
        if (ip_rx_axis_tlast) begin
            for(i = 0 ; i < ICMP_RX_TKEEP_WIDTH/2 ; i = i + 1 )begin
                case ({ip_rx_axis_tkeep[2 * i + 1],ip_rx_axis_tkeep[2 * i]})
                    2'b00 : begin
                        checksum_payload[i] <= checksum_tmpload[i];
                    end
                    2'b01 : begin
                        checksum_payload[i] <= checksum_gen(checksum_tmpload[i] , {{ip_rx_axis_tdata[16 * i +: 8],8'h00}});
                    end
                    2'b11 : begin
                        checksum_payload[i] <= checksum_gen(checksum_tmpload[i] , {ip_rx_axis_tdata[16 * i +: 8],ip_rx_axis_tdata[16 * i + 8 +: 8]});
                    end
                    default: begin
                        checksum_payload[i] <= checksum_tmpload[i];
                    end
                endcase
                checksum_tmpload[i] <= 0;
            end
        end
        else begin
            for (i = 0; i < ICMP_RX_TKEEP_WIDTH/2 ; i = i + 1 ) begin
                checksum_tmpload[i] <= checksum_gen(
                    checksum_tmpload[i],
                    {ip_rx_axis_tdata[16 * i +: 8] , ip_rx_axis_tdata[16 * i + 8 +: 8]}
                );
            end
        end
    end
end

/************************************************************************
 *The five-layer additive tree alleviates timing pressure and 
 * is used to calculate the final 16-bit checksum
 ***********************************************************************/
localparam HALF_WIDTH = ICMP_RX_TKEEP_WIDTH >> 1;
localparam STAGE_NUM  = $clog2(HALF_WIDTH - 1);
//integer k;

always @(posedge rx_axis_aclk) begin
    if (~rx_axis_aresetn) begin
        for (i = 0; i < 32; i = i + 1)
            checksum[i] <= 0;
    end
    else if (icmp_recv_state == RECV_GOOD) begin
        //stage 1  0~15
        for (i = 0; i < 2 ; i = i + 1) begin
            checksum[i]     <= checksum_gen(checksum_payload[2 * i], checksum_payload[2 * i + 1]);
        end

        for (i = 0; i < 1 ; i = i + 1) begin
            checksum[2]     <= checksum_gen(checksum[0], checksum[1]);
        end       
        
        checksum_count <= checksum_count + 1;

    end
    else if (icmp_recv_state == RECV_HEADER) begin
        for (i = 0; i < HALF_WIDTH; i = i + 1)
            checksum[i] <= 0;

        checksum_count <= 0;
    end
end

/*********************************************************************
 * 3. build icmp reply data's packet
 *********************************************************************/


// Output stage with valid/ready handshake: pop the next FIFO word only when
// the output register is free (empty, or its beat is being consumed this
// cycle); a stalled consumer (icmp_rx_axis_tready low) holds the beat instead
// of dropping it.
wire icmp_rx_axis_fire = icmp_rx_axis_tvalid && icmp_rx_axis_tready;

wire icmp_payload_pop_data = (icmp_recv_state == SEND_DATA) && ~icmp_payload_empty
                             && (~icmp_rx_axis_tvalid || icmp_rx_axis_tready);

assign  icmp_payload_rden = icmp_payload_pop_data
                         || ((icmp_recv_state == FRAME_BAD) && ~icmp_payload_empty);

always @(posedge rx_axis_aclk) begin
    if (~rx_axis_aresetn) begin
        icmp_rx_axis_tdata  <=  0;
        icmp_rx_axis_tkeep  <=  0;
        icmp_rx_axis_tlast  <=  0;
        icmp_rx_axis_tvalid <=  0; 
        icmp_rx_axis_tuser  <=  0;       
    end
    else if (icmp_payload_pop_data) begin
        icmp_rx_axis_tdata <= icmp_payload_dout[ICMP_RX_TDATA_WIDTH + ICMP_RX_TKEEP_WIDTH - 1: ICMP_RX_TKEEP_WIDTH];
        icmp_rx_axis_tkeep <= icmp_payload_dout[ICMP_RX_TKEEP_WIDTH - 1 : 0];
        icmp_rx_axis_tlast <= icmp_payload_dout[ICMP_RX_TOTAL_WIDTH - 1];
        icmp_rx_axis_tuser <= icmp_payload_dout[ICMP_RX_TOTAL_WIDTH - 2];
        icmp_rx_axis_tvalid<= icmp_payload_dout[ICMP_RX_TOTAL_WIDTH - 3];
    end
    else if (icmp_rx_axis_fire) begin
        icmp_rx_axis_tvalid <=  0;
    end
end
      

endmodule //icmp_rx_req_10g