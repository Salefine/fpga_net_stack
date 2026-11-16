/****************************************************************************
 * @file    tb_udp_rx.sv
 * @brief   Self-checking testbench for udp_rx
 *
 *          The ethernet padding of a short frame is removed by ip_rx, so a
 *          datagram arriving on udp_rx_axis carries exactly the UDP header
 *          plus the UDP payload (no zero tail). udp_rx therefore only has to
 *          strip the 8-byte UDP header and pass the rest through unchanged.
 *
 *          Covers:
 *            1. two back-to-back "hello, world" datagrams (1-cycle gap)
 *            2. checksum pass -> app_rx_axis_tuser low on the final beat
 *            3. checksum fail -> app_rx_axis_tuser high, payload intact
 *            4. checksum field 0 (not computed) -> treated as valid
 *            5. frame error from the MAC/IP layer (udp_rx_axis_tuser) is
 *               forwarded on the final beat
 *            6. payload length sweep 9..74 bytes, one datagram per length:
 *               data, tkeep, tlast and the beat count must match exactly
 *            7. destination-port mismatch -> datagram dropped silently
 *            8. source-port mismatch   -> datagram dropped silently
 *            9. output backpressure (random app_rx_axis_tready)
 *           10. 5000-byte datagram: longer than the 512-entry output FIFO,
 *               so the input handshake throttles while the reader drains
 *
 * @copyright Copyright (c) 2026
 * ***************************************************************************/

`timescale 1ns / 1ps
`default_nettype none

module tb_udp_rx;

localparam integer CLK_HALF = 5;   // ns -> 100 MHz

reg clk = 1'b0;
reg rst = 1'b1;

reg [31:0] recv_dst_ip_addr = 32'hC0A80001; // 192.168.0.1 (local)
reg [31:0] recv_src_ip_addr = 32'hC0A80002; // 192.168.0.2 (remote)
reg [15:0] local_udp_port   = 16'h5678;     // local port (dst-port filter)
reg [15:0] dst_udp_port     = 16'h1234;     // remote port (src-port filter)

reg  [63:0] udp_rx_axis_tdata = 64'd0;
reg  [7:0]  udp_rx_axis_tkeep = 8'd0;
reg         udp_rx_axis_tvalid = 1'b0;
reg         udp_rx_axis_tlast = 1'b0;
wire        udp_rx_axis_tready;
reg         udp_rx_axis_tuser = 1'b0;

wire [63:0] app_rx_axis_tdata;
wire [7:0]  app_rx_axis_tkeep;
wire        app_rx_axis_tvalid;
wire        app_rx_axis_tlast;
wire        app_rx_axis_tuser;
reg         app_rx_axis_tready = 1'b1;

udp_rx dut (
    .recv_dst_ip_addr  (recv_dst_ip_addr),
    .recv_src_ip_addr  (recv_src_ip_addr),
    .local_udp_port    (local_udp_port),
    .dst_udp_port      (dst_udp_port),
    .clk               (clk),
    .rst               (rst),
    .udp_rx_axis_tdata (udp_rx_axis_tdata),
    .udp_rx_axis_tkeep (udp_rx_axis_tkeep),
    .udp_rx_axis_tvalid(udp_rx_axis_tvalid),
    .udp_rx_axis_tlast (udp_rx_axis_tlast),
    .udp_rx_axis_tready(udp_rx_axis_tready),
    .udp_rx_axis_tuser (udp_rx_axis_tuser),
    .app_rx_axis_tdata (app_rx_axis_tdata),
    .app_rx_axis_tkeep (app_rx_axis_tkeep),
    .app_rx_axis_tvalid(app_rx_axis_tvalid),
    .app_rx_axis_tlast (app_rx_axis_tlast),
    .app_rx_axis_tuser (app_rx_axis_tuser),
    .app_rx_axis_tready(app_rx_axis_tready)
);

always #CLK_HALF clk = ~clk;

// --------------------------------------------------------------------------
// scoreboard
// --------------------------------------------------------------------------
integer errors = 0;

reg [7:0] frame_bytes [0:8191];  // reference: UDP header + payload

// Continuous output monitor: a handshake is captured on every cycle it
// happens, so beats can never be lost while the stimulus side is busy.  The
// queued beats are drained frame by frame by read_frame().
localparam integer Q_DEPTH = 8192;
reg [63:0]       q_data [0:Q_DEPTH-1];
reg [7:0]        q_keep [0:Q_DEPTH-1];
reg              q_last [0:Q_DEPTH-1];
reg              q_user [0:Q_DEPTH-1];
integer          q_wr = 0;
integer          q_rd = 0;

