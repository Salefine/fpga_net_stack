`timescale 1ns / 1ps

/****************************************************************************
 * @file    tb_icmp_reply.sv
 * @brief   self checking testbench for rtl/icmp/icmp_rx.v + rtl/icmp/icmp_tx.v
 *
 * The two modules together build the ICMP echo responder of the stack:
 *   icmp_rx : takes the ICMP message from the IP layer (AXIS, 8 bytes/beat),
 *             verifies the ICMP checksum, buffers the frame and replays it on
 *             its output when the frame is good. A frame with a wrong checksum
 *             or a frame flagged with tuser is dropped.
 *   icmp_tx : takes that stream and turns it into the echo reply
 *             (type/code = 0, checksum = ~sum) and hands it back to the
 *             IP layer.
 *
 * Both modules run in the same clock domain here, exactly like in
 * udp_stack_top.
 *
 * Tests:
 *   1.   64 byte echo request -> echo reply, reply packet verified
 *   2.  128 byte echo request -> echo reply, reply packet verified
 *   3. 1024 byte echo request -> echo reply, reply packet verified
 *   4.   19 byte echo request with payload "hello,world" (partial last beat,
 *        odd message length) -> echo reply, reply packet verified
 *   5. echo request with a corrupted checksum -> dropped, no reply
 *   6. good request flagged with tuser (link error) -> dropped, no reply
 *   7. 64 byte echo request again -> DUT still answers after the dropped frames
 *
 * Every reply is checked for: exactly one reply per request, length, type and
 * code, identifier, sequence number, echoed payload and the 16 bit ICMP
 * checksum (checksum field value and checksum self consistency, i.e. the one's
 * complement sum over the message including its own checksum field = 0xffff).
 *
 * Run (Vivado xsim, from the repository root):
 *   xvlog -sv -work xpm %XILINX_VIVADO%/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv
 *   xvlog -sv -work xpm %XILINX_VIVADO%/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv
 *   xvlog -sv rtl/icmp/icmp_rx.v rtl/icmp/icmp_tx.v rtl/xpm_sync_fifo.v tb/tb_icmp_reply.sv
 *   xelab -L xpm tb_icmp_reply -s tb_icmp_reply_sim -O0 -mt off
 *   xsim tb_icmp_reply_sim -runall
 *
 * -O0 is needed on purpose: with the default optimization level the xsim
 * elaborator dies with an access violation in exprHasXsimGeneratedNodeOr-
 * GeneratedTmp while compiling this testbench, -O0 elaborates it cleanly.
 * ***************************************************************************/

module tb_icmp_reply;

// ---------------------------------------------------------------------------
// configuration
// ---------------------------------------------------------------------------
localparam CLOCK_PERIOD      = 100;       // 10 MHz, slow clock -> readable waves
localparam DATA_WIDTH        = 64;
localparam KEEP_WIDTH        = DATA_WIDTH / 8;

localparam REPLY_TIMEOUT_CYC = 400;       // cycles to wait for the reply of a request
localparam DROP_WINDOW_CYC   = 400;       // quiet window a dropped frame must keep

localparam [7:0] ICMP_TYPE_ECHO_REQUEST = 8'h08;
localparam [7:0] ICMP_TYPE_ECHO_REPLY   = 8'h00;
localparam [7:0] ICMP_CODE_ZERO         = 8'h00;

// ---------------------------------------------------------------------------
// clock / reset (rx and tx share one clock domain)
// ---------------------------------------------------------------------------
logic clk   = 1'b0;
logic rst_n = 1'b0;

always #(CLOCK_PERIOD/2) clk = ~clk;

// ---------------------------------------------------------------------------
// interfaces
// ---------------------------------------------------------------------------
/* IP layer -> icmp_layer : the ICMP message, byte 0 (ICMP type) in lane 0 */
logic [DATA_WIDTH-1:0] ip_rx_axis_tdata  = '0;
logic [KEEP_WIDTH-1:0] ip_rx_axis_tkeep  = '0;
logic                  ip_rx_axis_tvalid = 1'b0;
logic                  ip_rx_axis_tlast  = 1'b0;
logic                  ip_rx_axis_tuser  = 1'b0;
wire                   ip_rx_axis_tready;

/* icmp_layer -> IP layer */
wire [DATA_WIDTH-1:0]  icmp_tx_axis_tdata;
wire [KEEP_WIDTH-1:0]  icmp_tx_axis_tkeep;
wire                   icmp_tx_axis_tvalid;
wire                   icmp_tx_axis_tlast;
logic                  icmp_tx_axis_tready = 1'b1;
wire                   icmp_not_empty;

icmp_layer #(
    .ICMP_LAYER_TDATA_WIDTH (DATA_WIDTH)
) icmp_layer_inst (
    .clk                  (clk                 ),
    .rst                  (~rst_n              ),
    .icmp_not_empty       (icmp_not_empty      ),

    .icmp_rx_axis_tdata   (ip_rx_axis_tdata    ),
    .icmp_rx_axis_tkeep   (ip_rx_axis_tkeep    ),
    .icmp_rx_axis_tvalid  (ip_rx_axis_tvalid   ),
    .icmp_rx_axis_tlast   (ip_rx_axis_tlast    ),
    .icmp_rx_axis_tuser   (ip_rx_axis_tuser    ),
    .icmp_rx_axis_tready  (ip_rx_axis_tready   ),

    .icmp_tx_axis_tdata   (icmp_tx_axis_tdata  ),
    .icmp_tx_axis_tkeep   (icmp_tx_axis_tkeep  ),
    .icmp_tx_axis_tvalid  (icmp_tx_axis_tvalid ),
    .icmp_tx_axis_tlast   (icmp_tx_axis_tlast  ),
    .icmp_tx_axis_tready  (icmp_tx_axis_tready )
);

// ---------------------------------------------------------------------------
// scoreboard
// ---------------------------------------------------------------------------
integer pass_count         = 0;
integer fail_count         = 0;
integer tx_packet_count    = 0;   // complete packets handed back to the IP layer
integer not_empty_pulses   = 0;
logic [15:0] lfsr = 16'hACE1;     // backpressure pattern generator for TEST8

always @(posedge clk) begin
    if (icmp_tx_axis_tvalid && icmp_tx_axis_tlast && icmp_tx_axis_tready)
        tx_packet_count <= tx_packet_count + 1;
    if (icmp_not_empty)
        not_empty_pulses <= not_empty_pulses + 1;
end

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// mixed byte queues are used for the messages, element 0 is the first byte on
// the wire (ICMP type), the ICMP checksum is the 16 bit one's complement sum
// over the message, words are read big endian.
function automatic [15:0] ones_add (input [15:0] a, input [15:0] b);
    logic [16:0] s;
    s = a + b;
    return s[16] ? (s[15:0] + 16'h0001) : s[15:0];
endfunction

function automatic [15:0] msg_sum (input byte unsigned b [$]);
    logic [15:0] acc;
    acc = 16'h0000;
    for (integer i = 0; i < b.size(); i = i + 2) begin
        if (i + 1 < b.size())
            acc = ones_add(acc, {b[i], b[i+1]});
        else
            acc = ones_add(acc, {b[i], 8'h00});
    end
    return acc;
endfunction

function automatic [15:0] icmp_checksum (input byte unsigned b [$]);
    return ~msg_sum(b);
endfunction

function automatic string bytes_str (input byte unsigned b [$], input integer max_n);
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

// printable ASCII rendering of a payload, for the log
function automatic string ascii_str (input byte unsigned b [$], input integer max_n);
    string  s;
    integer n;
    s = "";
    n = (b.size() < max_n) ? b.size() : max_n;
    for (integer i = 0; i < n; i = i + 1)
        if ((b[i] >= 8'h20) && (b[i] < 8'h7f))
            s = {s, $sformatf("%c", b[i])};
        else
            s = {s, "."};
    return s;
endfunction

// build a request from an explicit payload: 8 byte header + payload + checksum
function automatic void build_request_msg (output byte unsigned msg [$],
                                           input  byte unsigned payload [$],
                                           input  [15:0]  ident,
                                           input  [15:0]  seqn);
    logic [15:0] cksum;
    msg.delete();
    msg.push_back(ICMP_TYPE_ECHO_REQUEST);
    msg.push_back(ICMP_CODE_ZERO);
    msg.push_back(8'h00);                 // checksum, filled in below
    msg.push_back(8'h00);
    msg.push_back(ident[15:8]);
    msg.push_back(ident[7:0]);
    msg.push_back(seqn[15:8]);
    msg.push_back(seqn[7:0]);
    for (integer i = 0; i < payload.size(); i = i + 1)
        msg.push_back(payload[i]);
    cksum = icmp_checksum(msg);
    msg[2] = cksum[15:8];
    msg[3] = cksum[7:0];
endfunction

// build a valid ICMP echo request with a generated payload
function automatic void build_request (output byte unsigned msg [$],
                                       input  integer len,
                                       input  [15:0]  ident,
                                       input  [15:0]  seqn,
                                       input  integer seed);
    byte unsigned payload [$];
    logic [31:0]  x;
    payload.delete();
    x = seed;
    for (integer i = 8; i < len; i = i + 1) begin
        x = x * 32'd1103515245 + 32'd12345;
        payload.push_back(x[23:16]);
    end
    build_request_msg(msg, payload, ident, seqn);
endfunction

// expected echo reply: type/code 0, valid checksum, everything else copied
function automatic void build_reply (input  byte unsigned req [$],
                                     output byte unsigned exp [$]);
    logic [15:0] cksum;
    exp.delete();
    for (integer i = 0; i < req.size(); i = i + 1)
        exp.push_back(req[i]);
    exp[0] = ICMP_TYPE_ECHO_REPLY;
    exp[1] = ICMP_CODE_ZERO;
    exp[2] = 8'h00;
    exp[3] = 8'h00;
    cksum  = icmp_checksum(exp);
    exp[2] = cksum[15:8];
    exp[3] = cksum[7:0];
endfunction

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

// drive one ICMP message into icmp_rx, handshake-aware (holds each beat
// until ip_rx_axis_tready is high)
task automatic send_msg (input byte unsigned msg [$], input bit tuser_i);
    integer n;
    integer lanes;
    integer guard;
    n = msg.size();
    for (integer i = 0; i < n; i = i + KEEP_WIDTH) begin
        lanes = (n - i) > KEEP_WIDTH ? KEEP_WIDTH : (n - i);
        ip_rx_axis_tdata  = {DATA_WIDTH{1'b0}};
        ip_rx_axis_tkeep  = {KEEP_WIDTH{1'b0}};
        for (integer j = 0; j < lanes; j = j + 1) begin
            ip_rx_axis_tdata[j*8 +: 8] = msg[i+j];
            ip_rx_axis_tkeep[j]        = 1'b1;
        end
        ip_rx_axis_tlast  = (i + KEEP_WIDTH) >= n;
        ip_rx_axis_tvalid = 1'b1;
        ip_rx_axis_tuser  = tuser_i;
        guard = 0;
        @(negedge clk);
        while (!(ip_rx_axis_tvalid && ip_rx_axis_tready)) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 2000) begin
                $display("[%0t]   SEND_TIMEOUT: ip_rx_axis_tready stuck low", $time);
                $finish;
            end
        end
    end
    ip_rx_axis_tdata  = {DATA_WIDTH{1'b0}};
    ip_rx_axis_tkeep  = {KEEP_WIDTH{1'b0}};
    ip_rx_axis_tvalid = 1'b0;
    ip_rx_axis_tlast  = 1'b0;
    ip_rx_axis_tuser  = 1'b0;
    @(negedge clk);
    $display("[%0t]   sent    : type=0x%02x code=0x%02x cksum=0x%02x%02x id=0x%02x%02x seq=0x%02x%02x len=%0d",
             $time, msg[0], msg[1], msg[2], msg[3], msg[4], msg[5], msg[6], msg[7], n);
endtask

// collect one reply packet from icmp_tx; timed_out is set when nothing arrives
// beats are sampled at the negedge: by then the posedge NBA has completed and
// the FWFT FIFO has popped the previous beat, so each beat is sampled exactly
// once.  (Sampling at the posedge reads the signal before the NBA updates,
// which double-counts the first beat when tready rises while tvalid already
// holds a beat.)
task automatic recv_reply (output byte unsigned rpl [$],
                           output bit timed_out,
                           input  integer max_wait_cyc);
    integer guard;
    rpl.delete();
    timed_out = 1'b0;
    guard     = 0;
    while (!(icmp_tx_axis_tvalid && icmp_tx_axis_tready)) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard >= max_wait_cyc) begin
            timed_out = 1'b1;
            return;
        end
    end
    forever begin
        for (integer lane = 0; lane < KEEP_WIDTH; lane = lane + 1)
            if (icmp_tx_axis_tkeep[lane])
                rpl.push_back(icmp_tx_axis_tdata[lane*8 +: 8]);
        if (icmp_tx_axis_tlast)
            break;
        @(negedge clk);
        guard = 0;
        while (!(icmp_tx_axis_tvalid && icmp_tx_axis_tready)) begin
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

// compare the reply against the expected echo reply
task automatic check_reply (input string tag,
                            input byte unsigned exp [$],
                            input byte unsigned got [$]);
    bit     data_ok;
    integer bad_idx;
    integer i;
    check(got.size() == exp.size(),
          $sformatf("%0s: reply length = %0d bytes", tag, exp.size()));
    if (got.size() != exp.size()) begin
        $display("[%0t]   got     : %s", $time, bytes_str(got, 16));
        return;
    end
    $display("[%0t]   reply   : type=0x%02x code=0x%02x cksum=0x%02x%02x id=0x%02x%02x seq=0x%02x%02x len=%0d",
             $time, got[0], got[1], got[2], got[3], got[4], got[5], got[6], got[7], got.size());
    // full dump for short packets, so the bytes can be re-checked offline
    if (exp.size() <= 64)
        $display("[%0t]   hex     : %s", $time, bytes_str(got, got.size()));

    if ((got[0] == ICMP_TYPE_ECHO_REPLY) && (got[1] == ICMP_CODE_ZERO))
        check(1'b1, $sformatf("%0s: type = %0d (echo reply), code = %0d", tag, got[0], got[1]));
    else
        check(1'b0, $sformatf("%0s: type/code = %0d/%0d, expected 0/0", tag, got[0], got[1]));

    if ((got[4] == exp[4]) && (got[5] == exp[5]))
        check(1'b1, $sformatf("%0s: identifier echoed (0x%02x%02x)", tag, got[4], got[5]));
    else
        check(1'b0, $sformatf("%0s: identifier = 0x%02x%02x, expected 0x%02x%02x",
                              tag, got[4], got[5], exp[4], exp[5]));

    if ((got[6] == exp[6]) && (got[7] == exp[7]))
        check(1'b1, $sformatf("%0s: sequence number echoed (0x%02x%02x)", tag, got[6], got[7]));
    else
        check(1'b0, $sformatf("%0s: sequence = 0x%02x%02x, expected 0x%02x%02x",
                              tag, got[6], got[7], exp[6], exp[7]));

    data_ok = 1'b1;
    bad_idx = 0;
    for (i = 8; i < exp.size(); i = i + 1) begin
        if (got[i] !== exp[i]) begin
            data_ok = 1'b0;
            bad_idx = i;
            break;
        end
    end
    if (data_ok)
        check(1'b1, $sformatf("%0s: %0d payload bytes echoed unchanged", tag, exp.size()-8));
    else
        check(1'b0, $sformatf("%0s: payload differs at byte %0d (expected 0x%02x, got 0x%02x)",
                              tag, bad_idx, exp[bad_idx], got[bad_idx]));

    if ((got[2] == exp[2]) && (got[3] == exp[3]))
        check(1'b1, $sformatf("%0s: ICMP checksum = 0x%02x%02x", tag, exp[2], exp[3]));
    else
        check(1'b0, $sformatf("%0s: ICMP checksum = 0x%02x%02x, expected 0x%02x%02x",
                              tag, got[2], got[3], exp[2], exp[3]));

    if (msg_sum(got) == 16'hFFFF)
        check(1'b1, $sformatf("%0s: reply checksum self consistent (sum = 0x%04x)", tag, msg_sum(got)));
    else
        check(1'b0, $sformatf("%0s: reply checksum broken (sum = 0x%04x, expected 0xffff)",
                              tag, msg_sum(got)));
endtask

// run one ping exchange: request in, reply verified, no extra traffic afterwards
task automatic run_ping (input string tag, input byte unsigned req [$]);
    byte unsigned exp [$];
    byte unsigned got [$];
    bit timed_out;
    send_msg(req, 1'b0);
    recv_reply(got, timed_out, REPLY_TIMEOUT_CYC);
    check(!timed_out, $sformatf("%0s: reply received", tag));
    if (timed_out)
        return;
    build_reply(req, exp);
    check_reply(tag, exp, got);
    recv_reply(got, timed_out, 20);
    check(timed_out, $sformatf("%0s: no extra reply after the answer", tag));
endtask

// ping test with a generated payload
task automatic ping_test (input string tag,
                          input integer len,
                          input [15:0]  ident,
                          input [15:0]  seqn,
                          input integer seed);
    byte unsigned req [$];
    build_request(req, len, ident, seqn, seed);
    run_ping(tag, req);
endtask

// ping test with an explicit payload (e.g. an ASCII test string)
task automatic ping_test_msg (input string tag,
                              input byte unsigned payload [$],
                              input [15:0]  ident,
                              input [15:0]  seqn);
    byte unsigned req [$];
    build_request_msg(req, payload, ident, seqn);
    $display("[%0t]   payload : \"%0s\" (%0d bytes)", $time, ascii_str(payload, 32), payload.size());
    run_ping(tag, req);
endtask

// frame must be dropped: nothing may come out of icmp_tx
task automatic expect_dropped (input string tag,
                               input byte unsigned msg [$],
                               input bit tuser_i);
    byte unsigned got [$];
    bit timed_out;
    send_msg(msg, tuser_i);
    recv_reply(got, timed_out, DROP_WINDOW_CYC);
    if (!timed_out) begin
        check(1'b0, $sformatf("%0s: frame must be dropped, but a %0d byte reply came out",
                              tag, got.size()));
        $display("[%0t]   got     : %s", $time, bytes_str(got, 16));
    end
    else
        check(1'b1, $sformatf("%0s: frame dropped, no reply sent", tag));
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
byte unsigned msg_q [$];
byte unsigned pl_q  [$];   // payload of the "hello,world" test

initial begin
    $timeformat(-9, 2, " ns", 12);

    // reset
    rst_n = 1'b0;
    repeat (20) @(negedge clk);
    rst_n = 1'b1;
    repeat (20) @(negedge clk);

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST1: 64 byte ICMP echo request =====", $time);
    ping_test("TEST1", 64, 16'h4d7c, 16'h0001, 32'h0000_0064);

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST2: 128 byte ICMP echo request =====", $time);
    ping_test("TEST2", 128, 16'h1234, 16'h0005, 32'h0000_0128);

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST3: 1024 byte ICMP echo request =====", $time);
    ping_test("TEST3", 1024, 16'hbeef, 16'h0102, 32'h0000_1024);

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST4: 19 byte ICMP echo request, data \"hello,world\" =====", $time);
    begin : hello_world
        string s;
        s = "hello,world";
        pl_q.delete();
        for (integer i = 0; i < s.len(); i = i + 1)
            pl_q.push_back(s[i]);
    end
    ping_test_msg("TEST4", pl_q, 16'h4d7c, 16'h0001);

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST5: corrupted request checksum -> dropped =====", $time);
    build_request(msg_q, 64, 16'h4d7c, 16'h0003, 32'h0bad_f00d);
    msg_q[3] = msg_q[3] ^ 8'h01;
    expect_dropped("TEST5", msg_q, 1'b0);

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST6: request flagged with tuser -> dropped =====", $time);
    build_request(msg_q, 64, 16'h4d7c, 16'h0004, 32'h5a5a_5a5a);
    expect_dropped("TEST6", msg_q, 1'b1);

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST7: 64 byte request after the dropped frames =====", $time);
    ping_test("TEST7", 64, 16'h4d7c, 16'h0002, 32'hcafe_babe);

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST8: reply output with random backpressure =====", $time);
    begin : test8
        byte unsigned exp [$];
        byte unsigned got [$];
        bit timed_out;
        build_request(msg_q, 200, 16'h07c0, 16'h0008, 32'hfeed_f00d);
        send_msg(msg_q, 1'b0);
        // apply random backpressure on icmp_tx_axis_tready while collecting
        fork
            begin : t8_bp
                repeat (400) begin
                    @(posedge clk);
                    lfsr = {lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5], lfsr[15:1]};
                    icmp_tx_axis_tready <= lfsr[0];
                end
                @(posedge clk);
                icmp_tx_axis_tready = 1'b1;   // blocking: last write wins
            end
            begin : t8_rx
                recv_reply(got, timed_out, REPLY_TIMEOUT_CYC);
            end
        join
        check(!timed_out, "TEST8: reply received under backpressure");
        if (!timed_out) begin
            build_reply(msg_q, exp);
            check_reply("TEST8", exp, got);
        end
    end

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST9: reply output fully stalled, then released =====", $time);
    begin : test9
        byte unsigned exp [$];
        byte unsigned got [$];
        bit timed_out;
        build_request(msg_q, 64, 16'h9c3a, 16'h0009, 32'hdead_beef);
        @(negedge clk);                  // clear timestep: avoid the NBA from
        icmp_tx_axis_tready = 1'b0;      // TEST8's bp driver overwriting this
        send_msg(msg_q, 1'b0);
        repeat (60) @(negedge clk);      // nothing must be lost or half-sent
        // fixed handshake: tvalid is asserted (first beat held) while tready
        // is low; no beat may be handed off until tready returns
        check(icmp_tx_axis_tvalid === 1'b1,
              "TEST9: tvalid asserted while stalled (first beat held)");
        check(icmp_tx_axis_tlast === 1'b0,
              "TEST9: tlast not asserted while stalled");
        icmp_tx_axis_tready = 1'b1;      // release
        recv_reply(got, timed_out, REPLY_TIMEOUT_CYC);
        check(!timed_out, "TEST9: complete reply after the stall");
        if (!timed_out) begin
            build_reply(msg_q, exp);
            check_reply("TEST9", exp, got);
        end
    end

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST10: tvalid asserted before tready (arbiter handshake) =====", $time);
    begin : test10
        byte unsigned exp [$];
        byte unsigned got [$];
        bit timed_out;
        build_request(msg_q, 64, 16'h0013, 16'h0001, 32'h0000_0064);
        // Simulate an arbiter that only asserts tready once it sees tvalid:
        // icmp_tx must present tvalid (and the first beat) BEFORE waiting,
        // otherwise this deadlocks (tvalid low waiting for tready, arbiter
        // waiting for tvalid before granting).
        icmp_tx_axis_tready = 1'b0;
        send_msg(msg_q, 1'b0);
        fork
            begin : t10_valid_watch
                wait (icmp_tx_axis_tvalid === 1'b1);
                check(1'b1, "TEST10: tvalid asserted while tready is low");
                icmp_tx_axis_tready = 1'b1;   // grant
            end
            begin : t10_timeout
                #(6000);
                check(1'b0, "TEST10: tvalid never asserted without tready (deadlock)");
                icmp_tx_axis_tready = 1'b1;   // release so the bench can finish
            end
        join_any
        disable fork;
        @(negedge clk);   // align the sampler to the stable negedge window so
                          // the first beat is sampled before the next posedge pop
        recv_reply(got, timed_out, REPLY_TIMEOUT_CYC);
        check(!timed_out, "TEST10: reply received after grant");
        if (!timed_out) begin
            build_reply(msg_q, exp);
            check_reply("TEST10", exp, got);
        end
    end

    // -----------------------------------------------------------------
    if (tx_packet_count == 8)
        check(1'b1, $sformatf("exactly 8 reply packets on the output (got %0d)", tx_packet_count));
    else
        check(1'b0, $sformatf("8 reply packets expected on the output, got %0d", tx_packet_count));
    $display("[%0t] info    : icmp_not_empty pulsed %0d time(s)", $time, not_empty_pulses);

    if (fail_count == 0)
        $display("[%0t] ================ ALL %0d CHECKS PASSED ================", $time, pass_count);
    else
        $display("[%0t] ================ %0d/%0d CHECKS FAILED ================",
                 $time, fail_count, pass_count + fail_count);
    $finish;
end

// global watchdog
initial begin
    #(CLOCK_PERIOD * 20000);
    $display("FATAL: global timeout");
    $fatal(1);
end

endmodule

`default_nettype wire
