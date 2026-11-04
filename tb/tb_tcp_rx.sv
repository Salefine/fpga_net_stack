`timescale 1ns / 1ps

/****************************************************************************
 * @file    tb_tcp_rx.sv
 * @brief   Self-checking testbench for rtl/tcp/tcp_rx.v (control-path part)
 *
 * tcp_rx receives TCP segments from the IP layer (AXIS, 8 bytes/beat, byte 0
 * in lane 0) and classifies them into control packets. The FPGA is the TCP
 * server, so the testbench plays the client and sends the four control
 * messages of a connection:
 *
 *   1. client SYN        -> tcp_handshake_syn  (seq captured on tcp_rx_seq)
 *   2. client 3rd ACK    -> tcp_handshake_ack
 *   3. client FIN        -> tcp_close_fin
 *   4. client 4th ACK    -> tcp_close_ack
 *
 * Each packet is a 20 byte TCP header (no options) carried in three beats:
 *   beat0: bytes  0..7  (src port, dst port, seq)
 *   beat1: bytes  8..15 (ack, data offset, flags, window)
 *   beat2: bytes 16..19 (checksum, urgent pointer), tkeep=0x0f, tlast=1
 *
 * The checksum is computed in the testbench per RFC 793 (one's complement
 * sum over pseudo header + header) and the module must accept it and raise
 * the matching strobe only when the checksum is good.
 *
 * Tests:
 *   1. SYN                -> handshake_syn strobe + seq captured
 *   2. 3rd ACK            -> handshake_ack strobe
 *   3. FIN                -> close_fin strobe
 *   4. 4th ACK            -> close_ack strobe
 *   5. corrupted checksum -> no strobe
 *   6. two packets back-to-back -> both strobes (no cross-packet state leak)
 *
 * Run (Vivado xsim, from the repository root):
 *   xvlog -sv rtl/tcp/tcp_rx.v tb/tb_tcp_rx.sv
 *   xelab tb_tcp_rx -s tb_tcp_rx_sim -O0 -mt off -L xpm
 *   xsim tb_tcp_rx_sim -runall
 * ***************************************************************************/

module tb_tcp_rx;

localparam CLOCK_PERIOD = 100;   // 10 MHz

// FPGA is the server
localparam [31:0] SERVER_IP   = 32'hC0A8010A;   // 192.168.1.10
localparam [31:0] CLIENT_IP   = 32'hC0A80114;   // 192.168.1.20
localparam [15:0] SERVER_PORT = 16'h0050;       // 80
localparam [15:0] CLIENT_PORT = 16'h3039;       // 12345
localparam [31:0] CLIENT_ISN  = 32'h12345678;
localparam [31:0] SERVER_ISN  = 32'h00005000;

localparam [7:0] FLAG_SYN = 8'h02;
localparam [7:0] FLAG_FIN = 8'h01;
localparam [7:0] FLAG_ACK = 8'h10;

localparam STROBE_WIN_CYC = 60;   // window in which a strobe pulse must appear

// ---------------------------------------------------------------------------
// clock / reset (rst active high)
// ---------------------------------------------------------------------------
logic clk = 1'b0;
logic rst = 1'b1;
always #(CLOCK_PERIOD/2) clk = ~clk;

// ---------------------------------------------------------------------------
// DUT interfaces
// ---------------------------------------------------------------------------
logic [63:0] tcp_rx_axis_tdata = '0;
logic [7:0]  tcp_rx_axis_tkeep = '0;
logic        tcp_rx_axis_tvalid = 1'b0;
logic        tcp_rx_axis_tlast  = 1'b0;
logic        tcp_rx_axis_tuser  = 1'b0;
logic        app_rx_axis_tready = 1'b0;   // real app: stall until it reads
logic        tcp_link_up        = 1'b0;
logic [15:0] tcp_seg_len        = 16'd0;   // TCP段真实长度(不含padding)

wire         tcp_rx_axis_tready;
logic        tcp_handshake_syn;
logic        tcp_handshake_ack;
logic        tcp_close_fin;
logic        tcp_close_ack;
wire         tcp_trans_resp;
wire [15:0]  tcp_rx_paylen;
wire [31:0]  tcp_rx_seq;
wire [31:0]  tcp_rx_ack;
wire [63:0]  app_rx_axis_tdata;
wire [7:0]   app_rx_axis_tkeep;
wire         app_rx_axis_tvalid;
wire         app_rx_axis_tlast;
wire         app_rx_axis_tuser;

tcp_rx dut (
    .recv_dst_ip_addr   (SERVER_IP          ),
    .recv_src_ip_addr   (CLIENT_IP          ),
    .clk                (clk                ),
    .rst                (rst                ),
    .tcp_rx_axis_tdata  (tcp_rx_axis_tdata  ),
    .tcp_rx_axis_tkeep  (tcp_rx_axis_tkeep  ),
    .tcp_rx_axis_tvalid (tcp_rx_axis_tvalid ),
    .tcp_rx_axis_tlast  (tcp_rx_axis_tlast  ),
    .tcp_rx_axis_tready (tcp_rx_axis_tready ),
    .tcp_rx_axis_tuser  (tcp_rx_axis_tuser  ),
    .tcp_link_up        (tcp_link_up        ),
    .tcp_handshake_syn  (tcp_handshake_syn  ),
    .tcp_handshake_ack  (tcp_handshake_ack  ),
    .tcp_close_fin      (tcp_close_fin      ),
    .tcp_close_ack      (tcp_close_ack      ),
    .tcp_trans_resp     (tcp_trans_resp     ),
    .tcp_rx_paylen      (tcp_rx_paylen      ),
    .tcp_rx_seq         (tcp_rx_seq         ),
    .tcp_rx_ack         (tcp_rx_ack         ),
    .tcp_seg_len        (tcp_seg_len        ),
    .app_rx_axis_tdata  (app_rx_axis_tdata  ),
    .app_rx_axis_tkeep  (app_rx_axis_tkeep  ),
    .app_rx_axis_tvalid (app_rx_axis_tvalid ),
    .app_rx_axis_tlast  (app_rx_axis_tlast  ),
    .app_rx_axis_tuser  (app_rx_axis_tuser  ),
    .app_rx_axis_tready (app_rx_axis_tready )
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

// ---------------------------------------------------------------------------
// one's complement checksum helpers (RFC 793, end-around carry loop)
// ---------------------------------------------------------------------------
function automatic [15:0] ones_add (input [15:0] a, input [15:0] b);
    logic [31:0] s;
    s = a + b;
    while (s > 32'hFFFF)
        s = (s & 32'hFFFF) + (s >> 16);
    return s[15:0];
endfunction

function automatic [15:0] ones_sum (input logic [7:0] b [$]);
    logic [15:0] acc;
    acc = 16'h0000;
    for (integer i = 0; i < b.size(); i = i + 2)
        acc = ones_add(acc, (i + 1 < b.size()) ? {b[i], b[i+1]} : {b[i], 8'h00});
    return acc;
endfunction

// build a 20 byte TCP header with a correct checksum
function automatic void build_header (output logic [7:0] h [$],
                                      input [31:0] seqn,
                                      input [31:0] ackn,
                                      input [7:0]  flags,
                                      input [15:0] window);
    logic [15:0] acc;
    logic [15:0] ck;
    h.delete();
    h.push_back(CLIENT_PORT[15:8]); h.push_back(CLIENT_PORT[7:0]);
    h.push_back(SERVER_PORT[15:8]); h.push_back(SERVER_PORT[7:0]);
    h.push_back(seqn[31:24]); h.push_back(seqn[23:16]);
    h.push_back(seqn[15:8]);  h.push_back(seqn[7:0]);
    h.push_back(ackn[31:24]); h.push_back(ackn[23:16]);
    h.push_back(ackn[15:8]);  h.push_back(ackn[7:0]);
    h.push_back(8'h50);       // data offset = 5
    h.push_back(flags);
    h.push_back(window[15:8]); h.push_back(window[7:0]);
    h.push_back(8'h00); h.push_back(8'h00);   // checksum placeholder
    h.push_back(8'h00); h.push_back(8'h00);   // urgent pointer

    acc = 16'h0000;
    acc = ones_add(acc, CLIENT_IP[31:16]);
    acc = ones_add(acc, CLIENT_IP[15:0]);
    acc = ones_add(acc, SERVER_IP[31:16]);
    acc = ones_add(acc, SERVER_IP[15:0]);
    acc = ones_add(acc, 16'h0006);           // protocol TCP
    acc = ones_add(acc, 16'h0014);           // TCP length 20
    acc = ones_add(acc, ones_sum(h));
    ck  = ~acc;
    if (ck == 16'h0000) ck = 16'hFFFF;
    h[16] = ck[15:8];
    h[17] = ck[7:0];
endfunction

// ---------------------------------------------------------------------------
// stimulus helpers
// ---------------------------------------------------------------------------
task automatic reset_dut;
    rst = 1'b1;
    repeat (20) @(negedge clk);
    rst = 1'b0;
    repeat (20) @(negedge clk);
endtask

// drive a byte queue into tcp_rx as AXIS beats, appending 0x00 padding so the
// frame reaches 64 bytes (simulating the Ethernet minimum frame). tlast lands
// on the last padding beat, exactly like the MAC layer does. tready honored.
task automatic send_bytes (ref logic [7:0] data [$]);
    logic [7:0] f [$];
    f = data;
    while (f.size() < 64)
        f.push_back(8'h00);   // Ethernet padding

    for (integer i = 0; i < f.size(); i = i + 8) begin
        integer lanes;
        lanes = (f.size() - i) > 8 ? 8 : (f.size() - i);
        tcp_rx_axis_tdata = 64'h0;
        tcp_rx_axis_tkeep = 8'h00;
        for (integer j = 0; j < lanes; j = j + 1) begin
            tcp_rx_axis_tdata[j*8 +: 8] = f[i+j];
            tcp_rx_axis_tkeep[j]        = 1'b1;
        end
        tcp_rx_axis_tvalid = 1'b1;
        tcp_rx_axis_tlast  = (i + 8 >= f.size());
        do @(negedge clk); while (!tcp_rx_axis_tready);
    end

    tcp_rx_axis_tdata = '0;
    tcp_rx_axis_tkeep = '0;
    tcp_rx_axis_tvalid = 1'b0;
    tcp_rx_axis_tlast  = 1'b0;
    @(negedge clk);
endtask

// drive one 20 byte TCP control header (padded to 64 bytes by the MAC layer)
task automatic send_pkt (input [31:0] seqn,
                         input [31:0] ackn,
                         input [7:0]  flags,
                         input [15:0] window);
    logic [7:0] h [$];
    build_header(h, seqn, ackn, flags, window);
    $display("[%0t]   send    : seq=0x%08x ack=0x%08x flags=0x%02x cksum=0x%02x%02x",
             $time, seqn, ackn, flags, h[16], h[17]);
    tcp_seg_len = 16'd20;   // TCP段真实长度(不含padding)
    send_bytes(h);
endtask

// build a full TCP segment (header + options + payload) with a correct checksum
function automatic void build_segment (output logic [7:0] s [$],
                                       input  [31:0] seqn,
                                       input  [31:0] ackn,
                                       input  [7:0]  flags,
                                       input  [3:0]  doff,
                                       input  logic [7:0] pl [$]);
    logic [15:0] acc;
    logic [15:0] ck;
    s.delete();
    s.push_back(CLIENT_PORT[15:8]); s.push_back(CLIENT_PORT[7:0]);
    s.push_back(SERVER_PORT[15:8]); s.push_back(SERVER_PORT[7:0]);
    s.push_back(seqn[31:24]); s.push_back(seqn[23:16]);
    s.push_back(seqn[15:8]);  s.push_back(seqn[7:0]);
    s.push_back(ackn[31:24]); s.push_back(ackn[23:16]);
    s.push_back(ackn[15:8]);  s.push_back(ackn[7:0]);
    s.push_back({doff, 4'h0});         // data offset (x4 = header bytes)
    s.push_back(flags);
    s.push_back(8'hff); s.push_back(8'hff);   // window
    s.push_back(8'h00); s.push_back(8'h00);   // checksum placeholder
    s.push_back(8'h00); s.push_back(8'h00);   // urgent pointer
    for (integer i = 20; i < doff*4; i = i + 1)
        s.push_back(8'hEE);                   // option bytes
    for (integer i = 0; i < pl.size(); i = i + 1)
        s.push_back(pl[i]);

    acc = 16'h0000;
    acc = ones_add(acc, CLIENT_IP[31:16]);
    acc = ones_add(acc, CLIENT_IP[15:0]);
    acc = ones_add(acc, SERVER_IP[31:16]);
    acc = ones_add(acc, SERVER_IP[15:0]);
    acc = ones_add(acc, 16'h0006);
    acc = ones_add(acc, 16'(doff*4 + pl.size()));   // TCP length = header + payload
    acc = ones_add(acc, ones_sum(s));
    ck  = ~acc;
    if (ck == 16'h0000) ck = 16'hFFFF;
    s[16] = ck[15:8];
    s[17] = ck[7:0];
endfunction

// drive one full data segment (header + payload), padded to 64 bytes
task automatic send_data_pkt (input [31:0] seqn,
                              input [31:0] ackn,
                              input [7:0]  flags,
                              input [3:0]  doff,
                              input  logic [7:0] pl [$]);
    logic [7:0] s [$];
    build_segment(s, seqn, ackn, flags, doff, pl);
    $display("[%0t]   send    : seq=0x%08x ack=0x%08x flags=0x%02x doff=%0d plen=%0d cksum=0x%02x%02x",
             $time, seqn, ackn, flags, doff, pl.size(), s[16], s[17]);
    tcp_seg_len = 16'(doff*4 + pl.size());   // TCP段真实长度(不含padding)
    send_bytes(s);
endtask

// collect one packet from the application interface (byte 0 first).
// the app asserts tready only while it is actually sampling, so words are
// never drained from the DUT when nobody is watching.
task automatic collect_app (output logic [7:0] data [$],
                            output bit          timed_out,
                            input  integer      max_wait_cyc);
    integer guard;
    data.delete();
    timed_out = 1'b0;
    guard = 0;
    app_rx_axis_tready = 1'b1;
    while (app_rx_axis_tvalid !== 1'b1) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard >= max_wait_cyc) begin
            timed_out = 1'b1;
            app_rx_axis_tready = 1'b0;
            return;
        end
    end
    forever begin
        for (integer lane = 0; lane < 8; lane = lane + 1)
            if (app_rx_axis_tkeep[lane])
                data.push_back(app_rx_axis_tdata[lane*8 +: 8]);
        if (app_rx_axis_tlast)
            break;
        @(negedge clk);
        guard = 0;
        while (app_rx_axis_tvalid !== 1'b1) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard >= max_wait_cyc) begin
                timed_out = 1'b1;
                app_rx_axis_tready = 1'b0;
                return;
            end
        end
    end
    @(negedge clk);
    app_rx_axis_tready = 1'b0;
endtask

// expect the app interface to stay quiet for `window_cyc` cycles
task automatic expect_app_quiet (input integer window_cyc, output bit quiet);
    logic [7:0] d [$];
    bit tout;
    collect_app(d, tout, window_cyc);
    quiet = tout;
endtask

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
// stimulus
// ---------------------------------------------------------------------------
bit syn_seen, ack_seen, fin_seen, cack_seen, quiet;
bit timed_out;

// background strobe monitors: latch 1-cycle strobes whenever they fire,
// so pulses emitted during send_pkt are never missed
bit m_syn, m_ack, m_fin, m_cack, m_resp;
always @(posedge clk) begin
    if (tcp_handshake_syn === 1'b1) m_syn  = 1'b1;
    if (tcp_handshake_ack === 1'b1) m_ack  = 1'b1;
    if (tcp_close_fin     === 1'b1) m_fin  = 1'b1;
    if (tcp_close_ack     === 1'b1) m_cack = 1'b1;
    if (tcp_trans_resp    === 1'b1) m_resp = 1'b1;
end

task automatic clear_strobes;
    m_syn = 1'b0; m_ack = 1'b0; m_fin = 1'b0; m_cack = 1'b0; m_resp = 1'b0;
endtask

initial begin
    $timeformat(-9, 2, " ns", 12);

    // =====================================================================
    $display("[%0t] ===== CASE1: client SYN -> tcp_handshake_syn =====", $time);
    reset_dut;
    clear_strobes;
    tcp_link_up = 1'b0;
    send_pkt(CLIENT_ISN, 32'd0, FLAG_SYN, 16'hFFFF);
    repeat (2) @(negedge clk);
    check(m_syn, "CASE1: tcp_handshake_syn pulsed");
    check(tcp_rx_seq == CLIENT_ISN,
          $sformatf("CASE1: tcp_rx_seq = 0x%08x (expected 0x%08x)", tcp_rx_seq, CLIENT_ISN));

    // =====================================================================
    $display("[%0t] ===== CASE2: client 3rd ACK -> tcp_handshake_ack =====", $time);
    reset_dut;
    clear_strobes;
    tcp_link_up = 1'b0;   // not yet established -> ACK is the 3rd handshake ACK
    send_pkt(CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, FLAG_ACK, 16'hFFFF);
    repeat (2) @(negedge clk);
    check(m_ack, "CASE2: tcp_handshake_ack pulsed");

    // =====================================================================
    $display("[%0t] ===== CASE3: client FIN -> tcp_close_fin =====", $time);
    reset_dut;
    clear_strobes;
    tcp_link_up = 1'b1;   // established -> FIN starts the close
    send_pkt(CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, FLAG_FIN, 16'hFFFF);
    repeat (2) @(negedge clk);
    check(m_fin, "CASE3: tcp_close_fin pulsed");

    // =====================================================================
    $display("[%0t] ===== CASE4: client 4th ACK -> tcp_close_ack =====", $time);
    reset_dut;
    clear_strobes;
    tcp_link_up = 1'b1;   // established -> ACK is the 4th close ACK
    send_pkt(CLIENT_ISN + 32'd2, SERVER_ISN + 32'd2, FLAG_ACK, 16'hFFFF);
    repeat (2) @(negedge clk);
    check(m_cack, "CASE4: tcp_close_ack pulsed");

    // =====================================================================
    $display("[%0t] ===== CASE5: corrupted checksum -> no strobe =====", $time);
    reset_dut;
    clear_strobes;
    begin : corrupt_syn
        logic [7:0] h [$];
        build_header(h, CLIENT_ISN, 32'd0, FLAG_SYN, 16'hFFFF);
        h[17] = h[17] ^ 8'h01;   // flip one checksum bit
        tcp_seg_len = 16'd20;
        send_bytes(h);
    end
    repeat (STROBE_WIN_CYC) @(negedge clk);
    check(!m_syn, "CASE5: no handshake_syn strobe on a corrupted checksum");

    // =====================================================================
    // CASE6: two control packets in a row without reset -> per-packet state
    // (checksum accumulators) must not leak from one packet into the next
    // =====================================================================
    $display("[%0t] ===== CASE6: two packets in a row, no reset between them =====", $time);
    reset_dut;
    clear_strobes;
    tcp_link_up = 1'b0;
    send_pkt(CLIENT_ISN, 32'd0, FLAG_SYN, 16'hFFFF);
    repeat (2) @(negedge clk);
    check(m_syn, "CASE6: tcp_handshake_syn pulsed (1st packet)");

    clear_strobes;
    tcp_link_up = 1'b1;   // link established after the first packet
    send_pkt(CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, FLAG_FIN, 16'hFFFF);
    repeat (2) @(negedge clk);
    check(m_fin, "CASE6: tcp_close_fin pulsed (2nd packet)");

    // =====================================================================
    // data packet cases: PSH packets carry payload that must appear on the
    // application interface, and tcp_trans_resp must pulse for good frames
    // =====================================================================
    begin : payloads
        logic [7:0] pl16 [$];   // 16 bytes  : 2 full payload words
        logic [7:0] pl5  [$];   //  5 bytes  : partial last word
        logic [7:0] pl3  [$];   //  3 bytes  : payload shorter than 4 bytes
        logic [7:0] got  [$];
        bit         got_ok;

        for (integer i = 0; i < 16; i = i + 1) pl16.push_back(8'hA0 + i);
        for (integer i = 0; i < 5;  i = i + 1) pl5.push_back (8'hB0 + i);
        for (integer i = 0; i < 3;  i = i + 1) pl3.push_back (8'hC0 + i);

        // CASE7: 16 byte payload
        $display("[%0t] ===== CASE7: data packet, 16 byte payload =====", $time);
        reset_dut;
        clear_strobes;
        tcp_link_up = 1'b1;
        send_data_pkt(CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, 8'h08, 4'd5, pl16);
        repeat (2) @(negedge clk);
        check(m_resp, "CASE7: tcp_trans_resp pulsed");
        collect_app(got, timed_out, STROBE_WIN_CYC);
        check(!timed_out, "CASE7: payload arrived on app_rx_axis");
        if (!timed_out) begin
            check(got.size() == pl16.size(),
                  $sformatf("CASE7: app payload length = %0d (got %0d)", pl16.size(), got.size()));
            got_ok = 1'b1;
            for (integer i = 0; i < pl16.size(); i = i + 1)
                if (got[i] !== pl16[i]) got_ok = 1'b0;
            check(got_ok, "CASE7: app payload bytes match");
            if (!got_ok)
                $display("[%0t]   got     : %s", $time, bytes_str(got, 20));
        end

        // CASE8: 5 byte payload (ACK+PSH flags like a real client), partial word
        $display("[%0t] ===== CASE8: data packet (ACK+PSH), 5 byte payload =====", $time);
        reset_dut;
        clear_strobes;
        tcp_link_up = 1'b1;
        send_data_pkt(CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, 8'h18, 4'd5, pl5);
        repeat (2) @(negedge clk);
        check(m_resp, "CASE8: tcp_trans_resp pulsed");
        collect_app(got, timed_out, STROBE_WIN_CYC);
        check(!timed_out, "CASE8: payload arrived on app_rx_axis");
        if (!timed_out) begin
            check(got.size() == pl5.size(),
                  $sformatf("CASE8: app payload length = %0d (got %0d)", pl5.size(), got.size()));
            got_ok = 1'b1;
            for (integer i = 0; i < pl5.size(); i = i + 1)
                if (got[i] !== pl5[i]) got_ok = 1'b0;
            check(got_ok, "CASE8: app payload bytes match");
            if (!got_ok)
                $display("[%0t]   got     : %s", $time, bytes_str(got, 20));
        end

        // CASE9: 3 byte payload (payload starts mid-word, ends mid-word)
        $display("[%0t] ===== CASE9: data packet, 3 byte payload =====", $time);
        reset_dut;
        clear_strobes;
        tcp_link_up = 1'b1;
        send_data_pkt(CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, 8'h08, 4'd5, pl3);
        repeat (2) @(negedge clk);
        check(m_resp, "CASE9: tcp_trans_resp pulsed");
        collect_app(got, timed_out, STROBE_WIN_CYC);
        check(!timed_out, "CASE9: payload arrived on app_rx_axis");
        if (!timed_out) begin
            check(got.size() == pl3.size(),
                  $sformatf("CASE9: app payload length = %0d (got %0d)", pl3.size(), got.size()));
            got_ok = 1'b1;
            for (integer i = 0; i < pl3.size(); i = i + 1)
                if (got[i] !== pl3[i]) got_ok = 1'b0;
            check(got_ok, "CASE9: app payload bytes match");
            if (!got_ok)
                $display("[%0t]   got     : %s", $time, bytes_str(got, 20));
        end

        // CASE10: corrupted checksum -> payload dropped, no trans_resp
        $display("[%0t] ===== CASE10: data packet with corrupted checksum =====", $time);
        reset_dut;
        clear_strobes;
        tcp_link_up = 1'b1;
        begin : bad_data
            logic [7:0] s [$];
            build_segment(s, CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, 8'h08, 4'd5, pl16);
            s[17] = s[17] ^ 8'h01;
            tcp_seg_len = 16'(20 + pl16.size());
            send_bytes(s);
        end
        repeat (STROBE_WIN_CYC) @(negedge clk);
        check(!m_resp, "CASE10: no tcp_trans_resp for a corrupted packet");
        begin : w10
            bit app_quiet;
            logic [7:0] d [$];
            bit tout;
            collect_app(d, tout, 20);
            check(tout, "CASE10: corrupted data packet dropped (nothing on app_rx_axis)");
        end

        // CASE11: two data frames in a row -> both delivered in order
        $display("[%0t] ===== CASE11: two data frames back-to-back =====", $time);
        reset_dut;
        clear_strobes;
        tcp_link_up = 1'b1;
        send_data_pkt(CLIENT_ISN + 32'd1,  SERVER_ISN + 32'd1, 8'h08, 4'd5, pl16);
        send_data_pkt(CLIENT_ISN + 32'd17, SERVER_ISN + 32'd1, 8'h08, 4'd5, pl5);
        repeat (2) @(negedge clk);
        check(m_resp, "CASE11: tcp_trans_resp pulsed");
        collect_app(got, timed_out, STROBE_WIN_CYC);
        check(!timed_out, "CASE11: 1st payload arrived");
        if (!timed_out) begin
            got_ok = (got.size() == pl16.size());
            for (integer i = 0; i < pl16.size(); i = i + 1)
                if (got[i] !== pl16[i]) got_ok = 1'b0;
            check(got_ok, "CASE11: 1st payload bytes match");
            if (!got_ok)
                $display("[%0t]   got     : %s", $time, bytes_str(got, 20));
        end
        collect_app(got, timed_out, STROBE_WIN_CYC);
        check(!timed_out, "CASE11: 2nd payload arrived");
        if (!timed_out) begin
            got_ok = (got.size() == pl5.size());
            for (integer i = 0; i < pl5.size(); i = i + 1)
                if (got[i] !== pl5[i]) got_ok = 1'b0;
            check(got_ok, "CASE11: 2nd payload bytes match");
            if (!got_ok)
                $display("[%0t]   got     : %s", $time, bytes_str(got, 20));
        end

        // CASE12: offset=7 (28 byte header), 16 byte payload.
        // payload starts at byte 28 = beat 3 lane 4, needs 4 bytes from the
        // option tail to be concatenated with the next beat's low 4 bytes.
        $display("[%0t] ===== CASE12: data packet, offset=7, 16 byte payload =====", $time);
        reset_dut;
        clear_strobes;
        tcp_link_up = 1'b1;
        send_data_pkt(CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, 8'h08, 4'd7, pl16);
        repeat (2) @(negedge clk);
        check(m_resp, "CASE12: tcp_trans_resp pulsed");
        collect_app(got, timed_out, STROBE_WIN_CYC);
        check(!timed_out, "CASE12: payload arrived on app_rx_axis");
        if (!timed_out) begin
            check(got.size() == pl16.size(),
                  $sformatf("CASE12: app payload length = %0d (got %0d)", pl16.size(), got.size()));
            got_ok = 1'b1;
            for (integer i = 0; i < pl16.size(); i = i + 1)
                if (got[i] !== pl16[i]) got_ok = 1'b0;
            check(got_ok, "CASE12: app payload bytes match (offset=7 concat)");
            if (!got_ok)
                $display("[%0t]   got     : %s", $time, bytes_str(got, 20));
        end

        // CASE13: offset=6 (24 byte header), 16 byte payload.
        // payload starts at byte 24 = beat 3 lane 0, word-aligned (no concat).
        $display("[%0t] ===== CASE13: data packet, offset=6, 16 byte payload =====", $time);
        reset_dut;
        clear_strobes;
        tcp_link_up = 1'b1;
        send_data_pkt(CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, 8'h08, 4'd6, pl16);
        repeat (2) @(negedge clk);
        check(m_resp, "CASE13: tcp_trans_resp pulsed");
        collect_app(got, timed_out, STROBE_WIN_CYC);
        check(!timed_out, "CASE13: payload arrived on app_rx_axis");
        if (!timed_out) begin
            check(got.size() == pl16.size(),
                  $sformatf("CASE13: app payload length = %0d (got %0d)", pl16.size(), got.size()));
            got_ok = 1'b1;
            for (integer i = 0; i < pl16.size(); i = i + 1)
                if (got[i] !== pl16[i]) got_ok = 1'b0;
            check(got_ok, "CASE13: app payload bytes match (offset=6 aligned)");
            if (!got_ok)
                $display("[%0t]   got     : %s", $time, bytes_str(got, 20));
        end

        // CASE14: payload length sweep 1..64, data offset rotates 5/6/7 so
        // every length is exercised with a half-beat start (offset=5/7) and
        // a word-aligned start (offset=6)
        $display("[%0t] ===== CASE14: payload length sweep 1..64 =====", $time);
        begin : sweep
            logic [7:0] pl_sweep [$];
            logic [3:0] doff_sweep;
            for (integer len = 1; len <= 64; len = len + 1) begin
                pl_sweep.delete();
                for (integer i = 0; i < len; i = i + 1)
                    pl_sweep.push_back(8'((len + i) & 8'hFF));
                case (len % 3)
                    0: doff_sweep = 4'd5;
                    1: doff_sweep = 4'd6;
                    default: doff_sweep = 4'd7;
                endcase

                reset_dut;
                clear_strobes;
                tcp_link_up = 1'b1;
                send_data_pkt(CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, 8'h08, doff_sweep, pl_sweep);
                repeat (2) @(negedge clk);
                check(m_resp, $sformatf("CASE14[%0d/doff%0d]: tcp_trans_resp pulsed", len, doff_sweep));

                collect_app(got, timed_out, STROBE_WIN_CYC);
                check(!timed_out, $sformatf("CASE14[%0d]: payload arrived", len));
                if (!timed_out) begin
                    check(got.size() == len,
                          $sformatf("CASE14[%0d]: length = %0d (got %0d)", len, len, got.size()));
                    got_ok = 1'b1;
                    for (integer i = 0; i < len; i = i + 1)
                        if (got[i] !== pl_sweep[i]) got_ok = 1'b0;
                    check(got_ok, $sformatf("CASE14[%0d]: bytes match", len));
                    if (!got_ok)
                        $display("[%0t]   got     : %s", $time, bytes_str(got, 20));
                end
            end
        end
    end
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
