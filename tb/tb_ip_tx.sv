`timescale 1ns / 1ps

//============================================================================
// tb_ip_tx_extreme : exhaustive + back-pressure verification of ip_tx
//
// The DUT turns an AXI-Stream payload (ip_tx_axis) into a complete IPv4
// packet on frame_tx_axis. This testbench checks, byte-for-byte, against an
// independently computed reference (20-byte IPv4 header + payload):
//   * header checksum (one's-complement over the 10 header words)
//   * total length, identification, flags/fragment, TTL, protocol, addresses
//   * payload byte order through the 4-byte stagger datapath
//   * tkeep for every possible partial last-beat alignment (0..18B sweep)
//
// Coverage:
//   A  full-rate size sweep (0..18, powers of two +/-1, 1500)
//   B  random downstream frame_tx_axis_tready throttling
//   C  deterministic periodic long downstream stalls (6 ready / 10 stall)
//   D  ingress back-pressure: payload FIFO almost-full deasserts
//      ip_tx_axis_tready while the output is held stalled, then drains
//   E  back-to-back burst (frame-boundary stress) + large-burst 1500B
//   F  single near-capacity packet (16000B) at full rate
//   G  single near-capacity packet fully stalled during ingress, then drained
//
// Watchdog aborts a hung run; TEST_PASS is printed only if error_count==0.
//============================================================================

module tb_ip_tx;

reg clk = 1'b0;
reg rst = 1'b1;

reg  [7:0]  ip_send_type = 8'h11;
reg  [31:0] src_ip_addr  = 32'hc0a80101;   // 192.168.1.1
reg  [31:0] dst_ip_addr  = 32'hc0a80102;   // 192.168.1.2

reg  [63:0] ip_tx_axis_tdata  = 64'd0;
reg  [7:0]  ip_tx_axis_tkeep  = 8'd0;
reg         ip_tx_axis_tvalid = 1'b0;
reg         ip_tx_axis_tlast  = 1'b0;
wire        ip_tx_axis_tready;

wire [63:0] frame_tx_axis_tdata;
wire [7:0]  frame_tx_axis_tkeep;
wire        frame_tx_axis_tvalid;
wire        frame_tx_axis_tlast;
reg         frame_tx_axis_tready = 1'b1;

integer error_count = 0;
integer frame_count  = 0;   // frames built & verified
integer ident_expect = 0;   // DUT identification field expectation

always #5 clk = ~clk;       // 100 MHz

ip_tx dut (
    .ip_send_type        (ip_send_type),
    .src_ip_addr         (src_ip_addr),
    .dst_ip_addr         (dst_ip_addr),
    .clk                 (clk),
    .rst                 (rst),
    .ip_tx_axis_tdata    (ip_tx_axis_tdata),
    .ip_tx_axis_tkeep    (ip_tx_axis_tkeep),
    .ip_tx_axis_tvalid   (ip_tx_axis_tvalid),
    .ip_tx_axis_tlast    (ip_tx_axis_tlast),
    .ip_tx_axis_tready   (ip_tx_axis_tready),
    .frame_tx_axis_tdata (frame_tx_axis_tdata),
    .frame_tx_axis_tkeep (frame_tx_axis_tkeep),
    .frame_tx_axis_tvalid(frame_tx_axis_tvalid),
    .frame_tx_axis_tlast (frame_tx_axis_tlast),
    .frame_tx_axis_tready(frame_tx_axis_tready)
);

//---------------------------------------------------------------------------
// downstream ready generator
//   00 : always ready (full rate)
//   01 : pseudo-random ready (~62%), bounded stall <= 32 cycles
//   10 : manual_tready
//   11 : deterministic periodic long stall (6 ready / 10 stall)
//---------------------------------------------------------------------------
reg [1:0]  tready_mode   = 2'b00;
reg        manual_tready = 1'b1;
reg [31:0] rnd_bp        = 32'hDEADBEEF;
reg [7:0]  bp_stall_cnt  = 8'd0;
reg [3:0]  periodic_cnt  = 4'd0;

function [31:0] lfsr_step(input [31:0] s);
    reg fb;
    begin
        fb = s[31] ^ s[21] ^ s[1] ^ s[0];
        lfsr_step = {s[30:0], fb};
    end
endfunction

always @(posedge clk) begin
    if (rst) begin
        frame_tx_axis_tready <= 1'b1;
        rnd_bp       <= 32'hDEADBEEF;
        bp_stall_cnt <= 8'd0;
        periodic_cnt <= 4'd0;
    end
    else begin
        rnd_bp <= lfsr_step(rnd_bp);
        case (tready_mode)
            2'b01: frame_tx_axis_tready <= (bp_stall_cnt >= 8'd32) ? 1'b1
                                                                   : (rnd_bp[2:0] < 3'd5);
            2'b10: frame_tx_axis_tready <= manual_tready;
            2'b11: begin
                       periodic_cnt <= periodic_cnt + 4'd1;
                       frame_tx_axis_tready <= (periodic_cnt < 4'd6);
                   end
            default: frame_tx_axis_tready <= 1'b1;
        endcase
        if (frame_tx_axis_tready)
            bp_stall_cnt <= 8'd0;
        else
            bp_stall_cnt <= bp_stall_cnt + 8'd1;
    end
end

//---------------------------------------------------------------------------
// reference model
//---------------------------------------------------------------------------
function [15:0] ocsum(input [15:0] a, input [15:0] b);
    reg [16:0] s;
    begin
        s = {1'b0, a} + {1'b0, b};
        ocsum = s[16] ? (s[15:0] + 16'd1) : s[15:0];
    end
endfunction

function [15:0] ip_hdr_cksum(input [15:0] total_len, input [15:0] ident,
                             input [7:0] proto);
    reg [15:0] sum;
    begin
        sum = 16'd0;
        sum = ocsum(sum, 16'h4500);            // ver/IHL + TOS
        sum = ocsum(sum, total_len);
        sum = ocsum(sum, ident);
        sum = ocsum(sum, 16'h4000);            // flags + fragment offset
        sum = ocsum(sum, {8'hff, proto});      // TTL + protocol
        sum = ocsum(sum, 16'h0000);            // checksum field = 0
        sum = ocsum(sum, src_ip_addr[31:16]);
        sum = ocsum(sum, src_ip_addr[15:0]);
        sum = ocsum(sum, dst_ip_addr[31:16]);
        sum = ocsum(sum, dst_ip_addr[15:0]);
        ip_hdr_cksum = (sum == 16'hffff) ? 16'hffff : ~sum;
    end
endfunction

// expected tkeep of the final output beat, as a function of payload length.
// Non-final beats must always be 8'hff.
function [7:0] exp_tail_tkeep_func(input integer L);
    integer r;
    begin
        r = L % 8;
        case (r)
            0: exp_tail_tkeep_func = 8'h0f;
            1: exp_tail_tkeep_func = 8'h1f;
            2: exp_tail_tkeep_func = 8'h3f;
            3: exp_tail_tkeep_func = 8'h7f;
            4: exp_tail_tkeep_func = 8'hff;
            5: exp_tail_tkeep_func = 8'h01;
            6: exp_tail_tkeep_func = 8'h03;
            7: exp_tail_tkeep_func = 8'h07;
        endcase
    end
endfunction

function [7:0] payload_byte(input [31:0] seed, input integer k);
    begin
        payload_byte = (seed + (k * 32'd93)) & 32'hff;
    end
endfunction

//---------------------------------------------------------------------------
// scoreboard state
//---------------------------------------------------------------------------
reg  [7:0] exp_b [0:65535];
integer    exp_n;
reg  [7:0] cap_b [0:65535];
integer    cap_n;
reg        cap_done;

reg  [7:0] exp_tail_tkeep [0:1023];
integer    tail_tkeep_count = 0;
integer    cap_fidx;

reg  [15:0] dbg_total_len;
reg  [15:0] dbg_cksum;

// capture `nframes` output frames (standard AXI monitor at the posedge:
// tvalid && tready marks the beat consumed at that edge)
task automatic capture_n(input integer nframes);
    integer j;
    integer seen;
    begin
        cap_n    = 0;
        seen     = 0;
        cap_fidx = 0;
        while (seen < nframes) begin
            @(posedge clk);
            if (frame_tx_axis_tvalid && frame_tx_axis_tready) begin
                // ---- tkeep verification ----
                if (frame_tx_axis_tlast) begin
                    if (frame_tx_axis_tkeep !== exp_tail_tkeep[cap_fidx]) begin
                        error_count = error_count + 1;
                        if (error_count <= 10)
                            $display("ERROR tkeep: frame[%0d] last beat tkeep=%h expected=%h",
                                     cap_fidx, frame_tx_axis_tkeep, exp_tail_tkeep[cap_fidx]);
                    end
                    cap_fidx = cap_fidx + 1;
                end
                else begin
                    if (frame_tx_axis_tkeep !== 8'hff) begin
                        error_count = error_count + 1;
                        if (error_count <= 10)
                            $display("ERROR tkeep: frame[%0d] mid beat tkeep=%h expected=ff",
                                     cap_fidx, frame_tx_axis_tkeep);
                    end
                end

                for (j = 0; j < 8; j = j + 1) begin
                    if (frame_tx_axis_tkeep[j]) begin
                        cap_b[cap_n] = frame_tx_axis_tdata[8*j +: 8];
                        cap_n = cap_n + 1;
                    end
                end
                if (frame_tx_axis_tlast)
                    seen = seen + 1;
            end
        end
        cap_done = 1;
    end
endtask

//---------------------------------------------------------------------------
// ingress driver (standard AXI master)
//---------------------------------------------------------------------------
integer bp_ingress_cycles;
integer bp_ingress_asserted;

task automatic send_packet(input integer len, input [31:0] seed);
    integer k, b, nbeat;
    begin
        if (len == 0) begin
            // empty payload: single tlast beat with tkeep = 0
            ip_tx_axis_tdata  = 64'd0;
            ip_tx_axis_tkeep  = 8'd0;
            ip_tx_axis_tlast  = 1'b1;
            ip_tx_axis_tvalid = 1'b1;
            @(posedge clk);
            while (!ip_tx_axis_tready) begin
                bp_ingress_cycles   = bp_ingress_cycles + 1;
                bp_ingress_asserted = 1;
                @(posedge clk);
            end
            @(negedge clk);
            ip_tx_axis_tvalid = 1'b0;
            ip_tx_axis_tlast  = 1'b0;
            return;
        end

        k = 0;
        while (k < len) begin
            nbeat = ((len - k) > 8) ? 8 : (len - k);
            ip_tx_axis_tdata = 64'd0;
            ip_tx_axis_tkeep = 8'd0;
            for (b = 0; b < nbeat; b = b + 1) begin
                ip_tx_axis_tdata[8*b +: 8] = payload_byte(seed, k + b);
                ip_tx_axis_tkeep[b] = 1'b1;
            end
            ip_tx_axis_tlast  = (k + nbeat == len);
            ip_tx_axis_tvalid = 1'b1;

            @(posedge clk);
            while (!ip_tx_axis_tready) begin
                bp_ingress_cycles   = bp_ingress_cycles + 1;
                bp_ingress_asserted = 1;
                @(posedge clk);
            end
            @(negedge clk);
            ip_tx_axis_tvalid = 1'b0;
            ip_tx_axis_tlast  = 1'b0;
            k = k + nbeat;
        end
    end
endtask

//---------------------------------------------------------------------------
// expected stream builder / comparator
//---------------------------------------------------------------------------
task automatic build_expected_append(input integer nbytes, input [7:0] proto,
                                     input [31:0] seed);
    integer k;
    integer base;
    reg [15:0] total_len;
    reg [15:0] cksum;
    begin
        base      = exp_n;
        total_len = nbytes + 16'd20;
        cksum     = ip_hdr_cksum(total_len, ident_expect, proto);
        dbg_total_len = total_len;
        dbg_cksum     = cksum;

        exp_b[base+0]  = 8'h45;
        exp_b[base+1]  = 8'h00;
        exp_b[base+2]  = total_len[15:8];
        exp_b[base+3]  = total_len[7:0];
        exp_b[base+4]  = ident_expect[15:8];
        exp_b[base+5]  = ident_expect[7:0];
        exp_b[base+6]  = 8'h40;
        exp_b[base+7]  = 8'h00;
        exp_b[base+8]  = 8'hff;
        exp_b[base+9]  = proto;
        exp_b[base+10] = cksum[15:8];
        exp_b[base+11] = cksum[7:0];
        exp_b[base+12] = src_ip_addr[31:24];
        exp_b[base+13] = src_ip_addr[23:16];
        exp_b[base+14] = src_ip_addr[15:8];
        exp_b[base+15] = src_ip_addr[7:0];
        exp_b[base+16] = dst_ip_addr[31:24];
        exp_b[base+17] = dst_ip_addr[23:16];
        exp_b[base+18] = dst_ip_addr[15:8];
        exp_b[base+19] = dst_ip_addr[7:0];
        for (k = 0; k < nbytes; k = k + 1)
            exp_b[base+20+k] = payload_byte(seed, k);
        exp_n = base + 20 + nbytes;
        exp_tail_tkeep[tail_tkeep_count] = exp_tail_tkeep_func(nbytes);
        tail_tkeep_count = tail_tkeep_count + 1;
        ident_expect = ident_expect + 1;
        frame_count  = frame_count + 1;
    end
endtask

task automatic compare_expected(input string what);
    integer k;
    begin
        if (cap_n != exp_n) begin
            error_count = error_count + 1;
            $display("ERROR %s: byte count %0d, expected %0d", what, cap_n, exp_n);
        end
        else begin
            for (k = 0; k < exp_n; k = k + 1) begin
                if (cap_b[k] !== exp_b[k]) begin
                    error_count = error_count + 1;
                    if (error_count <= 10)
                        $display("ERROR %s: byte[%0d] = %h, expected %h",
                                 what, k, cap_b[k], exp_b[k]);
                end
            end
        end
        if (error_count == 0)
            $display("OK   %-14s bytes=%0d (last: total_len=%h cksum=%h ident=%0d)",
                     what, cap_n, dbg_total_len, dbg_cksum, ident_expect - 1);
    end
endtask

//---------------------------------------------------------------------------
// high-level test helpers
//---------------------------------------------------------------------------
task automatic run_packet(input integer nbytes, input [7:0] proto,
                          input [31:0] seed, input string what);
    begin
        ip_send_type = proto;
        exp_n = 0;
        tail_tkeep_count = 0;
        build_expected_append(nbytes, proto, seed);
        bp_ingress_cycles   = 0;
        bp_ingress_asserted = 0;
        cap_done = 0;
        fork capture_n(1); join_none
        send_packet(nbytes, seed);
        wait (cap_done);
        compare_expected(what);
    end
endtask

task automatic run_burst(input integer nframes, input integer nbytes,
                         input [7:0] proto, input [31:0] seed, input string what);
    integer f;
    begin
        ip_send_type = proto;
        exp_n = 0;
        tail_tkeep_count = 0;
        for (f = 0; f < nframes; f = f + 1)
            build_expected_append(nbytes, proto, seed + f);
        bp_ingress_cycles   = 0;
        bp_ingress_asserted = 0;
        cap_done = 0;
        fork capture_n(nframes); join_none
        for (f = 0; f < nframes; f = f + 1)
            send_packet(nbytes, seed + f);
        wait (cap_done);
        compare_expected(what);
    end
endtask

//---------------------------------------------------------------------------
// test driver
//---------------------------------------------------------------------------
reg [31:0] rnd = 32'hC0FFEE15;

initial begin : TESTBENCH
    integer L;

    repeat (20) @(negedge clk);   // power-up reset
    rst = 1'b0;
    repeat (30) @(negedge clk);   // wait for XPM FIFO reset recovery

    // ---- A: full-rate size sweep ----
    $display("=== A: full-rate size sweep (no back-pressure) ===");
    tready_mode = 2'b00;
    for (L = 0; L <= 18; L = L + 1) begin
        rnd = lfsr_step(rnd);
        run_packet(L, ((L % 2) == 0) ? 8'h11 : 8'h01, rnd, "A-small");
    end
    L = 32;
    while (L <= 4096) begin
        rnd = lfsr_step(rnd); run_packet(L - 1, 8'h11, rnd, "A-pow2");
        rnd = lfsr_step(rnd); run_packet(L,     8'h06, rnd, "A-pow2");
        rnd = lfsr_step(rnd); run_packet(L + 1, 8'h11, rnd, "A-pow2");
        L = L * 2;
    end
    rnd = lfsr_step(rnd);
    run_packet(1500, 8'h11, rnd, "A-1500");

    // ---- B: random downstream back-pressure ----
    $display("=== B: random downstream back-pressure ===");
    tready_mode = 2'b01;
    for (L = 1; L <= 18; L = L + 1) begin
        rnd = lfsr_step(rnd);
        run_packet(L, ((L % 2) == 0) ? 8'h11 : 8'h06, rnd, "B-small");
    end
    rnd = lfsr_step(rnd); run_packet(63,  8'h11, rnd, "B-63");
    rnd = lfsr_step(rnd); run_packet(64,  8'h11, rnd, "B-64");
    rnd = lfsr_step(rnd); run_packet(65,  8'h11, rnd, "B-65");
    rnd = lfsr_step(rnd); run_packet(255, 8'h11, rnd, "B-255");
    rnd = lfsr_step(rnd); run_packet(256, 8'h11, rnd, "B-256");
    rnd = lfsr_step(rnd); run_packet(257, 8'h11, rnd, "B-257");
    rnd = lfsr_step(rnd); run_packet(511, 8'h11, rnd, "B-511");
    rnd = lfsr_step(rnd); run_packet(512, 8'h11, rnd, "B-512");
    rnd = lfsr_step(rnd); run_packet(1023,8'h11, rnd, "B-1023");
    rnd = lfsr_step(rnd); run_packet(1500,8'h11, rnd, "B-1500");
    tready_mode = 2'b00;

    // ---- C: deterministic periodic long downstream stalls ----
    $display("=== C: deterministic periodic long stalls (6 on / 10 off) ===");
    tready_mode = 2'b11;
    rnd = lfsr_step(rnd); run_packet(64,   8'h11, rnd, "C-64");
    rnd = lfsr_step(rnd); run_packet(1024, 8'h11, rnd, "C-1024");
    rnd = lfsr_step(rnd); run_packet(1500, 8'h11, rnd, "C-1500");
    tready_mode = 2'b00;

    // ---- D: ingress back-pressure (payload FIFO almost-full) ----
    $display("=== D: ingress back-pressure (payload FIFO almost-full) ===");
    tready_mode   = 2'b10;
    manual_tready = 1'b0;   // stall output so ingress fills the payload FIFO
    exp_n = 0;
    tail_tkeep_count = 0;
    for (L = 0; L < 30; L = L + 1)
        build_expected_append(1000, 8'h11, 32'hD0000000 + L);
    bp_ingress_cycles   = 0;
    bp_ingress_asserted = 0;
    cap_done = 0;
    fork capture_n(30); join_none
    fork begin
        for (L = 0; L < 30; L = L + 1)
            send_packet(1000, 32'hD0000000 + L);
    end join_none
    repeat (5000) @(posedge clk);   // let the FIFO fill and throttle ingress
    if (!bp_ingress_asserted) begin
        error_count = error_count + 1;
        $display("ERROR D: ip_tx_axis_tready never deasserted");
    end
    else
        $display("OK   D: ingress back-pressured %0d cycles", bp_ingress_cycles);
    manual_tready = 1'b1;
    wait (cap_done);
    compare_expected("D-burst30x1000");
    tready_mode = 2'b00;

    // ---- E: back-to-back bursts ----
    $display("=== E: back-to-back bursts ===");
    tready_mode = 2'b00;
    run_burst(200, 60,   8'h11, 32'hBEEF0000, "E-burst200x60");
    run_burst(50,  1500, 8'h11, 32'hCAFE0000, "E-burst50x1500");

    // ---- F: single near-capacity packet at full rate ----
    $display("=== F: single near-capacity packet 16000B ===");
    tready_mode = 2'b00;
    rnd = lfsr_step(rnd);
    run_packet(16000, 8'h11, rnd, "F-16000");

    // ---- G: near-capacity packet, fully stalled during ingress, then drained ----
    $display("=== G: 16000B fully stalled during ingress, then drained ===");
    tready_mode   = 2'b10;
    manual_tready = 1'b0;
    rnd = lfsr_step(rnd);
    ip_send_type = 8'h11;
    exp_n = 0;
    tail_tkeep_count = 0;
    build_expected_append(16000, 8'h11, rnd);
    bp_ingress_cycles   = 0;
    bp_ingress_asserted = 0;
    cap_done = 0;
    fork capture_n(1); join_none
    fork send_packet(16000, rnd); join_none
    repeat (5000) @(posedge clk);   // ingress must now be throttled (FIFO full)
    manual_tready = 1'b1;
    wait (cap_done);
    compare_expected("G-16000-stall");
    tready_mode = 2'b00;

    // ---- summary ----
    $display("==================================================");
    if (error_count == 0) begin
        $display("TEST_PASS: %0d frames verified", frame_count);
        $finish;
    end
    else begin
        $display("TEST_FAIL: %0d error(s)", error_count);
        $fatal(1, "TEST_FAIL: %0d error(s)", error_count);
    end
end

// watchdog
initial begin
    #30_000_000;
    $fatal(1, "watchdog timeout at %0t", $time);
end

endmodule
