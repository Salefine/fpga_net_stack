/****************************************************************************
 * @file    tb_udp_rx.sv
 * @brief   Self-checking testbench for udp_rx
 *
 *          Covers:
 *            1. "hello, world" frame, checksum pass/fail
 *               -> app_rx_axis_tuser low / high on the final beat
 *               (padding is stripped in both cases)
 *            2. payload length sweep 9..74 bytes (one per byte)
 *               -> received data must match, padding removed
 *            3. output backpressure: random app_rx_axis_tready must not
 *               corrupt the received data
 *
 *          Note: the sweep exercises payload lengths 9..74 bytes
 *          (UDP length field = 17..82). Frames shorter than 46 bytes total
 *          are padded with zeros to simulate L2 minimum-size padding.
 *
 * @copyright Copyright (c) 2026
 * ***************************************************************************/

`timescale 1ns / 1ps
`default_nettype none

module tb_udp_rx;

localparam integer CLK_HALF = 5;   // ns -> 100 MHz
localparam integer PAD_TO   = 46;  // pad UDP segment up to 46 B (L2 min data size)

reg clk = 1'b0;
reg rst = 1'b1;

reg [31:0] recv_dst_ip_addr = 32'hC0A80001; // 192.168.0.1 (local)
reg [31:0] recv_src_ip_addr = 32'hC0A80002; // 192.168.0.2 (remote)
reg [15:0] local_udp_port   = 16'h5678;     // local port (dst-port filter)

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

reg [7:0] frame_bytes [0:127];  // reference: header + payload (+zero padding)
reg [7:0] rx_bytes    [0:127];  // received payload bytes
integer   rx_count;
reg       rx_last_user;

// --------------------------------------------------------------------------
// output backpressure stimulus (LFSR-driven, ~50% duty cycle)
// --------------------------------------------------------------------------
reg bp_enable = 1'b0;
reg [15:0] lfsr = 16'hACE1;
always @(negedge clk) begin
    if (bp_enable) begin
        lfsr = {lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5], lfsr[15:1]};
        app_rx_axis_tready <= lfsr[0];
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
        if (guard > 200) begin
            $display("SEND_TIMEOUT at %0t (tready=%b)", $time, udp_rx_axis_tready);
            $finish;
        end
    end
    udp_rx_axis_tvalid <= 1'b0;
end
endtask

// destination port written into the UDP header; defaults to the local port,
// overridden by the port-filter test
reg [15:0] force_dst_port = 16'h5678;

// send a UDP segment: 8-byte header + plen-byte payload (payload pre-loaded in
// frame_bytes), zero-padded up to pad_to bytes total if shorter
task automatic send_udp(input integer plen, input integer checksum_ok, input integer pad_to);
    integer total, wire_len, i, remain;
    reg [15:0] cksum;
