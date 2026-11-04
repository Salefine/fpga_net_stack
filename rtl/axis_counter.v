/****************************************************************************
 * @file    axis_counter_contiguous.v
 * @brief   AXI-Stream Packet Length Counter for contiguous tkeep patterns
 * @author  (Based on weslie's design)
 * @version 1.0
 * @date    2025-01-26
 * 
 * @par Description:
 * This module handles cases where tkeep has contiguous 1's from LSB
 * Example: 64'h0000000000000001, 64'h0000000000000003, 64'h0000000000000007, etc.
 * ================================================================
 ****************************************************************************/

`timescale 1ns/1ps

module axis_counter #(
    parameter integer AXIS_DATA_WIDTH = 512,
    parameter integer TKEEP_WIDTH     = AXIS_DATA_WIDTH / 8
)(
    input  wire                      axis_aclk,
    input  wire                      axis_aresetn,
    input  wire                      axis_tvalid,
    input  wire                      axis_tready,
    input  wire [AXIS_DATA_WIDTH-1:0] axis_tdata,
    input  wire                      axis_tlast,
    input  wire [TKEEP_WIDTH-1:0]    axis_tkeep,
    output reg  [15:0]               packet_len_bytes
);

    //------------------------------------------------------------
    // Byte count based on contiguous tkeep pattern matching
    // Only patterns with consecutive 1's from LSB are considered
    //------------------------------------------------------------
    reg [15:0] valid_bytes;
    
    always @(*) begin
        case (axis_tkeep)
            // 1 byte (all 1-bit patterns)
            64'h0000000000000001: valid_bytes = 16'd1;  // 1'b1
            
            // 2 bytes
            64'h0000000000000003: valid_bytes = 16'd2;  // 2'b11
            
            // 3 bytes
            64'h0000000000000007: valid_bytes = 16'd3;  // 3'b111
            
            // 4 bytes
            64'h000000000000000F: valid_bytes = 16'd4;  // 4'b1111
            
            // 5 bytes
            64'h000000000000001F: valid_bytes = 16'd5;  // 5'b11111
            
            // 6 bytes
            64'h000000000000003F: valid_bytes = 16'd6;  // 6'b111111
            
            // 7 bytes
            64'h000000000000007F: valid_bytes = 16'd7;  // 7'b1111111
            
            // 8 bytes
            64'h00000000000000FF: valid_bytes = 16'd8;  // 8'b11111111
            
            // 9 bytes
            64'h00000000000001FF: valid_bytes = 16'd9;  // 9'b111111111
            
            // 10 bytes
            64'h00000000000003FF: valid_bytes = 16'd10; // 10'b1111111111
            
            // 11 bytes
            64'h00000000000007FF: valid_bytes = 16'd11; // 11'b11111111111
            
            // 12 bytes
            64'h0000000000000FFF: valid_bytes = 16'd12; // 12'b111111111111
            
            // 13 bytes
            64'h0000000000001FFF: valid_bytes = 16'd13; // 13'b1111111111111
            
            // 14 bytes
            64'h0000000000003FFF: valid_bytes = 16'd14; // 14'b11111111111111
            
            // 15 bytes
            64'h0000000000007FFF: valid_bytes = 16'd15; // 15'b111111111111111
            
            // 16 bytes
            64'h000000000000FFFF: valid_bytes = 16'd16; // 16'b1111111111111111
            
            // 17 bytes
            64'h000000000001FFFF: valid_bytes = 16'd17; // 17'b11111111111111111
            
            // 18 bytes
            64'h000000000003FFFF: valid_bytes = 16'd18; // 18'b111111111111111111
            
            // 19 bytes
            64'h000000000007FFFF: valid_bytes = 16'd19; // 19'b1111111111111111111
            
            // 20 bytes
            64'h00000000000FFFFF: valid_bytes = 16'd20; // 20'b11111111111111111111
            
            // 21 bytes
            64'h00000000001FFFFF: valid_bytes = 16'd21; // 21'b111111111111111111111
            
            // 22 bytes
            64'h00000000003FFFFF: valid_bytes = 16'd22; // 22'b1111111111111111111111
            
            // 23 bytes
            64'h00000000007FFFFF: valid_bytes = 16'd23; // 23'b11111111111111111111111
            
            // 24 bytes
            64'h0000000000FFFFFF: valid_bytes = 16'd24; // 24'b111111111111111111111111
            
            // 25 bytes
            64'h0000000001FFFFFF: valid_bytes = 16'd25; // 25'b1111111111111111111111111
            
            // 26 bytes
            64'h0000000003FFFFFF: valid_bytes = 16'd26; // 26'b11111111111111111111111111
            
            // 27 bytes
            64'h0000000007FFFFFF: valid_bytes = 16'd27; // 27'b111111111111111111111111111
            
            // 28 bytes
            64'h000000000FFFFFFF: valid_bytes = 16'd28; // 28'b1111111111111111111111111111
            
            // 29 bytes
            64'h000000001FFFFFFF: valid_bytes = 16'd29; // 29'b11111111111111111111111111111
            
            // 30 bytes
            64'h000000003FFFFFFF: valid_bytes = 16'd30; // 30'b111111111111111111111111111111
            
            // 31 bytes
            64'h000000007FFFFFFF: valid_bytes = 16'd31; // 31'b1111111111111111111111111111111
            
            // 32 bytes
            64'h00000000FFFFFFFF: valid_bytes = 16'd32; // 32'b11111111111111111111111111111111
            
            // 33 bytes
            64'h00000001FFFFFFFF: valid_bytes = 16'd33; // 33 bits of 1
            
            // 34 bytes
            64'h00000003FFFFFFFF: valid_bytes = 16'd34;
            
            // 35 bytes
            64'h00000007FFFFFFFF: valid_bytes = 16'd35;
            
            // 36 bytes
            64'h0000000FFFFFFFFF: valid_bytes = 16'd36;
            
            // 37 bytes
            64'h0000001FFFFFFFFF: valid_bytes = 16'd37;
            
            // 38 bytes
            64'h0000003FFFFFFFFF: valid_bytes = 16'd38;
            
            // 39 bytes
            64'h0000007FFFFFFFFF: valid_bytes = 16'd39;
            
            // 40 bytes
            64'h000000FFFFFFFFFF: valid_bytes = 16'd40;
            
            // 41 bytes
            64'h000001FFFFFFFFFF: valid_bytes = 16'd41;
            
            // 42 bytes
            64'h000003FFFFFFFFFF: valid_bytes = 16'd42;
            
            // 43 bytes
            64'h000007FFFFFFFFFF: valid_bytes = 16'd43;
            
            // 44 bytes
            64'h00000FFFFFFFFFFF: valid_bytes = 16'd44;
            
            // 45 bytes
            64'h00001FFFFFFFFFFF: valid_bytes = 16'd45;
            
            // 46 bytes
            64'h00003FFFFFFFFFFF: valid_bytes = 16'd46;
            
            // 47 bytes
            64'h00007FFFFFFFFFFF: valid_bytes = 16'd47;
            
            // 48 bytes
            64'h0000FFFFFFFFFFFF: valid_bytes = 16'd48;
            
            // 49 bytes
            64'h0001FFFFFFFFFFFF: valid_bytes = 16'd49;
            
            // 50 bytes
            64'h0003FFFFFFFFFFFF: valid_bytes = 16'd50;
            
            // 51 bytes
            64'h0007FFFFFFFFFFFF: valid_bytes = 16'd51;
            
            // 52 bytes
            64'h000FFFFFFFFFFFFF: valid_bytes = 16'd52;
            
            // 53 bytes
            64'h001FFFFFFFFFFFFF: valid_bytes = 16'd53;
            
            // 54 bytes
            64'h003FFFFFFFFFFFFF: valid_bytes = 16'd54;
            
            // 55 bytes
            64'h007FFFFFFFFFFFFF: valid_bytes = 16'd55;
            
            // 56 bytes
            64'h00FFFFFFFFFFFFFF: valid_bytes = 16'd56;
            
            // 57 bytes
            64'h01FFFFFFFFFFFFFF: valid_bytes = 16'd57;
            
            // 58 bytes
            64'h03FFFFFFFFFFFFFF: valid_bytes = 16'd58;
            
            // 59 bytes
            64'h07FFFFFFFFFFFFFF: valid_bytes = 16'd59;
            
            // 60 bytes
            64'h0FFFFFFFFFFFFFFF: valid_bytes = 16'd60;
            
            // 61 bytes
            64'h1FFFFFFFFFFFFFFF: valid_bytes = 16'd61;
            
            // 62 bytes
            64'h3FFFFFFFFFFFFFFF: valid_bytes = 16'd62;
            
            // 63 bytes
            64'h7FFFFFFFFFFFFFFF: valid_bytes = 16'd63;
            
            // 64 bytes (all bytes valid)
            64'hFFFFFFFFFFFFFFFF: valid_bytes = 16'd64;
            
            // Default case (should not happen with contiguous tkeep)
            default: valid_bytes = 16'd0;
        endcase
    end

    //------------------------------------------------------------
    // Main sequential logic for accumulating packet length
    //------------------------------------------------------------
    reg [15:0] r_packet_len_bytes;
    
    always @(posedge axis_aclk) begin
        if (~axis_aresetn) begin
            r_packet_len_bytes <= 16'd0;
            packet_len_bytes   <= 16'd0;
        end
        else if (axis_tvalid && axis_tready) begin
            if (axis_tlast) begin
                // Output the total packet length immediately
                packet_len_bytes   <= r_packet_len_bytes + valid_bytes;
                r_packet_len_bytes <= 16'd0;
            end
            else begin
                // Accumulate length
                r_packet_len_bytes <= r_packet_len_bytes + valid_bytes;
            end
        end
    end

endmodule