always @(posedge clk) begin
    if (app_rx_axis_tvalid && app_rx_axis_tready) begin
        q_data[q_wr] = app_rx_axis_tdata;
        q_keep[q_wr] = app_rx_axis_tkeep;
        q_last[q_wr] = app_rx_axis_tlast;
        q_user[q_wr] = app_rx_axis_tuser;
        q_wr = q_wr + 1;
    end
end

// evidence that the input handshake really throttled (delay line frozen)
reg saw_input_stall = 1'b0;
always @(posedge clk) begin
    if (udp_rx_axis_tvalid && !udp_rx_axis_tready)
        saw_input_stall <= 1'b1;
end

// --------------------------------------------------------------------------
// output backpressure stimulus: random (~50%) or slow (1 in 8) app_rx_axis_tready
// --------------------------------------------------------------------------
reg bp_enable = 1'b0;
reg bp_slow   = 1'b0;
reg [15:0] lfsr = 16'hACE1;
reg [2:0]  bp_cnt = 3'd0;
always @(negedge clk) begin
    bp_cnt <= bp_cnt + 3'd1;
    if (bp_enable) begin
        lfsr = {lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5], lfsr[15:1]};
        app_rx_axis_tready <= bp_slow ? (bp_cnt == 3'd0) : lfsr[0];
    end else begin
        app_rx_axis_tready <= 1'b1;
    end
end

// --------------------------------------------------------------------------
// helpers
// --------------------------------------------------------------------------

// 1's complement carry fold
function automatic [15:0] fold16(input [31:0] s);
begin
    while (s[31:16] != 0)
        s = s[15:0] + s[31:16];
    fold16 = s[15:0];
end
endfunction

// UDP checksum over pseudo-header + UDP header (checksum field = 0) + payload
function automatic [15:0] compute_udp_checksum(input integer plen);
    integer total, i;
    reg [31:0] sum;
    reg [15:0] w;
begin
    total = 8 + plen;
    sum = 32'd0;
    // pseudo-header
    sum = sum + recv_src_ip_addr[31:16] + recv_src_ip_addr[15:0];
    sum = sum + recv_dst_ip_addr[31:16] + recv_dst_ip_addr[15:0];
    sum = sum + 16'h0011;
    sum = sum + total[15:0];
    // UDP header (checksum field = 0)
    sum = sum + {frame_bytes[0], frame_bytes[1]};  // src port
    sum = sum + {frame_bytes[2], frame_bytes[3]};  // dst port
    sum = sum + {frame_bytes[4], frame_bytes[5]};  // length
    sum = sum + 16'h0000;                           // checksum placeholder
    // payload (big-endian 16-bit words, odd tail byte padded with zero)
    i = 8;
    while (i < total) begin
        w = (i + 1 < total) ? {frame_bytes[i], frame_bytes[i+1]} : {frame_bytes[i], 8'h00};
        sum = sum + w;
        i = i + 2;
    end
    compute_udp_checksum = ~fold16(sum);
end
endfunction

// pack 8 big-endian bytes starting at idx into a 64-bit word (byte0 -> bits[7:0])
function automatic [63:0] pack8(input integer idx);
    integer j;
    reg [63:0] w;
begin
    w = 64'd0;
    for (j = 0; j < 8; j = j + 1)
        w = w | ({56'd0, frame_bytes[idx + j]} << (8 * j));
    pack8 = w;
end
endfunction

task automatic fill_payload(input integer plen);
    integer i;
begin
    for (i = 0; i < plen; i = i + 1)
        frame_bytes[8 + i] = (i * 7 + 3) & 8'hff;
end
endtask

task automatic load_hello;
    string s = "hello, world";
    integer i;
begin
    for (i = 0; i < 12; i = i + 1)
        frame_bytes[8 + i] = s[i];
end
endtask

// race-free beat sender: drive on negedge with NBA, handshake on posedge
task automatic send_beat(input [63:0] data, input [7:0] keep, input last, input user);
    integer guard;
begin
    @(negedge clk);
    udp_rx_axis_tdata <= data;
    udp_rx_axis_tkeep <= keep;
    udp_rx_axis_tlast <= last;
    udp_rx_axis_tuser <= user;
    udp_rx_axis_tvalid <= 1'b1;
    guard = 0;
    @(posedge clk);
    while (!(udp_rx_axis_tvalid && udp_rx_axis_tready)) begin
        @(posedge clk);
        guard = guard + 1;
        if (guard > 5000) begin
            $display("SEND_TIMEOUT at %0t (tready=%b)", $time, udp_rx_axis_tready);
            $finish;
        end
    end
    udp_rx_axis_tvalid <= 1'b0;
end
endtask

// destination / source port written into the UDP header; defaults match the
// configured local and remote ports, overridden by the port-filter tests
reg [15:0] force_dst_port = 16'h5678;
reg [15:0] force_src_port = 16'h1234;

// checksum field selector
localparam integer CKSUM_OK   = 0,   // correct checksum
                   CKSUM_BAD  = 1,   // corrupted checksum
                   CKSUM_OMIT = 2;   // 0x0000: sender did not compute one

// send a UDP datagram: 8-byte header + plen-byte payload (payload pre-loaded
// in frame_bytes).  The datagram is not padded: ip_rx already removed the
// ethernet padding behind it, so tlast lands on the last payload byte.
task automatic send_udp(input integer plen, input integer cksum_mode, input integer frame_err);
    integer total, i, remain;
    reg [15:0] cksum;
begin
    total = 8 + plen;

    // UDP header (network byte order)
    frame_bytes[0] = force_src_port[15:8];
    frame_bytes[1] = force_src_port[7:0];
    frame_bytes[2] = force_dst_port[15:8];
    frame_bytes[3] = force_dst_port[7:0];
    frame_bytes[4] = total[15:8];     // length high
    frame_bytes[5] = total[7:0];      // length low
    frame_bytes[6] = 8'h00;           // checksum placeholder
    frame_bytes[7] = 8'h00;

    cksum = compute_udp_checksum(plen);
    if (cksum_mode == CKSUM_BAD)  cksum = cksum ^ 16'h8000;   // guaranteed corruption
    if (cksum_mode == CKSUM_OMIT) cksum = 16'h0000;           // no checksum
    frame_bytes[6] = cksum[15:8];
    frame_bytes[7] = cksum[7:0];

    // header word
    send_beat(pack8(0), 8'hff, 1'b0, 1'b0);

    // payload, no padding tail
    i = 8;
    while (i < total) begin
        remain = total - i;
        if (remain >= 8) begin
            // full word; if exactly 8 bytes remain this is also the final beat
            send_beat(pack8(i), 8'hff, (remain == 8) ? 1'b1 : 1'b0,
                      ((remain == 8) && frame_err) ? 1'b1 : 1'b0);
            i = i + 8;
        end else begin
            send_beat(pack8(i), (8'b1 << remain) - 8'b1, 1'b1, frame_err);
            i = total;
        end
    end
end
endtask

task automatic recv_word(output [63:0] d, output [7:0] k, output l, output u);
    integer guard;
begin
    guard = 0;
    while (q_rd == q_wr) begin
        @(posedge clk);
        guard = guard + 1;
        if (guard > 20000) begin
            $display("RECV_TIMEOUT at %0t (valid=%b ready=%b)", $time, app_rx_axis_tvalid, app_rx_axis_tready);
            $finish;
        end
    end
    d = q_data[q_rd];
    k = q_keep[q_rd];
    l = q_last[q_rd];
    u = q_user[q_rd];
    q_rd = q_rd + 1;
end
endtask

// drain one datagram from the app interface into rx_bytes
reg [7:0] rx_bytes [0:8191];  // received payload bytes
integer   rx_count;
integer   rx_beats;
reg       rx_last_user;

task automatic read_frame;
    reg [63:0] d; reg [7:0] k; reg l; reg u;
    integer i;
begin
    rx_count = 0;
    rx_beats = 0;
    l = 1'b0;
    while (!l) begin
        recv_word(d, k, l, u);
        rx_beats = rx_beats + 1;
        for (i = 0; i < 8; i = i + 1) begin
            if (k[i]) begin
                rx_bytes[rx_count] = d[8*i +: 8];
                rx_count = rx_count + 1;
            end
        end
    end
    rx_last_user = u;
end
endtask

// return 0 on match, 1 on mismatch
function automatic integer check_frame(input integer plen, input [80:0] tag);
    integer i, exp_beats;
begin
    exp_beats = (plen + 7) / 8;
    if (rx_beats != exp_beats) begin
        $display("ERROR %0s len=%0d: %0d beat(s), expected %0d", tag, plen, rx_beats, exp_beats);
        return 1;
    end
    if (rx_count != plen) begin
        $display("ERROR %0s len=%0d: received %0d bytes, expected %0d", tag, plen, rx_count, plen);
        return 1;
    end
    for (i = 0; i < plen; i = i + 1) begin
        if (rx_bytes[i] !== frame_bytes[8 + i]) begin
            $display("ERROR %0s len=%0d: byte %0d got %h expected %h", tag, plen, i, rx_bytes[i], frame_bytes[8 + i]);
            return 1;
        end
    end
    return 0;
end
endfunction

// verify a datagram that must be reported as good: data matches, tuser is 0
function automatic integer check_good_frame(input integer plen, input [80:0] tag);
    integer e;
begin
    e = check_frame(plen, tag);
    if (rx_last_user !== 1'b0) begin
        $display("ERROR %0s len=%0d: tuser=%b expected 0", tag, plen, rx_last_user);
        e = e + 1;
    end
    return e;
end
endfunction

// wait 'cycles' cycles and make sure nothing shows up on the app interface
task automatic expect_silence(input integer cycles, input [80:0] tag);
    integer c;
    integer pending;
begin
    for (c = 0; c < cycles; c = c + 1)
        @(posedge clk);
    pending = q_wr - q_rd;
    if (pending == 0) $display("OK   %0s: no output", tag);
    else begin
        $display("ERROR %0s: %0d unexpected beat(s) on app_rx_axis", tag, pending);
        errors = errors + 1;
    end
end
endtask

// --------------------------------------------------------------------------
// main
// --------------------------------------------------------------------------
integer len, sweep_err, bp_err;

initial begin
    // reset
    repeat (6) @(posedge clk);
    rst <= 1'b0;
    repeat (2) @(posedge clk);

    // ============ 1. two "hello, world" datagrams, 1-cycle gap ============
    $display("--- test 1: continuous 'hello, world' x2 (1-cycle gap) ---");
    load_hello();
    send_udp(12, CKSUM_OK, 1'b0);       // 1st datagram
    repeat (1) @(posedge clk);          // exactly one idle clock between frames
    send_udp(12, CKSUM_OK, 1'b0);       // 2nd datagram (payload still in frame_bytes)
    read_frame();
    if (check_good_frame(12, "cont1")) errors = errors + 1;
    else $display("OK   cont1: 1st datagram verified");
    read_frame();
    if (check_good_frame(12, "cont2")) errors = errors + 1;
    else $display("OK   cont2: 2nd datagram verified");

    // ============ 2. checksum OK -> tuser low =============================
    $display("--- test 2: 'hello, world' checksum OK ---");
    load_hello();
    send_udp(12, CKSUM_OK, 1'b0);
    read_frame();
    if (check_good_frame(12, "hello.ok")) errors = errors + 1;
    else $display("OK   hello.ok: 12-byte payload verified, tuser low");

    // ============ 3. checksum BAD -> tuser high, data intact ==============
    $display("--- test 3: 'hello, world' checksum BAD ---");
    load_hello();
    send_udp(12, CKSUM_BAD, 1'b0);
    read_frame();
    if (check_frame(12, "hello.bad")) errors = errors + 1;
    else $display("OK   hello.bad: 12-byte payload verified (data intact despite bad checksum)");
    if (rx_last_user !== 1'b1) begin
        $display("ERROR hello.bad: tuser=%b expected 1 (checksum fail)", rx_last_user);
        errors = errors + 1;
    end else begin
        $display("OK   hello.bad: tuser high (checksum fail)");
    end

    // ============ 4. checksum not computed (0x0000) -> accepted ===========
    $display("--- test 4: checksum field 0x0000 (not computed) ---");
    load_hello();
    send_udp(12, CKSUM_OMIT, 1'b0);
    read_frame();
    if (check_good_frame(12, "cksum.omit")) errors = errors + 1;
    else $display("OK   cksum.omit: 12-byte payload verified, tuser low (no checksum)");

    // ============ 5. MAC/IP frame error -> tuser high =====================
    $display("--- test 5: udp_rx_axis_tuser=1 on the frame tail ---");
    load_hello();
    send_udp(12, CKSUM_OK, 1'b1);
    read_frame();
    if (check_frame(12, "frame.err")) errors = errors + 1;
    else $display("OK   frame.err: 12-byte payload verified (input frame error)");
    if (rx_last_user !== 1'b1) begin
        $display("ERROR frame.err: tuser=%b expected 1 (input frame error)", rx_last_user);
        errors = errors + 1;
    end else begin
        $display("OK   frame.err: tuser high (input frame error forwarded)");
    end

    // ============ 6. payload length sweep 9..74 bytes =====================
    $display("--- test 6: payload length sweep 9..74 ---");
    sweep_err = 0;
    for (len = 9; len <= 74; len = len + 1) begin
        fill_payload(len);
        send_udp(len, CKSUM_OK, 1'b0);
        read_frame();
        sweep_err = sweep_err + check_good_frame(len, "sweep");
    end
    if (sweep_err == 0) begin
        $display("OK   sweep: payload lengths 9..74 all verified (data/tkeep/tlast)");
    end else begin
        $display("ERROR sweep: %0d length(s) failed", sweep_err);
        errors = errors + 1;
    end

    // ============ 7. destination-port mismatch is dropped =================
    $display("--- test 7: dst-port mismatch is dropped ---");
    force_dst_port = 16'h9999;          // not the local port
    load_hello();
    send_udp(12, CKSUM_OK, 1'b0);
    expect_silence(64, "port-filter.dst");
    force_dst_port = 16'h5678;          // restore local port
    load_hello();
    send_udp(12, CKSUM_OK, 1'b0);
    read_frame();
    if (check_good_frame(12, "port.ok")) errors = errors + 1;
    else $display("OK   port.ok: matching datagram still received after a drop");

    // ============ 8. source-port mismatch is dropped ======================
    $display("--- test 8: src-port mismatch is dropped ---");
    force_src_port = 16'h4321;          // not the configured remote port
    load_hello();
    send_udp(12, CKSUM_OK, 1'b0);
    expect_silence(64, "port-filter.src");
    force_src_port = 16'h1234;
    load_hello();
    send_udp(12, CKSUM_OK, 1'b0);
    read_frame();
    if (check_good_frame(12, "srcport.ok")) errors = errors + 1;
    else $display("OK   srcport.ok: matching datagram still received after a drop");

    // ============ 9. output backpressure ==================================
    $display("--- test 9: output backpressure ---");
    bp_enable = 1'b1;
    bp_err = 0;
    fill_payload(9);  send_udp(9,  CKSUM_OK, 1'b0); read_frame(); bp_err = bp_err + check_good_frame(9,  "bp9");
    fill_payload(40); send_udp(40, CKSUM_OK, 1'b0); read_frame(); bp_err = bp_err + check_good_frame(40, "bp40");
    fill_payload(74); send_udp(74, CKSUM_OK, 1'b0); read_frame(); bp_err = bp_err + check_good_frame(74, "bp74");
    bp_enable = 1'b0;
    if (bp_err == 0) begin
        $display("OK   backpressure: 3 datagrams verified with random app_rx_axis_tready");
    end else begin
        $display("ERROR backpressure: %0d datagram(s) failed", bp_err);
        errors = errors + 1;
    end

    // ============ 10. datagram longer than the output FIFO ================
    // 5000 payload bytes -> 5008 bytes on the wire -> 626 beats, more than the
    // 512-entry output FIFO, so sending and receiving must overlap and the
    // input handshake must throttle once the FIFO fills.
    $display("--- test 10: 5000-byte datagram (> 512-entry output FIFO) ---");
    bp_enable = 1'b1;
    bp_slow   = 1'b1;      // reader is much slower than the ingress path
    saw_input_stall = 1'b0;
    fill_payload(5000);
    fork
        send_udp(5000, CKSUM_OK, 1'b0);
        read_frame();
    join
    bp_enable = 1'b0;
    bp_slow   = 1'b0;
    if (check_good_frame(5000, "long")) errors = errors + 1;
    else $display("OK   long: 5000-byte datagram verified through a full output FIFO");
    if (saw_input_stall)
        $display("OK   long: input handshake throttled by the output FIFO");
    else begin
        $display("ERROR long: udp_rx_axis_tready never deasserted");
        errors = errors + 1;
    end

    // ============ 11. nothing left behind ================================
    repeat (16) @(posedge clk);
    if (q_wr != q_rd) begin
        $display("ERROR leftover: %0d beat(s) still queued", q_wr - q_rd);
        errors = errors + 1;
    end else begin
        $display("OK   leftover: no stray beats on app_rx_axis");
    end

    // ============ summary =================================================
    if (errors == 0)
        $display("=== ALL TESTS PASSED ===");
    else
        $display("=== FAILED: %0d error(s) ===", errors);
    $finish;
end

initial begin
    #5000000;  // 5 ms watchdog
    $display("GLOBAL TIMEOUT (testbench hung)");
    $finish;
end

endmodule

`resetall
