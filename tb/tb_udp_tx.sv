`timescale 1ns / 1ps

module tb_udp_tx;

//---------------------------------------------------------------------------
// Test plan
//  T1: 9-byte frame (8 + 1 odd byte), downstream stalled:
//      - UDP header appears and is held stable while tready = 0
//      - after release the two payload beats come out in order, with a
//        mid-stream stall holding beat 0 unchanged
//      - tvalid drops after the tlast beat
//      - header fields checked against an independent RFC 768 reference
//        checksum (expected checksum 0xfab7 for this frame)
//  T2: 37-byte frame with tready high: full-rate streaming, every beat
//      checked in order
//  T3: two back-to-back frames: per-frame length/checksum latching
// Watchdog aborts a hung run; TEST_PASS is printed only if error_count==0.
//---------------------------------------------------------------------------

reg clk = 1'b0;
reg rst = 1'b1;

reg  [31:0] src_ip_addr  = 32'hc0a80101;   // 192.168.1.1
reg  [31:0] dst_ip_addr  = 32'hc0a80102;   // 192.168.1.2
reg  [15:0] udp_src_port = 16'h1234;
reg  [15:0] udp_dst_port = 16'h5678;
reg         configure_done = 1'b1;

reg  [63:0] udp_tx_axis_tdata  = 64'd0;
reg  [7:0]  udp_tx_axis_tkeep  = 8'd0;
reg         udp_tx_axis_tvalid = 1'b0;
reg         udp_tx_axis_tlast  = 1'b0;
wire        udp_tx_axis_tready;

wire [63:0] ip_tx_axis_tdata;
wire [7:0]  ip_tx_axis_tkeep;
wire        ip_tx_axis_tvalid;
wire        ip_tx_axis_tlast;
reg         ip_tx_axis_tready = 1'b0;

integer error_count = 0;
integer i;

always #5 clk = ~clk;   // 100 MHz

udp_tx dut (
    .clk               (clk),
    .rst               (rst),
    .src_ip_addr       (src_ip_addr),
    .dst_ip_addr       (dst_ip_addr),
    .udp_src_port      (udp_src_port),
    .udp_dst_port      (udp_dst_port),
    .configure_done    (configure_done),
    .udp_tx_axis_tdata (udp_tx_axis_tdata),
    .udp_tx_axis_tkeep (udp_tx_axis_tkeep),
    .udp_tx_axis_tvalid(udp_tx_axis_tvalid),
    .udp_tx_axis_tlast (udp_tx_axis_tlast),
    .udp_tx_axis_tready(udp_tx_axis_tready),
    .ip_tx_axis_tdata  (ip_tx_axis_tdata),
    .ip_tx_axis_tkeep  (ip_tx_axis_tkeep),
    .ip_tx_axis_tvalid (ip_tx_axis_tvalid),
    .ip_tx_axis_tlast  (ip_tx_axis_tlast),
    .ip_tx_axis_tready (ip_tx_axis_tready)
);

//---------------------------------------------------------------------------
// Reference model
//---------------------------------------------------------------------------

function [15:0] ocsum(input [15:0] a, input [15:0] b);
    reg [16:0] s;
    begin
        s = {1'b0, a} + {1'b0, b};
        ocsum = s[16] ? (s[15:0] + 16'd1) : s[15:0];
    end
endfunction

function [3:0] cnt_ones(input [7:0] v);
    integer k;
    begin
        cnt_ones = 4'd0;
        for (k = 0; k < 8; k = k + 1)
            cnt_ones = cnt_ones + v[k];
    end
endfunction

// independent RFC 768 checksum: pseudo header + UDP header + payload
function [15:0] ref_checksum(input [63:0] beats [0:7], input integer nbeats,
                             input [7:0] last_keep);
    integer pbytes_n;
    integer pb_i;
    integer pb_j;
    integer payload_bytes;
    reg [7:0]  pbytes [0:127];
    reg [15:0] sum;
    reg [15:0] udp_len;
    begin
        pbytes_n = 0;
        for (pb_i = 0; pb_i < nbeats; pb_i = pb_i + 1)
            for (pb_j = 0; pb_j < 8; pb_j = pb_j + 1)
                if ((pb_i < nbeats - 1) || last_keep[pb_j]) begin
                    pbytes[pbytes_n] = beats[pb_i][pb_j*8 +: 8];
                    pbytes_n = pbytes_n + 1;
                end
        payload_bytes = pbytes_n;
        udp_len = payload_bytes + 16'd8;

        sum = 16'd0;
        sum = ocsum(sum, src_ip_addr[31:16]);
        sum = ocsum(sum, src_ip_addr[15:0]);
        sum = ocsum(sum, dst_ip_addr[31:16]);
        sum = ocsum(sum, dst_ip_addr[15:0]);
        sum = ocsum(sum, {8'h00, 8'd17});   // zero + protocol
        sum = ocsum(sum, udp_len);          // pseudo-header length
        sum = ocsum(sum, udp_src_port);
        sum = ocsum(sum, udp_dst_port);
        sum = ocsum(sum, udp_len);          // UDP header length field
        pb_i = 0;
        while (pb_i < payload_bytes) begin
            if (pb_i + 1 < payload_bytes)
                sum = ocsum(sum, {pbytes[pb_i], pbytes[pb_i+1]});
            else
                sum = ocsum(sum, {pbytes[pb_i], 8'h00});
            pb_i = pb_i + 2;
        end
        ref_checksum = (sum == 16'hffff) ? 16'hffff : ~sum;
    end
endfunction

function [63:0] hdr_word(input [15:0] cksum, input [15:0] udp_len);
    hdr_word = {cksum[7:0],  cksum[15:8],
                udp_len[7:0], udp_len[15:8],
                udp_dst_port[7:0],  udp_dst_port[15:8],
                udp_src_port[7:0],  udp_src_port[15:8]};
endfunction

//---------------------------------------------------------------------------
// T4: jumbo-frame helpers — 9000-byte payload = 1125 full beats
//---------------------------------------------------------------------------

function [63:0] t4_beat(input [7:0] fid, input integer idx);
    t4_beat = {16'h5aa5, {fid, 8'h00}, idx[15:0], idx[15:0] ^ 16'hf00d};
endfunction

// one's-complement addition is associative/commutative, so the payload
// words can be summed first and the header terms folded in afterwards
function [15:0] t4_checksum(input [7:0] fid);
    integer k;
    reg [15:0] sum;
    reg [63:0] t4_w;
    begin
        sum = 16'd0;
        for (k = 0; k < 1125; k = k + 1) begin
            // wire-order 16-bit words: first byte on the wire is the HIGH
            // byte of the checksum word, i.e. byte-swap each 16-bit chunk
            t4_w = t4_beat(fid, k);
            sum = ocsum(sum, {t4_w[7:0],   t4_w[15:8]});
            sum = ocsum(sum, {t4_w[23:16], t4_w[31:24]});
            sum = ocsum(sum, {t4_w[39:32], t4_w[47:40]});
            sum = ocsum(sum, {t4_w[55:48], t4_w[63:56]});
        end
        sum = ocsum(sum, src_ip_addr[31:16]);
        sum = ocsum(sum, src_ip_addr[15:0]);
        sum = ocsum(sum, dst_ip_addr[31:16]);
        sum = ocsum(sum, dst_ip_addr[15:0]);
        sum = ocsum(sum, {8'h00, 8'd17});   // zero + protocol
        sum = ocsum(sum, 16'd9008);         // pseudo-header length
        sum = ocsum(sum, udp_src_port);
        sum = ocsum(sum, udp_dst_port);
        sum = ocsum(sum, 16'd9008);         // UDP header length field
        t4_checksum = (sum == 16'hffff) ? 16'hffff : ~sum;
    end
endfunction

// stream one 9000-byte frame at full rate, honoring backpressure;
// aborts with a diagnostic if the input path deadlocks
task automatic send_t4_frame(input [7:0] fid);
    integer k;
    integer stall;
    begin
        k = 0;
        stall = 0;
        while (k < 1125) begin
            @(negedge clk);
            udp_tx_axis_tdata  = t4_beat(fid, k);
            udp_tx_axis_tkeep  = 8'hff;
            udp_tx_axis_tlast  = (k == 1124);
            udp_tx_axis_tvalid = 1'b1;
            @(posedge clk);
            if (udp_tx_axis_tready) begin
                k = k + 1;
                stall = 0;
            end
            else begin
                stall = stall + 1;
                if (stall > 500) begin
                    $fatal(1, "T4 frame %0d: input stalled at beat %0d for %0d cycles -- payload FIFO full (store-and-forward depth limit)",
                           fid, k, stall);
                end
            end
        end
        @(negedge clk);
        udp_tx_axis_tvalid = 1'b0;
        udp_tx_axis_tlast  = 1'b0;
    end
endtask

// output-side checker, runs in parallel with the input stimulus:
// at full rate frame A drains while frame B is still being sent
reg t4_check_done;
reg t4_bp_en = 1'b0;
reg [15:0] t4_cksum1, t4_cksum2;

// receive one accepted output beat; samples mid-cycle (after the
// backpressure driver settles at the negedge), so it is race-free and
// tolerates beats held by downstream backpressure
task automatic recv_beat(input [63:0] exp_data, input [7:0] exp_keep,
                         input bit exp_last, input string what);
    begin
        while (!(ip_tx_axis_tvalid && ip_tx_axis_tready)) begin
            @(negedge clk);
            #1;
        end
        // the beat currently on the bus is accepted at the coming posedge
        if (ip_tx_axis_tdata !== exp_data || ip_tx_axis_tkeep !== exp_keep ||
            ip_tx_axis_tlast !== exp_last) begin
            error_count = error_count + 1;
            $display("ERROR %0t %s: data=%h (exp %h) keep=%h (exp %h) last=%b (exp %b)",
                     $time, what, ip_tx_axis_tdata, exp_data,
                     ip_tx_axis_tkeep, exp_keep, ip_tx_axis_tlast, exp_last);
        end
        @(posedge clk);      // beat consumed here
        @(negedge clk);
        #1;
    end
endtask

// bounded wait for the output to go idle (last tlast beat must first be
// accepted, which under backpressure can take extra cycles)
task automatic wait_idle(input integer max_cycles, input string what);
    integer g;
    begin
        g = 0;
        while (ip_tx_axis_tvalid && (g < max_cycles)) begin
            @(posedge clk); #1;
            g = g + 1;
        end
        if (ip_tx_axis_tvalid) begin
            error_count = error_count + 1;
            $display("ERROR %0t %s: output still valid after %0d cycles",
                     $time, what, max_cycles);
        end
    end
endtask

task automatic t4_check_stream;
    begin
        wait_output_valid(3000, "T4 header A");
        recv_beat(hdr_word(t4_cksum1, 16'd9008), 8'hff, 1'b0, "T4 header A");
        for (i = 0; i < 1125; i = i + 1)
            recv_beat(t4_beat(8'd1, i), 8'hff, (i == 1124), "T4 payload A");

        // frame B header can follow frame A's tail as early as one cycle
        // later, so no idle gap is required here
        wait_output_valid(3000, "T4 header B");
        recv_beat(hdr_word(t4_cksum2, 16'd9008), 8'hff, 1'b0, "T4 header B");
        for (i = 0; i < 1125; i = i + 1)
            recv_beat(t4_beat(8'd2, i), 8'hff, (i == 1124), "T4 payload B");
        wait_idle(1000, "T4 output after frame B");
        t4_check_done = 1'b1;
    end
endtask

//---------------------------------------------------------------------------
// Helpers
//---------------------------------------------------------------------------

task automatic send_beat(input [63:0] data, input [7:0] keep, input bit last);
    begin
        @(negedge clk);
        udp_tx_axis_tdata  = data;
        udp_tx_axis_tkeep  = keep;
        udp_tx_axis_tlast  = last;
        udp_tx_axis_tvalid = 1'b1;
        @(posedge clk);
        while (!udp_tx_axis_tready)
            @(posedge clk);
        @(negedge clk);
        udp_tx_axis_tvalid = 1'b0;
        udp_tx_axis_tlast  = 1'b0;
    end
endtask

task automatic check_beat(input [63:0] exp_data, input [7:0] exp_keep,
                          input bit exp_last, input string what);
    begin
        if (!ip_tx_axis_tvalid || ip_tx_axis_tdata !== exp_data ||
            ip_tx_axis_tkeep !== exp_keep || ip_tx_axis_tlast !== exp_last) begin
            error_count = error_count + 1;
            $display("ERROR %0t %s: tvalid=%b data=%h (exp %h) keep=%h (exp %h) last=%b (exp %b)",
                     $time, what, ip_tx_axis_tvalid,
                     ip_tx_axis_tdata, exp_data,
                     ip_tx_axis_tkeep, exp_keep,
                     ip_tx_axis_tlast, exp_last);
        end
    end
endtask

task automatic wait_output_valid(input integer max_cycles, input string what);
    integer k;
    begin
        k = 0;
        while (!ip_tx_axis_tvalid && (k < max_cycles)) begin
            @(posedge clk);
            #1;
            k = k + 1;
        end
        if (!ip_tx_axis_tvalid) begin
            error_count = error_count + 1;
            $display("ERROR %0t %s: no output beat within %0d cycles",
                     $time, what, max_cycles);
        end
    end
endtask

task automatic check_idle(input string what);
    begin
        if (ip_tx_axis_tvalid) begin
            error_count = error_count + 1;
            $display("ERROR %0t %s: tvalid still high, data=%h",
                     $time, what, ip_tx_axis_tdata);
        end
    end
endtask

//---------------------------------------------------------------------------
// Stimulus
//---------------------------------------------------------------------------

reg [63:0] t1_beats  [0:7];
reg [63:0] t2_beats  [0:7];
reg [63:0] t3a_beats [0:7];
reg [63:0] t3b_beats [0:7];
reg [15:0] t1_cksum, t2_cksum, t3a_cksum, t3b_cksum;

initial begin : main
    //-----------------------------------------------------------------------
    $display("T1: 9-byte frame with stalled downstream");
    repeat (10) @(negedge clk);
    rst = 1'b0;
    // XPM FIFOs need several cycles of rst_busy recovery time after reset
    // release before wr_en/rd_en may be driven
    repeat (10) @(negedge clk);

    t1_beats[0] = 64'h0807060504030201;
    t1_beats[1] = 64'h0000000000000009;
    t1_cksum = ref_checksum(t1_beats, 2, 8'h01);
    if (t1_cksum !== 16'hfab7) begin
        error_count = error_count + 1;
        $display("ERROR %0t T1 reference checksum sanity: got %h, expected fab7",
                 $time, t1_cksum);
    end

    send_beat(t1_beats[0], 8'hff, 1'b0);
    send_beat(t1_beats[1], 8'h01, 1'b1);

    // header must appear even while downstream is stalled, and hold
    wait_output_valid(200, "T1 header");
    check_beat(hdr_word(t1_cksum, 16'd17), 8'hff, 1'b0, "T1 UDP header");
    repeat (3) begin
        @(posedge clk); #1;
        check_beat(hdr_word(t1_cksum, 16'd17), 8'hff, 1'b0,
                   "T1 header held under stall");
    end

    // release for one cycle: header consumed, payload beat 0 appears
    @(negedge clk); ip_tx_axis_tready = 1'b1;
    @(posedge clk); #1;
    check_beat(t1_beats[0], 8'hff, 1'b0, "T1 payload beat 0 after release");

    // re-stall: beat 0 must be held unchanged
    @(negedge clk); ip_tx_axis_tready = 1'b0;
    repeat (2) begin
        @(posedge clk); #1;
        check_beat(t1_beats[0], 8'hff, 1'b0, "T1 payload beat 0 held under stall");
    end

    // release: beat 0 consumed, final odd-byte beat appears with tlast
    @(negedge clk); ip_tx_axis_tready = 1'b1;
    @(posedge clk); #1;
    check_beat(t1_beats[1], 8'h01, 1'b1, "T1 final odd-byte beat");
    @(posedge clk); #1;
    check_idle("T1 output after tlast beat");

    //-----------------------------------------------------------------------
    $display("T2: 37-byte frame, full rate");
    // ip_tx_axis_tready stays 1 from here on
    t2_beats[0] = 64'h8877665544332211;
    t2_beats[1] = 64'h99aabbccddeeff00;
    t2_beats[2] = 64'h0f1e2d3c4b5a6978;
    t2_beats[3] = 64'hdeadbeefcafebabe;
    t2_beats[4] = 64'h000000a5a5a5a5a5;
    for (i = 0; i < 4; i = i + 1)
        send_beat(t2_beats[i], 8'hff, 1'b0);
    send_beat(t2_beats[4], 8'h1f, 1'b1);

    t2_cksum = ref_checksum(t2_beats, 5, 8'h1f);
    wait_output_valid(200, "T2 header");
    check_beat(hdr_word(t2_cksum, 16'd45), 8'hff, 1'b0, "T2 UDP header");
    for (i = 0; i < 4; i = i + 1) begin
        @(posedge clk); #1;
        check_beat(t2_beats[i], 8'hff, 1'b0, "T2 payload beat");
    end
    @(posedge clk); #1;
    check_beat(t2_beats[4], 8'h1f, 1'b1, "T2 tail beat");
    @(posedge clk); #1;
    check_idle("T2 output after tlast beat");

    //-----------------------------------------------------------------------
    $display("T3: back-to-back frames (per-frame length/checksum)");
    t3a_beats[0] = 64'hdeadbeefdeadbeef;   // 8-byte frame
    t3b_beats[0] = 64'h0000000000c0ffee;   // 3-byte frame (keep=07)
    send_beat(t3a_beats[0], 8'hff, 1'b1);
    send_beat(t3b_beats[0], 8'h07, 1'b1);

    t3a_cksum = ref_checksum(t3a_beats, 1, 8'hff);
    t3b_cksum = ref_checksum(t3b_beats, 1, 8'h07);

    wait_output_valid(200, "T3 header A");
    check_beat(hdr_word(t3a_cksum, 16'd16), 8'hff, 1'b0, "T3 header A");
    @(posedge clk); #1;
    check_beat(t3a_beats[0], 8'hff, 1'b1, "T3 payload A");
    @(posedge clk); #1;                       // let payload A be consumed
    wait_output_valid(200, "T3 header B");
    check_beat(hdr_word(t3b_cksum, 16'd11), 8'hff, 1'b0, "T3 header B");
    @(posedge clk); #1;
    check_beat(t3b_beats[0], 8'h07, 1'b1, "T3 payload B");
    @(posedge clk); #1;
    check_idle("T3 output after tlast beat");

    //-----------------------------------------------------------------------
    $display("T4: two 9000-byte jumbo frames, 1-cycle gap, random downstream backpressure");
    t4_cksum1 = t4_checksum(8'd1);
    t4_cksum2 = t4_checksum(8'd2);
    t4_check_done = 1'b0;
    t4_bp_en = 1'b1;                    // enable ip_tx_axis_tready backpressure

    // check the output stream while the input stimulus is still running
    fork
        t4_check_stream();
    join_none

    send_t4_frame(8'd1);
    repeat (1) @(negedge clk);          // exactly one clock delay, not back-to-back
    send_t4_frame(8'd2);

    wait (t4_check_done);
    t4_bp_en = 1'b0;
    @(negedge clk);
    ip_tx_axis_tready = 1'b1;

    //-----------------------------------------------------------------------
    repeat (10) @(posedge clk);
    if (error_count == 0) begin
        $display("TEST_PASS");
        $finish;
    end
    else begin
        $fatal(1, "TEST_FAIL: %0d error(s)", error_count);
    end
end

// downstream backpressure generator: while enabled, randomly deassert
// ip_tx_axis_tready (~65% duty, deterministic under the default xsim seed)
initial begin
    forever begin
        @(negedge clk);
        if (t4_bp_en)
            ip_tx_axis_tready = ($urandom_range(0, 99) < 65);
    end
end

// watchdog
initial begin
    #300_000;
    $fatal(1, "watchdog timeout at %0t", $time);
end

endmodule
