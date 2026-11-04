`timescale 1ns / 1ps

/****************************************************************************
 * @file    tb_tcp_tx.sv
 * @brief   Self-checking testbench for rtl/tcp/tcp_tx.v (data-packet path)
 *
 * tcp_tx takes application payload on app_tx_axis and wraps it into a full
 * TCP segment: 24 byte header (3 AXIS beats: 8+8+8; the last beat carries
 * checksum/urgent + 4 bytes of options padding so data offset = 6) + payload.
 * The FPGA is the TCP server, so src = server, dst = client.
 *
 * Checks:
 *   - header beat 1: src port, dst port, sequence number
 *   - header beat 2: ack number, data offset (0x60), flags (0x18 PSH|ACK),
 *                    window
 *   - header beat 3: checksum, urgent pointer (0), 4 bytes zero padding,
 *                    tkeep=0xff
 *   - payload: bytes copied verbatim, partial last word preserved
 *   - TCP checksum: field value + self consistency (ones complement sum of
 *     pseudo header + header + payload incl. checksum field = 0xffff)
 *
 * Run (Vivado xsim, from the repository root):
 *   xvlog -sv rtl/tcp/tcp_tx.v tb/tb_tcp_tx.sv
 *   xelab tb_tcp_tx -s tb_tcp_tx_sim -O0 -mt off -L xpm
 *   xsim tb_tcp_tx_sim -runall
 * ***************************************************************************/

module tb_tcp_tx;

localparam CLOCK_PERIOD = 100;   // 10 MHz

localparam [31:0] SERVER_IP   = 32'hC0A8010A;   // 192.168.1.10 (FPGA)
localparam [31:0] CLIENT_IP   = 32'hC0A80114;   // 192.168.1.20
localparam [15:0] SERVER_PORT = 16'h0050;       // 80
localparam [15:0] CLIENT_PORT = 16'h3039;       // 12345
localparam [31:0] SERVER_SEQ  = 32'h00005001;
localparam [31:0] CLIENT_ACK  = 32'h12345679;
localparam [15:0] WINDOW      = 16'hFFFF;

localparam [7:0] FLAG_PSH_ACK = 8'h18;

localparam RCV_TIMEOUT_CYC = 4000;

// ---------------------------------------------------------------------------
// clock / reset
// ---------------------------------------------------------------------------
logic clk = 1'b0;
logic rst = 1'b1;
always #(CLOCK_PERIOD/2) clk = ~clk;

// app -> tcp_tx
logic [63:0] app_tx_axis_tdata = '0;
logic [7:0]  app_tx_axis_tkeep = '0;
logic        app_tx_axis_tvalid = 1'b0;
logic        app_tx_axis_tlast  = 1'b0;
logic        tcp_linkup = 1'b0;
logic        tcp_psh_ack = 1'b0;

wire         app_tx_axis_tready;

// tcp_tx -> ip
wire [63:0]  tcp_tx_axis_tdata;
wire [7:0]   tcp_tx_axis_tkeep;
wire         tcp_tx_axis_tvalid;
wire         tcp_tx_axis_tlast;
logic        tcp_tx_axis_tready = 1'b1;

tcp_tx #(
    .RETRANSMIT_RETRY_COUNT (2),
    .RETRANSMIT_TIMEOUT     (50)
) dut (
    .src_ip_addr        (SERVER_IP          ),
    .dst_ip_addr        (CLIENT_IP          ),
    .tcp_src_port       (SERVER_PORT        ),
    .tcp_dst_port       (CLIENT_PORT        ),
    .tcp_linkup         (tcp_linkup         ),
    .tcp_ack_ok         (tcp_psh_ack        ),
    .tcp_tx_seq         (SERVER_SEQ         ),
    .tcp_tx_ack         (CLIENT_ACK         ),
    .tcp_tx_window      (WINDOW             ),
    .clk                (clk                ),
    .rst                (rst                ),
    .app_tx_axis_tdata  (app_tx_axis_tdata  ),
    .app_tx_axis_tkeep  (app_tx_axis_tkeep  ),
    .app_tx_axis_tvalid (app_tx_axis_tvalid ),
    .app_tx_axis_tlast  (app_tx_axis_tlast  ),
    .app_tx_axis_tready (app_tx_axis_tready ),
    .tcp_tx_axis_tdata  (tcp_tx_axis_tdata  ),
    .tcp_tx_axis_tkeep  (tcp_tx_axis_tkeep  ),
    .tcp_tx_axis_tvalid (tcp_tx_axis_tvalid ),
    .tcp_tx_axis_tlast  (tcp_tx_axis_tlast  ),
    .tcp_tx_axis_tready (tcp_tx_axis_tready )
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
// one's complement checksum helpers
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

// build the expected 24 byte TCP header (checksum field zeroed)
function automatic void build_header (output logic [7:0] h [$],
                                      input  logic [7:0] pl [$]);
    h.delete();
    h.push_back(SERVER_PORT[15:8]); h.push_back(SERVER_PORT[7:0]);
    h.push_back(CLIENT_PORT[15:8]); h.push_back(CLIENT_PORT[7:0]);
    h.push_back(SERVER_SEQ[31:24]); h.push_back(SERVER_SEQ[23:16]);
    h.push_back(SERVER_SEQ[15:8]);  h.push_back(SERVER_SEQ[7:0]);
    h.push_back(CLIENT_ACK[31:24]); h.push_back(CLIENT_ACK[23:16]);
    h.push_back(CLIENT_ACK[15:8]);  h.push_back(CLIENT_ACK[7:0]);
    h.push_back(8'h60);             // data offset = 6 (24 bytes)
    h.push_back(FLAG_PSH_ACK);      // flags
    h.push_back(WINDOW[15:8]); h.push_back(WINDOW[7:0]);
    h.push_back(8'h00); h.push_back(8'h00);   // checksum placeholder
    h.push_back(8'h00); h.push_back(8'h00);   // urgent pointer
    h.push_back(8'h00); h.push_back(8'h00);   // options padding (bytes 20-21)
    h.push_back(8'h00); h.push_back(8'h00);   // options padding (bytes 22-23)
endfunction

// expected checksum of the full TCP segment (header with cksum=0 + payload)
function automatic [15:0] expected_checksum (input logic [7:0] pl [$]);
    logic [7:0] h [$];
    logic [7:0] seg [$];
    logic [15:0] acc;
    logic [15:0] ck;
    build_header(h, pl);
    seg.delete();
    for (integer i = 0; i < h.size(); i = i + 1) seg.push_back(h[i]);
    for (integer i = 0; i < pl.size(); i = i + 1) seg.push_back(pl[i]);

    acc = 16'h0000;
    acc = ones_add(acc, SERVER_IP[31:16]);
    acc = ones_add(acc, SERVER_IP[15:0]);
    acc = ones_add(acc, CLIENT_IP[31:16]);
    acc = ones_add(acc, CLIENT_IP[15:0]);
    acc = ones_add(acc, 16'h0006);
    acc = ones_add(acc, 16'(24 + pl.size()));
    acc = ones_add(acc, ones_sum(seg));
    ck = ~acc;
    if (ck == 16'h0000) ck = 16'hFFFF;
    return ck;
endfunction

// self-consistency sum of a received segment (pseudo header + bytes incl. cksum)
function automatic [15:0] self_sum (input logic [7:0] seg [$]);
    logic [15:0] acc;
    acc = 16'h0000;
    acc = ones_add(acc, SERVER_IP[31:16]);
    acc = ones_add(acc, SERVER_IP[15:0]);
    acc = ones_add(acc, CLIENT_IP[31:16]);
    acc = ones_add(acc, CLIENT_IP[15:0]);
    acc = ones_add(acc, 16'h0006);
    acc = ones_add(acc, 16'(seg.size()));
    acc = ones_add(acc, ones_sum(seg));
    return acc;
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

// assert tcp_psh_ack for one full clock to release the in-flight segment
task automatic ack_segment;
    tcp_psh_ack = 1'b1;
    repeat (2) @(negedge clk);
    tcp_psh_ack = 1'b0;
    @(negedge clk);
endtask

// wait until the app interface is ready again (stop-and-wait released)
task automatic wait_tready;
    integer guard;
    guard = 0;
    while (app_tx_axis_tready !== 1'b1) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard >= 4000) begin
            check(1'b0, "wait_tready: app_tx_axis_tready did not release");
            return;
        end
    end
endtask

// drive a payload into app_tx_axis (tready honored)
task automatic send_payload (input logic [7:0] pl [$]);
    $display("[%0t]   app     : payload %0d bytes", $time, pl.size());
    for (integer i = 0; i < pl.size(); i = i + 8) begin
        integer lanes;
        lanes = (pl.size() - i) > 8 ? 8 : (pl.size() - i);
        app_tx_axis_tdata = 64'h0;
        app_tx_axis_tkeep = 8'h00;
        for (integer j = 0; j < lanes; j = j + 1) begin
            app_tx_axis_tdata[j*8 +: 8] = pl[i+j];
            app_tx_axis_tkeep[j]        = 1'b1;
        end
        app_tx_axis_tvalid = 1'b1;
        app_tx_axis_tlast  = (i + 8 >= pl.size());
        if (app_tx_axis_tlast)
            @(negedge clk);   //最后一拍: 保持一拍被接收即可(busy随后置起, tready会变低)
        else
            do @(negedge clk); while (!app_tx_axis_tready);
    end
    app_tx_axis_tvalid = 1'b0;
    app_tx_axis_tlast  = 1'b0;
    @(negedge clk);
endtask

// collect one full TCP segment from tcp_tx_axis (byte 0 first)
task automatic recv_segment (output logic [7:0] seg [$],
                             output bit          timed_out);
    integer guard;
    seg.delete();
    timed_out = 1'b0;
    guard = 0;
    while (tcp_tx_axis_tvalid !== 1'b1) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard >= RCV_TIMEOUT_CYC) begin
            timed_out = 1'b1;
            return;
        end
    end
    forever begin
        for (integer lane = 0; lane < 8; lane = lane + 1)
            if (tcp_tx_axis_tkeep[lane])
                seg.push_back(tcp_tx_axis_tdata[lane*8 +: 8]);
        if (tcp_tx_axis_tlast)
            break;
        @(negedge clk);
        guard = 0;
        while (tcp_tx_axis_tvalid !== 1'b1) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard >= RCV_TIMEOUT_CYC) begin
                timed_out = 1'b1;
                return;
            end
        end
    end
    @(negedge clk);
endtask

// verify a received segment against the expected payload
task automatic check_segment (input string        tag,
                              input logic [7:0]   seg [$],
                              input logic [7:0]   pl [$]);
    logic [7:0] hdr [$];
    logic [15:0] exp_ck;

    $display("[%0t]   seg     : %s", $time, bytes_str(seg, 28));

    check(seg.size() == 24 + pl.size(),
          $sformatf("%0s: segment length = %0d bytes (got %0d)", tag, 24 + pl.size(), seg.size()));
    if (seg.size() < 24) begin
        check(1'b0, $sformatf("%0s: segment too short to check header", tag));
        return;
    end

    // header fields (bytes 0..15)
    check(seg[0] == SERVER_PORT[15:8] && seg[1] == SERVER_PORT[7:0],
          $sformatf("%0s: source port = 0x%04x", tag, SERVER_PORT));
    check(seg[2] == CLIENT_PORT[15:8] && seg[3] == CLIENT_PORT[7:0],
          $sformatf("%0s: destination port = 0x%04x", tag, CLIENT_PORT));
    check({seg[4],seg[5],seg[6],seg[7]} == SERVER_SEQ,
          $sformatf("%0s: sequence number = 0x%08x", tag, SERVER_SEQ));
    check({seg[8],seg[9],seg[10],seg[11]} == CLIENT_ACK,
          $sformatf("%0s: ack number = 0x%08x", tag, CLIENT_ACK));
    check(seg[12] == 8'h60,
          $sformatf("%0s: data offset = 0x%02x (got 0x%02x)", tag, 8'h60, seg[12]));
    check(seg[13] == FLAG_PSH_ACK,
          $sformatf("%0s: flags = 0x%02x (got 0x%02x)", tag, FLAG_PSH_ACK, seg[13]));
    check({seg[14],seg[15]} == WINDOW,
          $sformatf("%0s: window = 0x%04x", tag, WINDOW));
    check(seg[18] == 8'h00 && seg[19] == 8'h00,
          $sformatf("%0s: urgent pointer = 0x0000", tag));
    check(seg[20] == 8'h00 && seg[21] == 8'h00 &&
          seg[22] == 8'h00 && seg[23] == 8'h00,
          $sformatf("%0s: options padding = 0x00000000", tag));

    // checksum field value
    exp_ck = expected_checksum(pl);
    check({seg[16],seg[17]} == exp_ck,
          $sformatf("%0s: checksum field = 0x%04x (got 0x%04x)",
                    tag, exp_ck, {seg[16],seg[17]}));

    // checksum self-consistency over pseudo header + header + payload
    check(self_sum(seg) == 16'hFFFF,
          $sformatf("%0s: checksum self-consistency (sum = 0xffff, got 0x%04x)",
                    tag, self_sum(seg)));

    // payload bytes
    if (seg.size() == 24 + pl.size()) begin
        bit ok;
        ok = 1'b1;
        for (integer i = 0; i < pl.size(); i = i + 1)
            if (seg[24+i] !== pl[i]) ok = 1'b0;
        check(ok, $sformatf("%0s: payload bytes match", tag));
    end
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
logic [7:0] pl16 [$];
logic [7:0] pl5  [$];
logic [7:0] pl8  [$];
logic [7:0] got  [$];
bit         timed_out;

initial begin
    $timeformat(-9, 2, " ns", 12);

    for (integer i = 0; i < 16; i = i + 1) pl16.push_back(8'hA0 + i);
    for (integer i = 0; i < 5;  i = i + 1) pl5.push_back (8'hB0 + i);
    for (integer i = 0; i < 8;  i = i + 1) pl8.push_back (8'hC0 + i);

    reset_dut;
    tcp_linkup = 1'b1;

    // =====================================================================
    $display("[%0t] ===== CASE1: 16 byte payload =====", $time);
    fork
        send_payload(pl16);
        recv_segment(got, timed_out);
    join
    check(!timed_out, "CASE1: segment received");
    if (!timed_out) check_segment("CASE1", got, pl16);
    ack_segment;

    // =====================================================================
    $display("[%0t] ===== CASE2: 5 byte payload (partial last word) =====", $time);
    fork
        send_payload(pl5);
        recv_segment(got, timed_out);
    join
    check(!timed_out, "CASE2: segment received");
    if (!timed_out) check_segment("CASE2", got, pl5);
    ack_segment;

    // =====================================================================
    $display("[%0t] ===== CASE3: 8 byte payload (full word) =====", $time);
    fork
        send_payload(pl8);
        recv_segment(got, timed_out);
    join
    check(!timed_out, "CASE3: segment received");
    if (!timed_out) check_segment("CASE3", got, pl8);
    ack_segment;

    // =====================================================================
    // stop-and-wait: 一包ACK释放后才发下一包
    $display("[%0t] ===== CASE4: two payloads (ack between) =====", $time);
    send_payload(pl16);
    recv_segment(got, timed_out);
    check(!timed_out, "CASE4: 1st segment received");
    if (!timed_out) check_segment("CASE4a", got, pl16);
    ack_segment;
    wait_tready;
    send_payload(pl5);
    recv_segment(got, timed_out);
    check(!timed_out, "CASE4: 2nd segment received");
    if (!timed_out) check_segment("CASE4b", got, pl5);
    ack_segment;

    // =====================================================================
    // 不ACK: 超时后应自动重传相同段, ACK后释放
    $display("[%0t] ===== CASE5: no ack -> retransmit =====", $time);
    send_payload(pl8);
    recv_segment(got, timed_out);
    check(!timed_out, "CASE5: original segment received");
    if (!timed_out) check_segment("CASE5a", got, pl8);

    // 等重传(应再次收到相同内容)
    recv_segment(got, timed_out);
    check(!timed_out, "CASE5: retransmitted segment received");
    if (!timed_out) check_segment("CASE5b", got, pl8);

    ack_segment;
    wait_tready;

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
    #(CLOCK_PERIOD * 400000);
    $display("FATAL: global timeout");
    $fatal(1);
end

endmodule

`default_nettype wire