begin
    total = 8 + plen;

    // UDP header (network byte order)
    frame_bytes[0] = 8'h12;           // src port 0x1234
    frame_bytes[1] = 8'h34;
    frame_bytes[2] = force_dst_port[15:8];  // dst port
    frame_bytes[3] = force_dst_port[7:0];
    frame_bytes[4] = total[15:8];     // length high
    frame_bytes[5] = total[7:0];      // length low
    frame_bytes[6] = 8'h00;           // checksum placeholder
    frame_bytes[7] = 8'h00;

    cksum = compute_udp_checksum(plen);
    if (!checksum_ok)
        cksum = cksum ^ 16'h8000;     // guaranteed corruption
    frame_bytes[6] = cksum[15:8];
    frame_bytes[7] = cksum[7:0];

    // zero the padding region
    for (i = total; i < 128; i = i + 1)
        frame_bytes[i] = 8'h00;

    // header word
    send_beat(pack8(0), 8'hff, 1'b0, 1'b0);

    // payload + padding
    wire_len = (total < pad_to) ? pad_to : total;
    i = 8;
    while (i < wire_len) begin
        remain = wire_len - i;
        if (remain >= 8) begin
            // full word; if exactly 8 bytes remain this is also the final beat
            send_beat(pack8(i), 8'hff, (remain == 8) ? 1'b1 : 1'b0, 1'b0);
            i = i + 8;
        end else begin
            send_beat(pack8(i), (8'b1 << remain) - 8'b1, 1'b1, 1'b0);
            i = wire_len;
        end
    end
end
endtask

task automatic recv_word(output [63:0] d, output [7:0] k, output l, output u);
    integer guard;
begin
    guard = 0;
    do begin
        @(posedge clk);
        guard = guard + 1;
        if (guard > 2000) begin
            $display("RECV_TIMEOUT at %0t (valid=%b ready=%b)", $time, app_rx_axis_tvalid, app_rx_axis_tready);
            $finish;
        end
    end while (!(app_rx_axis_tvalid && app_rx_axis_tready));
    d = app_rx_axis_tdata;
    k = app_rx_axis_tkeep;
    l = app_rx_axis_tlast;
    u = app_rx_axis_tuser;
end
endtask

// drain one frame from the app interface into rx_bytes
task automatic read_frame;
    reg [63:0] d; reg [7:0] k; reg l; reg u;
    integer i;
begin
    rx_count = 0;
    l = 1'b0;
    while (!l) begin
        recv_word(d, k, l, u);
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
    integer i;
begin
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

// verify a frame sent with a CORRECT checksum: data must match and tuser must be 0
function automatic integer check_good_frame(input integer plen, input [80:0] tag);
    integer e;
begin
    e = check_frame(plen, tag);
    if (rx_last_user !== 1'b0) begin
        $display("ERROR %0s len=%0d: tuser=%b expected 0 (checksum should pass)", tag, plen, rx_last_user);
        e = e + 1;
    end
    return e;
end
endfunction

// --------------------------------------------------------------------------
// main
// --------------------------------------------------------------------------
integer i, len, sweep_err, bp_err;

initial begin
    // reset
    repeat (6) @(posedge clk);
    rst <= 1'b0;
    repeat (2) @(posedge clk);

    // ============ 0. continuous: two "hello, world" frames, 1-cycle gap ============
    $display("--- test 0: continuous 'hello, world' x2 (1-cycle gap) ---");
    load_hello();
    send_udp(12, 1, PAD_TO);       // 1st frame
    repeat (1) @(posedge clk);     // exactly one idle clock between frames
    send_udp(12, 1, PAD_TO);       // 2nd frame (payload still in frame_bytes)

    read_frame();
    if (check_good_frame(12, "cont1")) errors = errors + 1;
    else $display("OK   cont1: 1st frame verified");
    read_frame();
    if (check_good_frame(12, "cont2")) errors = errors + 1;
    else $display("OK   cont2: 2nd frame verified");

    // ============ 1. "hello, world" : checksum OK -> tuser low ============
    $display("--- test 1: 'hello, world' checksum OK ---");
    load_hello();
    send_udp(12, 1, PAD_TO);
    read_frame();
    if (check_frame(12, "hello.ok"))
        errors = errors + 1;
    else
        $display("OK   hello.ok: 12-byte payload verified");
    if (rx_last_user !== 1'b0) begin
        $display("ERROR hello.ok: tuser=%b expected 0 (checksum pass)", rx_last_user);
        errors = errors + 1;
    end else begin
        $display("OK   hello.ok: tuser low (checksum pass)");
    end

    // ============ 2. "hello, world" : checksum BAD -> tuser high ============
    $display("--- test 2: 'hello, world' checksum BAD ---");
    load_hello();
    send_udp(12, 0, PAD_TO);
    read_frame();
    if (check_frame(12, "hello.bad"))
        errors = errors + 1;
    else
        $display("OK   hello.bad: 12-byte payload verified (data intact despite bad checksum)");
    if (rx_last_user !== 1'b1) begin
        $display("ERROR hello.bad: tuser=%b expected 1 (checksum fail)", rx_last_user);
        errors = errors + 1;
    end else begin
        $display("OK   hello.bad: tuser high (checksum fail)");
    end

    // ============ 3. payload length sweep 9..74 bytes ============
    $display("--- test 3: payload length sweep 9..74 ---");
    sweep_err = 0;
    for (len = 9; len <= 74; len = len + 1) begin
        fill_payload(len);
        send_udp(len, 1, PAD_TO);
        read_frame();
        sweep_err = sweep_err + check_good_frame(len, "sweep");
    end
    if (sweep_err == 0) begin
        $display("OK   sweep: payload lengths 9..74 all verified (padding stripped)");
    end else begin
        $display("ERROR sweep: %0d length(s) failed", sweep_err);
        errors = errors + 1;
    end

    // ============ 4. output backpressure ============
    $display("--- test 4: output backpressure ---");
    bp_enable = 1'b1;
    bp_err = 0;
    fill_payload(9);  send_udp(9,  1, PAD_TO); read_frame(); bp_err = bp_err + check_good_frame(9,  "bp9");
    fill_payload(40); send_udp(40, 1, PAD_TO); read_frame(); bp_err = bp_err + check_good_frame(40, "bp40");
    fill_payload(74); send_udp(74, 1, PAD_TO); read_frame(); bp_err = bp_err + check_good_frame(74, "bp74");
    bp_enable = 1'b0;
    if (bp_err == 0) begin
        $display("OK   backpressure: 3 frames verified with random app_rx_axis_tready");
    end else begin
        $display("ERROR backpressure: %0d frame(s) failed", bp_err);
        errors = errors + 1;
    end

    // ============ 5. destination-port filter ============
    $display("--- test 5: dst-port mismatch is dropped ---");
    begin : t5
        integer quiet = 1;
        force_dst_port = 16'h9999;      // not the local port
        load_hello();
        send_udp(12, 1, PAD_TO);
        for (int c = 0; c < 64; c = c + 1) begin
            @(posedge clk);
            if (app_rx_axis_tvalid) quiet = 0;
        end
        if (quiet) $display("OK   port-filter: mismatched datagram produced no output");
        else begin
            $display("ERROR port-filter: data appeared on app_rx for a wrong dst port");
            errors = errors + 1;
        end
        force_dst_port = 16'h5678;      // restore local port
        send_udp(12, 1, PAD_TO);
        read_frame();
        if (check_good_frame(12, "port.ok")) errors = errors + 1;
        else $display("OK   port.ok: matching datagram still received after a drop");
    end

    // ============ summary ============
    if (errors == 0)
        $display("=== ALL TESTS PASSED ===");
    else
        $display("=== FAILED: %0d error(s) ===", errors);
    $finish;
end

initial begin
    #1000000;  // 1 ms watchdog
    $display("GLOBAL TIMEOUT (testbench hung)");
    $finish;
end

endmodule

`resetall
