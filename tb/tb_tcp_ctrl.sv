`timescale 1ns / 1ps

/****************************************************************************
 * @file    tb_tcp_ctrl.sv
 * @brief   Self-checking testbench for rtl/tcp/tcp_ctrl.v
 *
 * tcp_ctrl implements the TCP control path of the stack. The FPGA acts as
 * the TCP server:
 *   - three-way handshake : client SYN   -> server SYN+ACK
 *                           client ACK   -> tcp_link = 1   (3rd message)
 *   - four-way close      : client FIN   -> server ACK
 *                                         -> server FIN+ACK
 *                           client ACK   -> tcp_link = 0   (4th message)
 *
 * The module is verified in isolation. The testbench drives the handshake /
 * close strobes (tcp_handshake_syn / tcp_handshake_ack / tcp_close_fin /
 * tcp_close_ack) together with the client sequence / ack numbers, then
 * collects the server replies from the tcp_ctrl_axis_* stream and checks
 * every TCP header field against the RFC 793 expectations: ports, sequence
 * number, ack number, data offset, flags, window, checksum (pseudo header +
 * 20 byte header) and the link state transitions.
 *
 * Tests:
 *   1. handshake : SYN -> SYN+ACK (link stays low), 3rd ACK -> link high
 *   2. close     : FIN -> server ACK, then server FIN+ACK (from clean reset)
 *
 * Run (Vivado xsim, from the repository root):
 *   xvlog -sv rtl/tcp/tcp_ctrl.v tb/tb_tcp_ctrl.sv
 *   xelab tb_tcp_ctrl -s tb_tcp_ctrl_sim -O0 -mt off
 *   xsim tb_tcp_ctrl_sim -runall
 * ***************************************************************************/

module tb_tcp_ctrl;

// ---------------------------------------------------------------------------
// configuration
// ---------------------------------------------------------------------------
localparam CLOCK_PERIOD  = 100;       // 10 MHz, slow clock -> readable waves
localparam DATA_WIDTH    = 64;
localparam KEEP_WIDTH    = DATA_WIDTH / 8;

localparam RCV_TIMEOUT_CYC = 1000;    // cycles to wait for a reply packet
localparam ACK_HOLD_CYC    = 12;      // hold the ACK strobe so a polling FSM sees it

// FPGA is the server -> src = server, dst = client. The endpoint values are
// reconfigurable per test case, so the checksum reference tracks them.
logic [31:0] SERVER_IP   = 32'hC0A8010A;   // 192.168.1.10
logic [31:0] CLIENT_IP   = 32'hC0A80114;   // 192.168.1.20
logic [15:0] SERVER_PORT = 16'h0050;       // 80
logic [15:0] CLIENT_PORT = 16'h3039;       // 12345
localparam [31:0] SERVER_ISN  = 32'h00005000;   // hardcoded inside tcp_ctrl

localparam [7:0] FLAG_SYN_ACK = 8'h12;
localparam [7:0] FLAG_ACK     = 8'h10;
localparam [7:0] FLAG_FIN_ACK = 8'h11;

// ---------------------------------------------------------------------------
// clock / reset (rst is active high, like inside the DUT)
// ---------------------------------------------------------------------------
logic clk = 1'b0;
logic rst = 1'b1;

always #(CLOCK_PERIOD/2) clk = ~clk;

// ---------------------------------------------------------------------------
// DUT inputs
// ---------------------------------------------------------------------------
logic [15:0] tcp_src_port   = SERVER_PORT;
logic [15:0] tcp_dst_port   = CLIENT_PORT;
logic [31:0] tcp_src_ipaddr = SERVER_IP;
logic [31:0] tcp_dst_ipaddr = CLIENT_IP;
logic        tcp_handshake_syn = 1'b0;
logic        tcp_handshake_ack = 1'b0;
logic        tcp_close_fin     = 1'b0;
logic        tcp_close_ack     = 1'b0;
logic [31:0] tcp_rx_seq = '0;
logic [31:0] tcp_rx_ack = '0;
logic        tcp_ctrl_axis_tready = 1'b1;   // no back-pressure in the basic test

// ---------------------------------------------------------------------------
// DUT outputs
// ---------------------------------------------------------------------------
wire [63:0] tcp_ctrl_axis_tdata;
wire [7:0]  tcp_ctrl_axis_tkeep;
wire        tcp_ctrl_axis_tvalid;
wire        tcp_ctrl_axis_tlast;
wire        tcp_link;

tcp_ctrl dut (
    .clk                  (clk                 ),
    .rst                  (rst                 ),
    .tcp_src_port         (tcp_src_port        ),
    .tcp_dst_port         (tcp_dst_port        ),
    .tcp_src_ipaddr       (tcp_src_ipaddr      ),
    .tcp_dst_ipaddr       (tcp_dst_ipaddr      ),
    .tcp_handshake_syn    (tcp_handshake_syn   ),
    .tcp_handshake_ack    (tcp_handshake_ack   ),
    .tcp_close_fin        (tcp_close_fin       ),
    .tcp_close_ack        (tcp_close_ack       ),
    .tcp_rx_seq           (tcp_rx_seq          ),
    .tcp_rx_ack           (tcp_rx_ack          ),
    .tcp_ctrl_axis_tdata  (tcp_ctrl_axis_tdata ),
    .tcp_ctrl_axis_tkeep  (tcp_ctrl_axis_tkeep ),
    .tcp_ctrl_axis_tvalid (tcp_ctrl_axis_tvalid),
    .tcp_ctrl_axis_tlast  (tcp_ctrl_axis_tlast ),
    .tcp_ctrl_axis_tready (tcp_ctrl_axis_tready),
    .tcp_link             (tcp_link            )
);

// ---------------------------------------------------------------------------
// scoreboard
// ---------------------------------------------------------------------------
integer pass_count = 0;
integer fail_count = 0;

task automatic check (input logic cond, input string msg);
    if (cond) begin
        pass_count = pass_count + 1;
        $display("[%0t]   PASS: %0s", $time, msg);
    end
    else begin
        fail_count = fail_count + 1;
        $display("[%0t]   FAIL: %0s", $time, msg);
    end
endtask

// shared packet buffers (declared here so the tasks below can use them)
logic [7:0] got_pkt [$];
logic [7:0] exp_pkt [$];
bit         timed_out;

// ---------------------------------------------------------------------------
// one's complement checksum helpers
// ---------------------------------------------------------------------------

// one's complement addition with full end-around carry handling
function automatic [15:0] ones_add (input [15:0] a, input [15:0] b);
    logic [31:0] s;
    s = a + b;
    while (s > 32'hFFFF)
        s = (s & 32'hFFFF) + (s >> 16);
    return s[15:0];
endfunction

// one's complement sum over the TCP pseudo header + a byte queue
// (the queue is read as big endian 16 bit words, odd tails padded with 0)
function automatic [15:0] tcp_sum (input logic [7:0] b [$]);
    logic [15:0] acc;
    acc = 16'h0000;
    acc = ones_add(acc, SERVER_IP[31:16]);
    acc = ones_add(acc, SERVER_IP[15:0]);
    acc = ones_add(acc, CLIENT_IP[31:16]);
    acc = ones_add(acc, CLIENT_IP[15:0]);
    acc = ones_add(acc, 16'h0006);           // protocol = TCP
    acc = ones_add(acc, 16'h0014);           // TCP length = 20
    for (integer i = 0; i < b.size(); i = i + 2)
        acc = ones_add(acc, (i + 1 < b.size()) ? {b[i], b[i+1]} : {b[i], 8'h00});
    return acc;
endfunction

// RFC 793 checksum of a 20 byte TCP header whose checksum field is zero
function automatic [15:0] tcp_checksum (input logic [7:0] b [$]);
    logic [15:0] s;
    s = ~tcp_sum(b);
    return (s == 16'h0000) ? 16'hFFFF : s;
endfunction

// build a 20 byte TCP header with the checksum field set to zero
function automatic void build_header (output logic [7:0] h [$],
                                      input  [15:0] sport,
                                      input  [15:0] dport,
                                      input  [31:0] seqn,
                                      input  [31:0] ackn,
                                      input  [7:0]  flags,
                                      input  [15:0] window);
    h.delete();
    h.push_back(sport[15:8]); h.push_back(sport[7:0]);
    h.push_back(dport[15:8]); h.push_back(dport[7:0]);
    h.push_back(seqn[31:24]); h.push_back(seqn[23:16]);
    h.push_back(seqn[15:8]);  h.push_back(seqn[7:0]);
    h.push_back(ackn[31:24]); h.push_back(ackn[23:16]);
    h.push_back(ackn[15:8]);  h.push_back(ackn[7:0]);
    h.push_back(8'h50);       // data offset = 5, reserved = 0
    h.push_back(flags);
    h.push_back(window[15:8]); h.push_back(window[7:0]);
    h.push_back(8'h00); h.push_back(8'h00);   // checksum (filled below)
    h.push_back(8'h00); h.push_back(8'h00);   // urgent pointer
endfunction

// expected 20 byte header, checksum field filled in
function automatic void expected_header (output logic [7:0] h [$],
                                         input  [15:0] sport,
                                         input  [15:0] dport,
                                         input  [31:0] seqn,
                                         input  [31:0] ackn,
                                         input  [7:0]  flags,
                                         input  [15:0] window);
    logic [15:0] cks;
    build_header(h, sport, dport, seqn, ackn, flags, window);
    cks = tcp_checksum(h);
    h[16] = cks[15:8];
    h[17] = cks[7:0];
endfunction

// copy queue elements [lo .. hi-1] into a fresh queue
function automatic void slice_bytes (input  logic [7:0] q [$],
                                     input  integer lo,
                                     input  integer hi,
                                     output logic [7:0] r [$]);
    r.delete();
    for (integer i = lo; i < hi; i = i + 1)
        r.push_back(q[i]);
endfunction

function automatic string bytes_str (input logic [7:0] b [$], input integer max_n);
    string s;
    integer n;
    s = "";
    n = (b.size() < max_n) ? b.size() : max_n;
    for (integer i = 0; i < n; i = i + 1)
        s = {s, $sformatf("%02x ", b[i])};
    if (b.size() > n)
        s = {s, $sformatf("... (%0d bytes)", b.size())};
    return s;
endfunction

// ---------------------------------------------------------------------------
// stimulus helpers
// ---------------------------------------------------------------------------

// pulse tcp_handshake_syn for two cycles with the client ISN on tcp_rx_seq
task automatic drive_syn (input [31:0] client_isn);
    tcp_rx_seq        = client_isn;
    tcp_handshake_syn = 1'b1;
    @(posedge clk);
    @(posedge clk);
    tcp_handshake_syn = 1'b0;
endtask

// pulse tcp_handshake_ack: the client's 3rd handshake ACK
task automatic drive_handshake_ack (input [31:0] client_seq, input [31:0] client_ack);
    tcp_rx_seq        = client_seq;
    tcp_rx_ack        = client_ack;
    tcp_handshake_ack = 1'b1;
    repeat (ACK_HOLD_CYC) @(posedge clk);
    tcp_handshake_ack = 1'b0;
endtask

// pulse tcp_close_fin for two cycles: the client's FIN (1st close message)
task automatic drive_close_fin (input [31:0] client_seq, input [31:0] client_ack);
    tcp_rx_seq    = client_seq;
    tcp_rx_ack    = client_ack;
    tcp_close_fin = 1'b1;
    @(posedge clk);
    @(posedge clk);
    tcp_close_fin = 1'b0;
endtask

// pulse tcp_close_ack: the client's final ACK (4th close message)
task automatic drive_close_ack (input [31:0] client_seq, input [31:0] client_ack);
    tcp_rx_seq    = client_seq;
    tcp_rx_ack    = client_ack;
    tcp_close_ack = 1'b1;
    repeat (ACK_HOLD_CYC) @(posedge clk);
    tcp_close_ack = 1'b0;
endtask

// hold rst high for 20 cycles, then release and settle
task automatic reset_dut;
    rst = 1'b1;
    repeat (20) @(negedge clk);
    rst = 1'b0;
    repeat (20) @(negedge clk);
endtask

// collect one complete reply packet from the AXIS output (byte 0 first)
task automatic recv_packet (output logic [7:0] pkt [$],
                            output bit          timed_out,
                            input  integer      max_wait_cyc);
    integer guard;
    pkt.delete();
    timed_out = 1'b0;
    guard     = 0;
    while (tcp_ctrl_axis_tvalid !== 1'b1) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard >= max_wait_cyc) begin
            timed_out = 1'b1;
            return;
        end
    end
    forever begin
        for (integer lane = 0; lane < KEEP_WIDTH; lane = lane + 1)
            if (tcp_ctrl_axis_tkeep[lane])
                pkt.push_back(tcp_ctrl_axis_tdata[lane*8 +: 8]);
        if (tcp_ctrl_axis_tlast)
            break;
        @(negedge clk);
        guard = 0;
        while (tcp_ctrl_axis_tvalid !== 1'b1) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard >= max_wait_cyc) begin
                timed_out = 1'b1;
                return;
            end
        end
    end
    @(negedge clk);
endtask

// expect no packet on the output for `window_cyc` cycles; used to check the
// server waits for an ACK instead of spuriously sending more packets
task automatic expect_quiet (input string  tag,
                             input integer window_cyc);
    logic [7:0] pkt [$];
    bit         tout;
    recv_packet(pkt, tout, window_cyc);
    if (tout)
        check(1'b1, $sformatf("%0s: server stayed quiet for %0d cycles", tag, window_cyc));
    else
        check(1'b0, $sformatf("%0s: unexpected packet arrived within %0d cycles", tag, window_cyc));
endtask

// discard up to `max_packets` leftover packets from the output FIFO
task automatic drain_packets (input integer max_packets);
    logic [7:0] pkt [$];
    bit         tout;
    integer n;
    n = 0;
    while (n < max_packets) begin
        recv_packet(pkt, tout, 20);
        if (tout)
            break;
        n = n + 1;
    end
    $display("[%0t]   drained  : %0d leftover packet(s)", $time, n);
endtask

// verify every field of a collected TCP header against the expected 20 bytes
task automatic check_header (input string          tag,
                             input logic [7:0]     got [$],
                             input logic [7:0]     exp [$]);
    logic [7:0] hdr20 [$];
    logic [15:0] got_sport, got_dport, got_window, got_cks;
    logic [31:0] got_seq, got_ack;
    logic [7:0]  got_doff, got_flags;

    $display("[%0t]   pkt     : %s", $time, bytes_str(got, 24));

    check(got.size() == 20,
          $sformatf("%0s: packet length = 20 bytes (got %0d)", tag, got.size()));

    // fields available in the first 14 bytes (through the window)
    if (got.size() >= 14) begin
        got_sport  = {got[0],  got[1]};
        got_dport  = {got[2],  got[3]};
        got_seq    = {got[4],  got[5],  got[6],  got[7]};
        got_ack    = {got[8],  got[9],  got[10], got[11]};
        got_doff   = got[12];
        got_flags  = got[13];
        got_window = {got[14], got[15]};

        check(got_sport  == {exp[0], exp[1]},
              $sformatf("%0s: source port      = 0x%04x (got 0x%04x)", tag, {exp[0], exp[1]}, got_sport));
        check(got_dport  == {exp[2], exp[3]},
              $sformatf("%0s: destination port = 0x%04x (got 0x%04x)", tag, {exp[2], exp[3]}, got_dport));
        check(got_seq    == {exp[4], exp[5], exp[6], exp[7]},
              $sformatf("%0s: sequence number  = 0x%08x (got 0x%08x)", tag, {exp[4], exp[5], exp[6], exp[7]}, got_seq));
        check(got_ack    == {exp[8], exp[9], exp[10], exp[11]},
              $sformatf("%0s: ack number       = 0x%08x (got 0x%08x)", tag, {exp[8], exp[9], exp[10], exp[11]}, got_ack));
        check(got_doff   == exp[12],
              $sformatf("%0s: data offset      = 0x%02x (got 0x%02x)", tag, exp[12], got_doff));
        check(got_flags  == exp[13],
              $sformatf("%0s: flags            = 0x%02x (got 0x%02x)", tag, exp[13], got_flags));
        check(got_window == {exp[14], exp[15]},
              $sformatf("%0s: window           = 0x%04x (got 0x%04x)", tag, {exp[14], exp[15]}, got_window));
    end
    else begin
        check(1'b0, $sformatf("%0s: packet too short to extract the header (got %0d bytes)", tag, got.size()));
    end

    // checksum field lives in bytes 16-17
    if (got.size() >= 18) begin
        got_cks = {got[16], got[17]};
        check(got_cks == {exp[16], exp[17]},
              $sformatf("%0s: checksum field   = 0x%04x (got 0x%04x)", tag, {exp[16], exp[17]}, got_cks));
    end
    else begin
        check(1'b0, $sformatf("%0s: checksum field missing (packet only %0d bytes)", tag, got.size()));
    end

    // self consistency: one's complement sum over pseudo header + header
    // (including the received checksum field) must be 0xffff
    if (got.size() >= 20) begin
        slice_bytes(got, 0, 20, hdr20);
        check(tcp_sum(hdr20) == 16'hFFFF,
              $sformatf("%0s: checksum self-consistency (sum incl. cksum field = 0xffff, got 0x%04x)",
                        tag, tcp_sum(hdr20)));
    end
    else begin
        check(1'b0, $sformatf("%0s: checksum self-consistency not run (packet only %0d bytes)", tag, got.size()));
    end
endtask

// run one full connection lifecycle: three-way handshake then four-way close
task automatic run_connection (input string  tag,
                               input [31:0] client_isn,
                               input [31:0] srv_ip,
                               input [31:0] cli_ip,
                               input [15:0] srv_port,
                               input [15:0] cli_port);
    // reconfigure the endpoints and keep the checksum reference in sync
    SERVER_IP   = srv_ip;
    CLIENT_IP   = cli_ip;
    SERVER_PORT = srv_port;
    CLIENT_PORT = cli_port;
    tcp_src_ipaddr = srv_ip;
    tcp_dst_ipaddr = cli_ip;
    tcp_src_port   = srv_port;
    tcp_dst_port   = cli_port;

    // ---------------- three-way handshake ----------------
    drive_syn(client_isn);
    recv_packet(got_pkt, timed_out, RCV_TIMEOUT_CYC);
    check(!timed_out, $sformatf("%0s: server replied with SYN+ACK", tag));
    if (!timed_out) begin
        expected_header(exp_pkt, SERVER_PORT, CLIENT_PORT,
                        SERVER_ISN, client_isn + 32'd1, FLAG_SYN_ACK, 16'hFFFF);
        check_header($sformatf("%0s(SYN+ACK)", tag), got_pkt, exp_pkt);
    end

    repeat (4) @(negedge clk);
    check(tcp_link == 1'b0, $sformatf("%0s: tcp_link LOW before the 3rd ACK", tag));
    expect_quiet($sformatf("%0s: no extra packet before the 3rd ACK", tag), 20);

    drive_handshake_ack(client_isn + 32'd1, SERVER_ISN + 32'd1);
    repeat (4) @(negedge clk);
    check(tcp_link == 1'b1, $sformatf("%0s: tcp_link HIGH after the 3rd ACK", tag));

    // ---------------- four-way close ----------------
    drive_close_fin(client_isn + 32'd1, SERVER_ISN + 32'd1);

    recv_packet(got_pkt, timed_out, RCV_TIMEOUT_CYC);
    check(!timed_out, $sformatf("%0s: server sent the ACK reply", tag));
    if (!timed_out) begin
        expected_header(exp_pkt, SERVER_PORT, CLIENT_PORT,
                        SERVER_ISN + 32'd1, client_isn + 32'd2, FLAG_ACK, 16'hFFFF);
        check_header($sformatf("%0s(ACK)", tag), got_pkt, exp_pkt);
    end

    recv_packet(got_pkt, timed_out, RCV_TIMEOUT_CYC);
    check(!timed_out, $sformatf("%0s: server sent the FIN+ACK reply", tag));
    if (!timed_out) begin
        expected_header(exp_pkt, SERVER_PORT, CLIENT_PORT,
                        SERVER_ISN + 32'd1, client_isn + 32'd2, FLAG_FIN_ACK, 16'hFFFF);
        check_header($sformatf("%0s(FIN+ACK)", tag), got_pkt, exp_pkt);
    end

    drive_close_ack(client_isn + 32'd2, SERVER_ISN + 32'd2);
    repeat (4) @(negedge clk);
    check(tcp_link == 1'b0, $sformatf("%0s: tcp_link LOW after the 4th ACK", tag));
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
initial begin
    $timeformat(-9, 2, " ns", 12);
    reset_dut;

    // =====================================================================
    // Run several full connection lifecycles (three-way handshake then
    // four-way close) back to back, varying the client ISN and the endpoint
    // IPs/ports. No reset between cases, so re-connection is exercised too.
    // =====================================================================

    $display("[%0t] ===== CASE1: baseline connection =====", $time);
    run_connection("CASE1",
                   32'h12345678,
                   32'hC0A8010A, 32'hC0A80114,
                   16'h0050,     16'h3039);

    $display("[%0t] ===== CASE2: different client ISN =====", $time);
    run_connection("CASE2",
                   32'hAABBCCDD,
                   32'hC0A8010A, 32'hC0A80114,
                   16'h0050,     16'h3039);

    $display("[%0t] ===== CASE3: client ISN wraparound (0xFFFFFFFF) =====", $time);
    run_connection("CASE3",
                   32'hFFFFFFFF,
                   32'hC0A8010A, 32'hC0A80114,
                   16'h0050,     16'h3039);

    $display("[%0t] ===== CASE4: client ISN zero, different IPs/ports =====", $time);
    run_connection("CASE4",
                   32'h00000000,
                   32'h0A000001, 32'h0A000002,
                   16'h1F90,     16'hC350);

    $display("[%0t] ===== CASE5: different IPs/ports =====", $time);
    run_connection("CASE5",
                   32'h00010000,
                   32'hC0A80105, 32'hC0A80106,
                   16'h1234,     16'h5678);

    // =====================================================================
    if (fail_count == 0)
        $display("[%0t] ================ ALL %0d CHECKS PASSED ================", $time, pass_count);
    else
        $display("[%0t] ================ %0d/%0d CHECKS FAILED ================",
                 $time, fail_count, pass_count + fail_count);
    $finish;
end

// global watchdog
initial begin
    #(CLOCK_PERIOD * 200000);
    $display("FATAL: global timeout");
    $fatal(1);
end

endmodule

`default_nettype wire
