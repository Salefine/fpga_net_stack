/****************************************************************************
 * @file    icmp_tx_ack_10g.v
 * @brief  
 * @author  weslie (zzhi4832@gmail.com)
 * @version 1.0
 * @date    2025-01-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.0      |    weslie        | Support 100Gbps        |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2025 welie
 * ***************************************************************************/

`timescale 1ns/1ps

module icmp_tx#(
    // parameter   STACK_SPEED             =   100,
    parameter   ICMP_TX_TDATA_WIDTH     =   64,
    parameter   ICMP_TX_TKEEP_WIDTH     =   ICMP_TX_TDATA_WIDTH / 8,
    parameter   ICMP_TX_TOTAL_WIDTH     =   ICMP_TX_TDATA_WIDTH + ICMP_TX_TKEEP_WIDTH + 3
)(
    // input   wire    rx_axis_aclk        ,
    // input   wire    rx_axis_aresetn     ,
    input   wire    tx_axis_aclk        ,
    input   wire    tx_axis_aresetn     ,

    output  reg     icmp_not_empty      ,

    input   wire    [ICMP_TX_TDATA_WIDTH - 1 : 0]     icmp_rx_axis_tdata  ,
    input   wire    [ICMP_TX_TKEEP_WIDTH - 1 : 0]     icmp_rx_axis_tkeep  ,
    input   wire                                      icmp_rx_axis_tvalid ,
    input   wire                                      icmp_rx_axis_tlast  ,
    input   wire                                      icmp_rx_axis_tuser  ,
    output  wire                                      icmp_rx_axis_tready,

    output  reg     [ICMP_TX_TDATA_WIDTH - 1 : 0]     icmp_tx_axis_tdata  ,
    output  reg     [ICMP_TX_TKEEP_WIDTH - 1 : 0]     icmp_tx_axis_tkeep  ,
    output  reg                                       icmp_tx_axis_tvalid ,
    output  reg                                       icmp_tx_axis_tlast  ,
    input   wire                                      icmp_tx_axis_tready
    
);

reg                                   icmp_tx_fifo_wren =   0;
reg                                   icmp_tx_fifo_rden =   0;
reg     [ICMP_TX_TOTAL_WIDTH - 2 : 0] icmp_tx_fifo_din  =   0;
wire    [ICMP_TX_TOTAL_WIDTH - 2 : 0] icmp_tx_fifo_dout;
wire                                  icmp_tx_fifo_empty;

(* MARK_DEBUG="true" *)reg [3 : 0]  check_count    =   0;
(* MARK_DEBUG="true" *)reg [11: 0]  send_count     =   0;
(* MARK_DEBUG="true" *)reg [15 :0]  checksum_payload [0 : ICMP_TX_TKEEP_WIDTH / 2 - 1];
(* MARK_DEBUG="true" *)reg [15 :0]  checksum_tmpload [0 : ICMP_TX_TKEEP_WIDTH / 2 - 1];
(* MARK_DEBUG="true" *)reg [15 :0]  checksum         [0 : ICMP_TX_TKEEP_WIDTH / 2 - 1];


localparam  ICMP_TX_SEND_IDLE   =   4'b0001;
localparam  ICMP_TX_SEND_CHEK   =   4'b0010;
localparam  ICMP_TX_SEND_DATA   =   4'b1000;

(* MARK_DEBUG="true" *)reg    [3:0]    icmp_send_state     =   0;
(* MARK_DEBUG="true" *)reg    [3:0]    icmp_send_next_state=   0;

always @(posedge tx_axis_aclk) begin
    if (~tx_axis_aresetn) begin
        icmp_send_state <= ICMP_TX_SEND_IDLE;
    end
    else begin
        icmp_send_state <= icmp_send_next_state;
    end
end

always @(*) begin
    case (icmp_send_state)
        ICMP_TX_SEND_IDLE   : begin
            if (icmp_rx_axis_tlast & icmp_rx_axis_tvalid & icmp_rx_axis_tready) begin
                icmp_send_next_state = ICMP_TX_SEND_CHEK;
            end
            else begin
                icmp_send_next_state = ICMP_TX_SEND_IDLE;
            end
        end

        ICMP_TX_SEND_CHEK   : begin
            // Move straight to DATA: the first beat must be presented with
            // tvalid asserted BEFORE waiting for tready.  Waiting for tready
            // while tvalid is low deadlocks against an arbiter that only
            // grants (and therefore asserts tready) once it sees tvalid.
            if (check_count == 2) begin
                icmp_send_next_state = ICMP_TX_SEND_DATA;
            end
            else begin
                icmp_send_next_state = ICMP_TX_SEND_CHEK;
            end
        end

        ICMP_TX_SEND_DATA   : begin
            if (icmp_tx_axis_tlast & icmp_tx_axis_tvalid & icmp_tx_axis_tready) begin
                icmp_send_next_state  = ICMP_TX_SEND_IDLE;
            end
            else begin
                icmp_send_next_state  = ICMP_TX_SEND_DATA;
            end
        end

        default: begin
            icmp_send_next_state = ICMP_TX_SEND_IDLE;
        end
    endcase
end

integer     i;
integer     k;


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

/*********************************************************************
 * Echo reply header fields
 *
 * The reply differs from the request only in the type/code word
 * (0x0800 -> 0x0000) and in the checksum field. icmp_rx only forwards
 * requests whose checksum is correct (sum over the message = 0xffff),
 * so adding the type/code difference to the request checksum keeps the
 * reply correct as well: the sum over the reply message is 0xffff, too
 * (request 0x18ed -> reply 0x20ed).
 *********************************************************************/
wire    [15:0]  icmp_req_checksum    =   {icmp_tx_fifo_dout[31:24], icmp_tx_fifo_dout[39:32]};
wire    [15:0]  icmp_reply_checksum  =   checksum_gen(icmp_req_checksum, 16'h0800);

always @(posedge tx_axis_aclk) begin
    if (~tx_axis_aresetn) begin
        for (i = 0; i < ICMP_TX_TKEEP_WIDTH / 2 ; i = i + 1) begin
            checksum_tmpload[i] <= 0;
            checksum_payload[i] <= 0;
        end
    end
    else if (icmp_rx_axis_tlast & icmp_rx_axis_tvalid & icmp_rx_axis_tready) begin
        for(i = 0 ; i < ICMP_TX_TKEEP_WIDTH / 2 ; i = i + 1 )begin
            case ({icmp_rx_axis_tkeep[2 * i + 1],icmp_rx_axis_tkeep[2 * i]})
                2'b00 : begin
                    checksum_payload[i] <= checksum_tmpload[i];
                end
                2'b01 : begin
                    checksum_payload[i] <= checksum_gen(checksum_tmpload[i] , {{icmp_rx_axis_tdata[16 * i +: 8],8'h00}});
                end
                2'b11 : begin
                    checksum_payload[i] <= checksum_gen(checksum_tmpload[i] , {icmp_rx_axis_tdata[16 * i +: 8],icmp_rx_axis_tdata[16 * i + 8 +: 8]});
                end
                default: begin
                    checksum_payload[i] <= checksum_tmpload[i];
                end
            endcase
            checksum_tmpload[i] <= 0;
        end
    end
    else if(icmp_rx_axis_tvalid & icmp_rx_axis_tready & (~icmp_rx_axis_tlast))begin
        for (i = 0 ; i < ICMP_TX_TKEEP_WIDTH / 2 ; i = i + 1) begin
            checksum_tmpload[i] <= checksum_gen(checksum_tmpload[i], {icmp_rx_axis_tdata[i * 16 +: 8],icmp_rx_axis_tdata[16 * i + 8 +: 8]});
        end
    end
end

localparam ICMP_WIDTH = 64;                     // must be power of 2
localparam HALF_WIDTH = ICMP_WIDTH >> 1;        // 32
localparam STAGE_NUM  = $clog2(HALF_WIDTH);     // 5
//integer k;


always @(posedge tx_axis_aclk) begin
    if (~tx_axis_aresetn) begin
        for (i= 0; i < 32; i = i + 1)
            checksum[i] <= 0;
    end

    else if (icmp_send_state == ICMP_TX_SEND_CHEK) begin
        //stage 1
        for (k = 0; k < 2 ; k = k + 1) begin
            checksum[k] <= checksum_gen(checksum_payload[2 * k] , checksum_payload[2 * k + 1]);
        end

        checksum[2] <= checksum_gen(checksum[0] , checksum[1]);  

        check_count <= check_count + 1;
    end

    else if (icmp_send_state == ICMP_TX_SEND_IDLE) begin
        for (i = 0; i < 32 ; i = i + 1) begin
            checksum[i] <= 0;
        end
        check_count <= 0;
    end
end



wire    icmp_tx_fifo_alful;

// input backpressure: accept beats only while idle (one echo request at a
// time) and with room in the FIFO; the upstream icmp_rx holds its beats
// until this module has finished generating the previous reply.
assign icmp_rx_axis_tready = (icmp_send_state == ICMP_TX_SEND_IDLE) && ~icmp_tx_fifo_alful;

always @(posedge tx_axis_aclk) begin
    if (~tx_axis_aresetn) begin
        icmp_tx_fifo_wren <= 0;
        icmp_tx_fifo_din  <= 0;
    end
    else if(icmp_rx_axis_tvalid & icmp_rx_axis_tready)begin
        icmp_tx_fifo_wren <= 1;
        icmp_tx_fifo_din  <= {icmp_rx_axis_tvalid , icmp_rx_axis_tlast , icmp_rx_axis_tdata , icmp_rx_axis_tkeep};
    end
    else begin
        icmp_tx_fifo_wren <= 0;
        icmp_tx_fifo_din  <= 0;
    end
end

xpm_sync_fifo #(
    .WIDTH     	(ICMP_TX_TOTAL_WIDTH - 1),
    .DEPTH     	(11     ),
    .FIFO_TYPE 	("fwft" )
)icmp_tx_fifo(
    .clk         	(tx_axis_aclk       ),
    .rst         	(~tx_axis_aresetn   ),
    .wr_en        (icmp_tx_fifo_wren  ),
    .rd_en        (icmp_tx_fifo_rden  ),
    .data         (icmp_tx_fifo_din   ),
    .dout         (icmp_tx_fifo_dout  ),
    .full        	(),
    .empty       	(icmp_tx_fifo_empty),
    .almost_full 	(icmp_tx_fifo_alful)
);

reg     icmp_tx_fifo_wren_reg   =   0;

always @(posedge tx_axis_aclk) begin
    icmp_tx_fifo_wren_reg <= icmp_tx_fifo_wren;
end

always @(posedge tx_axis_aclk) begin
    if (~tx_axis_aresetn) begin
        icmp_not_empty <= 0;
    end
    else if(~icmp_tx_fifo_wren & icmp_tx_fifo_wren_reg)begin
        icmp_not_empty <= 1;
    end
    else begin
        icmp_not_empty <= 0;
    end
end

// Pop one FIFO word only when the beat currently on the output is accepted:
// with a stalled downstream (icmp_tx_axis_tready low) the FWFT head word is
// held on the output instead of being dropped.
always @(*) begin
    if (icmp_send_state == ICMP_TX_SEND_DATA) begin
        icmp_tx_fifo_rden = ~icmp_tx_fifo_empty && icmp_tx_axis_tready;
    end
    else begin
        icmp_tx_fifo_rden = 0;
    end
end


always @(*) begin

    if (icmp_send_state == ICMP_TX_SEND_DATA ) begin
        if (send_count == 0) begin
            icmp_tx_axis_tdata = {icmp_tx_fifo_dout[ICMP_TX_TKEEP_WIDTH + ICMP_TX_TDATA_WIDTH - 1 : ICMP_TX_TKEEP_WIDTH + 32], {icmp_reply_checksum[7:0],icmp_reply_checksum[15:8]},16'h0};
        end
        else begin
            icmp_tx_axis_tdata = icmp_tx_fifo_dout[ICMP_TX_TKEEP_WIDTH + ICMP_TX_TDATA_WIDTH - 1 : ICMP_TX_TKEEP_WIDTH];
        end

        icmp_tx_axis_tkeep = icmp_tx_fifo_dout[ICMP_TX_TKEEP_WIDTH-1 : 0];
        icmp_tx_axis_tvalid= icmp_tx_fifo_dout[ICMP_TX_TOTAL_WIDTH-2];
        icmp_tx_axis_tlast = icmp_tx_fifo_dout[ICMP_TX_TOTAL_WIDTH-3];
    end
    else begin
        icmp_tx_axis_tdata = 0;
        icmp_tx_axis_tkeep = 0;
        icmp_tx_axis_tlast = 0;
        icmp_tx_axis_tvalid= 0;
    end
end

always @(posedge tx_axis_aclk) begin
    if (~tx_axis_aresetn) begin
        send_count  <= 0;
    end
    else if (icmp_send_state != ICMP_TX_SEND_DATA) begin
        // reset between frames only; hold while the current beat is stalled
        // (tready low) so the first-beat patch stays on the first beat
        send_count <= 0;
    end
    else if (icmp_tx_fifo_rden) begin
        send_count <= send_count + 1;
    end
end


endmodule //icmp_tx_ack_10g