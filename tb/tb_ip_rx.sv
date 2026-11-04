`timescale 1ns / 1ps
`default_nettype none

//============================================================================
// tb_ip_rx : self-checking verification of ip_rx
//
// The DUT consumes an IPv4 packet on frame_rx_axis (64-bit AXI-Stream,
// first byte of the packet in tdata[7:0]) and emits the stripped UDP/ICMP
// payload on ip_rx_axis. This testbench checks, byte-for-byte, against an
// independently built IPv4 packet:
//   * 20-byte header checksum (one's-complement over the 10 header words)
//     -> payload is accepted with ip_rx_axis_tuser == 0 only when the sum
//        folds to 0xffff AND frame_rx_axis_tuser == 0
//   * 20-byte header removal + 64-bit re-alignment of the payload
//   * tkeep / tlast for the two tail alignments:
//        - tail ends in the low 4 bytes of the last beat (no flush beat)
//        - tail extends into the high 4 bytes (one extra flush beat)
//   * recv_src_ip_addr / recv_dst_ip_addr / ip_type extraction
//
// Watchdog aborts a hung run; TEST_PASS is printed only if error_count==0.
//============================================================================

module tb_ip_rx;

reg clk = 1'b0;
reg rst = 1'b1;

// ---- DUT ingress (frame_rx_axis) ----
reg  [63:0] frame_tdata  = 64'd0;
reg  [7:0]  frame_tkeep  = 8'd0;
reg         frame_tvalid = 1'b0;
reg         frame_tuser  = 1'b0;
reg         frame_tlast  = 1'b0;
wire        frame_tready;

// ---- DUT egress (ip_rx_axis) ----
wire [63:0] ip_tdata;
wire [7:0]  ip_tkeep;
wire        ip_tvalid;
wire        ip_tuser;
wire        ip_tlast;
reg         ip_tready = 1'b1;      // downstream ready (driven by generator below)
reg         tready_throttle = 1'b0; // 0 = full rate, 1 = periodic throttle
reg  [7:0]  throttle_cnt = 8'd0;
reg         saw_tready_low = 1'b0;  // evidence that ingress backpressure engaged

// ---- DUT side channels ----
reg  [31:0] local_ip  = 32'hC0A80114;   // 192.168.1.20
wire [31:0] recv_dst_ip;
wire [31:0] recv_src_ip;
reg  [47:0] local_mac = 48'h001122334455;
reg  [47:0] recv_dst_mac = 48'h001122334455;
wire [15:0] ip_type;

always #5 clk = ~clk;   // 100 MHz

// Downstream ready generator.  Throttled mode asserts ip_rx_axis_tready only
// 1 cycle in 10, so the output FIFO fills and the DUT must backpressure its
// ingress (frame_rx_axis_tready deasserts) without losing or corrupting data.
always @(posedge clk) begin
    if (tready_throttle) begin
        throttle_cnt <= throttle_cnt + 1'b1;
        ip_tready    <= (throttle_cnt % 10 == 8'd0);
    end
    else begin
        throttle_cnt <= 8'd0;
        ip_tready    <= 1'b1;
    end
end

// Track whether ingress backpressure was ever observed (valid held while not ready).
always @(posedge clk) begin
    if (frame_tvalid && !frame_tready)
        saw_tready_low <= 1'b1;
end

ip_rx dut (
    .clk                 (clk),
    .rst                 (rst),

    .frame_rx_axis_tdata (frame_tdata),
    .frame_rx_axis_tkeep (frame_tkeep),
    .frame_rx_axis_tvalid(frame_tvalid),
    .frame_rx_axis_tuser (frame_tuser),
    .frame_rx_axis_tlast (frame_tlast),
    .frame_rx_axis_tready(frame_tready),

    .ip_rx_axis_tdata    (ip_tdata),
    .ip_rx_axis_tkeep    (ip_tkeep),
    .ip_rx_axis_tvalid   (ip_tvalid),
    .ip_rx_axis_tuser    (ip_tuser),
    .ip_rx_axis_tlast    (ip_tlast),
    .ip_rx_axis_tready   (ip_tready),

    .local_ip_addr       (local_ip),
    .recv_dst_ip_addr    (recv_dst_ip),
    .recv_src_ip_addr    (recv_src_ip),
    .ip_type             (ip_type)
);

integer error_count = 0;

//---------------------------------------------------------------------------
// Reference packet builder.  Lays a full IPv4 packet (20-byte header +
// plen payload bytes) into pkt[].  The header checksum is computed so that
// the one's-complement sum over the 10 header words (checksum field
// included) folds to 16'hffff.
//---------------------------------------------------------------------------
reg [7:0] pkt [0:8191];
integer   total_len;

function [15:0] chk_add(input [15:0] a, input [15:0] b);
    reg [16:0] s;
    begin
        s = a + b;
        chk_add = s[16] ? s[15:0] + 16'd1 : s[15:0];
    end
endfunction

task build_ip_header(input [31:0] src, input [31:0] dst,
                     input [7:0] proto, input integer plen);
    reg [15:0] sum;
    integer    j;
    begin
        total_len = 20 + plen;
        pkt[0]  = 8'h45;                     // version 4, IHL 5
        pkt[1]  = 8'h00;                     // TOS
        pkt[2]  = total_len[15:8];           // total length (hi)
        pkt[3]  = total_len[7:0];            // total length (lo)
        pkt[4]  = 8'h00; pkt[5] = 8'h00;     // identification
        pkt[6]  = 8'h00; pkt[7] = 8'h00;     // flags / fragment offset
        pkt[8]  = 8'h40;                     // TTL
        pkt[9]  = proto;                     // protocol
        pkt[10] = 8'h00; pkt[11] = 8'h00;    // header checksum placeholder
        pkt[12] = src[31:24]; pkt[13] = src[23:16];
        pkt[14] = src[15:8];  pkt[15] = src[7:0];
        pkt[16] = dst[31:24]; pkt[17] = dst[23:16];
        pkt[18] = dst[15:8];  pkt[19] = dst[7:0];
        sum = 16'd0;
        for (j = 0; j < 10; j = j + 1)
            sum = chk_add(sum, {pkt[2*j], pkt[2*j+1]});
        sum = ~sum;
        if (sum == 16'd0) sum = 16'hffff;
        pkt[10] = sum[15:8];
        pkt[11] = sum[7:0];
    end
endtask

//---------------------------------------------------------------------------
// AXI-Stream ingress driver.  Inputs are presented at the negedge so they
// are stable before the posedge where the DUT samples them; the driver then
// holds tvalid until the accepting posedge.  This avoids any tvalid/tready
// race with the DUT's combinational ready path.
//---------------------------------------------------------------------------
function [63:0] beat_data(input integer k);
    begin
        beat_data = {pkt[k*8+7], pkt[k*8+6], pkt[k*8+5], pkt[k*8+4],
                     pkt[k*8+3], pkt[k*8+2], pkt[k*8+1], pkt[k*8+0]};
    end
endfunction

function [7:0] beat_keep(input integer k, input integer nbytes);
    integer n;
    begin
        n = nbytes - k*8;
        beat_keep = (n >= 8) ? 8'hff : ((1 << n) - 1);
    end
endfunction

//---------------------------------------------------------------------------
// Captured ingress beats (what was actually driven into frame_rx_axis).
// The independent data-consistency checker reconstructs the expected
// payload from these beats (skipping the 20-byte IPv4 header) and compares
// it byte-for-byte against the captured egress beats.
//---------------------------------------------------------------------------
reg [63:0] in_data [0:1023];
reg [7:0]  in_keep [0:1023];
integer    in_nb;
reg [7:0]  ref_byte [0:8191];
integer    ref_len;

function [63:0] ref_beat(input integer k, input integer plen);
    begin
        ref_beat[7:0]   = (k*8+0 < plen) ? ref_byte[k*8+0] : 8'h0;
        ref_beat[15:8]  = (k*8+1 < plen) ? ref_byte[k*8+1] : 8'h0;
        ref_beat[23:16] = (k*8+2 < plen) ? ref_byte[k*8+2] : 8'h0;
        ref_beat[31:24] = (k*8+3 < plen) ? ref_byte[k*8+3] : 8'h0;
        ref_beat[39:32] = (k*8+4 < plen) ? ref_byte[k*8+4] : 8'h0;
        ref_beat[47:40] = (k*8+5 < plen) ? ref_byte[k*8+5] : 8'h0;
        ref_beat[55:48] = (k*8+6 < plen) ? ref_byte[k*8+6] : 8'h0;
        ref_beat[63:56] = (k*8+7 < plen) ? ref_byte[k*8+7] : 8'h0;
    end
endfunction

task send_beat(input integer k, input integer nbytes,
               input last_flag, input user_flag);
    begin
        @(negedge clk);
        frame_tdata  = beat_data(k);
        frame_tkeep  = beat_keep(k, nbytes);
        frame_tlast  = last_flag;
        frame_tuser  = user_flag;
        in_data[k]   = frame_tdata;   // record the actual ingress beat
        in_keep[k]   = frame_tkeep;
        frame_tvalid = 1'b1;
        while (frame_tready !== 1'b1) @(posedge clk);
        @(posedge clk);          // accepting posedge
        // deassert only on the following negedge so tvalid stays stable
        // through the accepting posedge (no race with the DUT clocked logic)
        @(negedge clk);
        frame_tvalid = 1'b0;
        frame_tlast  = 1'b0;
        frame_tuser  = 1'b0;
    end
endtask

task send_frame(input integer nbytes, input user_flag);
    integer nb, k;
    begin
        nb = (nbytes + 7) / 8;
        in_nb = nb;
        frame_tvalid = 1'b0;
        frame_tlast  = 1'b0;
        frame_tuser  = 1'b0;
        @(negedge clk);
        for (k = 0; k < nb; k = k + 1)
            send_beat(k, nbytes, (k == nb-1), (k == nb-1) ? user_flag : 1'b0);
    end
endtask

//---------------------------------------------------------------------------
// Egress capture: sample at the posedge, before the FWFT FIFO pop takes
// effect, collecting data/keep/last/user for one complete frame.
//---------------------------------------------------------------------------
reg [63:0] od [0:1023];
reg [7:0]  ok [0:1023];
reg        ol [0:1023];
reg        ou [0:1023];
integer    ocnt;

task capture_output;
    reg done;
    begin
        ocnt = 0;
        done = 0;
        while (!done) begin
            @(posedge clk);
            if (ip_tvalid && ip_tready) begin
                od[ocnt] = ip_tdata;
                ok[ocnt] = ip_tkeep;
                ol[ocnt] = ip_tlast;
                ou[ocnt] = ip_tuser;
                if (ip_tlast) done = 1;
                else          ocnt = ocnt + 1;
            end
        end
    end
endtask

function [63:0] out_beat(input integer base, input integer total);
    begin
        out_beat[7:0]   = (base+0 < total) ? pkt[base+0] : 8'h0;
        out_beat[15:8]  = (base+1 < total) ? pkt[base+1] : 8'h0;
        out_beat[23:16] = (base+2 < total) ? pkt[base+2] : 8'h0;
        out_beat[31:24] = (base+3 < total) ? pkt[base+3] : 8'h0;
        out_beat[39:32] = (base+4 < total) ? pkt[base+4] : 8'h0;
        out_beat[47:40] = (base+5 < total) ? pkt[base+5] : 8'h0;
        out_beat[55:48] = (base+6 < total) ? pkt[base+6] : 8'h0;
        out_beat[63:56] = (base+7 < total) ? pkt[base+7] : 8'h0;
    end
endfunction

// Independent data-consistency check: reconstruct the expected payload from
// the captured ingress stream (skipping the 20-byte IPv4 header) and compare
// it byte-for-byte against the captured egress beats.  This verifies that the
// data portion passing through the DUT is unchanged, without relying on the
// reference packet builder.
task check_data_consistency;
    integer b, j, byte_idx, plen, nbeats, rem;
    reg [63:0] ed;
    reg [7:0]  ek;
    begin
        ref_len  = 0;
        byte_idx = 0;
        for (b = 0; b < in_nb; b = b + 1) begin
            for (j = 0; j < 8; j = j + 1) begin
                if (in_keep[b][j]) begin
                    if (byte_idx >= 20) begin
                        ref_byte[ref_len] = in_data[b][j*8 +: 8];
                        ref_len = ref_len + 1;
                    end
                    byte_idx = byte_idx + 1;
                end
            end
        end

        plen   = ref_len;
        nbeats = (plen + 7) / 8;
        rem    = plen % 8;

        if (ocnt + 1 != nbeats) begin
            $display("  FAIL(data-cmp): beat count %0d, expected %0d", ocnt+1, nbeats);
            error_count = error_count + 1;
        end
        for (j = 0; j < nbeats; j = j + 1) begin
            ed = ref_beat(j, plen);
            ek = (j < nbeats-1) ? 8'hff : ((rem == 0) ? 8'hff : ((1 << rem) - 1));
            if (od[j] !== ed) begin
                $display("  FAIL(data-cmp): beat %0d data=%h, expected %h", j, od[j], ed);
                error_count = error_count + 1;
            end
            if (ok[j] !== ek) begin
                $display("  FAIL(data-cmp): beat %0d keep=%h, expected %h", j, ok[j], ek);
                error_count = error_count + 1;
            end
        end
    end
endtask

task check_output(input integer exp_tuser);
    integer plen, nbeats, rem, j;
    reg [63:0] ed;
    reg [7:0]  ek;
    begin
        plen   = total_len - 20;
        nbeats = (plen + 7) / 8;
        rem    = plen % 8;
        if (ocnt + 1 != nbeats) begin
            $display("  FAIL: beat count %0d, expected %0d", ocnt+1, nbeats);
            error_count = error_count + 1;
        end
        for (j = 0; j < nbeats; j = j + 1) begin
            ed = out_beat(20 + j*8, total_len);
            ek = (j < nbeats-1) ? 8'hff : ((rem == 0) ? 8'hff : ((1 << rem) - 1));
            if (od[j] !== ed) begin
                $display("  FAIL: beat %0d data=%h, expected %h", j, od[j], ed);
                error_count = error_count + 1;
            end
            if (ok[j] !== ek) begin
                $display("  FAIL: beat %0d keep=%h, expected %h", j, ok[j], ek);
                error_count = error_count + 1;
            end
            if (j < nbeats-1 && ol[j] !== 1'b0) begin
                $display("  FAIL: beat %0d tlast should be 0", j);
                error_count = error_count + 1;
            end
        end
        if (ol[nbeats-1] !== 1'b1) begin
            $display("  FAIL: last beat tlast=%b", ol[nbeats-1]);
            error_count = error_count + 1;
        end
        if (ou[nbeats-1] !== exp_tuser) begin
            $display("  FAIL: last beat tuser=%b, expected %b", ou[nbeats-1], exp_tuser);
            error_count = error_count + 1;
        end

        // independent input-payload vs output-payload byte comparison
        check_data_consistency;
    end
endtask

task fill_payload(input integer plen, input integer base);
    integer j;
    begin
        for (j = 0; j < plen; j = j + 1)
            pkt[20 + j] = base + j;
    end
endtask

//---------------------------------------------------------------------------
initial begin
    integer j;
    integer L;
    rst = 1;
    repeat (6) @(posedge clk);
    rst = 0;
    repeat (2) @(posedge clk);

    // TEST 1 : good packet, 8-byte payload (tail in low 4 bytes, no flush)
    $display("TEST1: good checksum, payload=8");
    build_ip_header(32'hC0A8010A, 32'hC0A80114, 8'h11, 8);
    fill_payload(8, 32'h10);
    fork
        send_frame(total_len, 1'b0);
        capture_output;
    join
    check_output(1'b0);
    if (ip_type !== 16'h0011) begin
        $display("  FAIL: ip_type=%h, expected 0011", ip_type);
        error_count = error_count + 1;
    end
    if (recv_src_ip !== 32'hC0A8010A) begin
        $display("  FAIL: recv_src_ip=%h", recv_src_ip);
        error_count = error_count + 1;
    end
    if (recv_dst_ip !== 32'hC0A80114) begin
        $display("  FAIL: recv_dst_ip=%h", recv_dst_ip);
        error_count = error_count + 1;
    end
    repeat (4) @(posedge clk);

    // TEST 2 : good packet, 20-byte payload (tail spans high 4 bytes -> flush)
    $display("TEST2: good checksum, payload=20");
    build_ip_header(32'hC0A8010A, 32'hC0A80114, 8'h11, 20);
    fill_payload(20, 32'hA0);
    fork
        send_frame(total_len, 1'b0);
        capture_output;
    join
    check_output(1'b0);
    repeat (4) @(posedge clk);

    // TEST 2b : good packet, 13-byte payload (tail ends in the low 4 bytes
    //           with a partial last beat -> masked lanes must not be X)
    $display("TEST2b: good checksum, payload=13");
    build_ip_header(32'hC0A8010A, 32'hC0A80114, 8'h11, 13);
    fill_payload(13, 32'h50);
    fork
        send_frame(total_len, 1'b0);
        capture_output;
    join
    check_output(1'b0);
    repeat (4) @(posedge clk);

    // TEST 2c : good packet, 17-byte payload (tail spans the high 4 bytes
    //           with a partial last beat -> flush-beat masked lanes must not
    //           be X)
    $display("TEST2c: good checksum, payload=17");
    build_ip_header(32'hC0A8010A, 32'hC0A80114, 8'h11, 17);
    fill_payload(17, 32'h70);
    fork
        send_frame(total_len, 1'b0);
        capture_output;
    join
    check_output(1'b0);
    repeat (4) @(posedge clk);

    // TEST 3 : bad header checksum -> ip_rx_axis_tuser must be 1
    $display("TEST3: bad checksum, payload=8");
    build_ip_header(32'hC0A8010A, 32'hC0A80114, 8'h11, 8);
    fill_payload(8, 32'h10);
    pkt[10] = 8'h00; pkt[11] = 8'h00;   // corrupt the checksum field
    fork
        send_frame(total_len, 1'b0);
        capture_output;
    join
    check_output(1'b1);
    repeat (4) @(posedge clk);

    // TEST 4 : good checksum but frame_rx_axis_tuser = 1 -> tuser = 1
    $display("TEST4: frame error (tuser=1), payload=8");
    build_ip_header(32'hC0A8010A, 32'hC0A80114, 8'h11, 8);
    fill_payload(8, 32'h10);
    fork
        send_frame(total_len, 1'b1);
        capture_output;
    join
    check_output(1'b1);
    repeat (4) @(posedge clk);

    // TEST 4b : destination IP is neither local nor broadcast -> dropped
    $display("TEST4b: dst IP 192.168.1.99 (not local) -> dropped silently");
    build_ip_header(32'hC0A8010A, 32'hC0A80163, 8'h11, 20);
    fill_payload(20, 32'h20);
    send_frame(total_len, 1'b0);   // no capture fork: nothing must come out
    begin : t4b
        integer c;
        reg quiet = 1'b1;
        for (c = 0; c < 100; c = c + 1) begin
            @(posedge clk);
            if (ip_tvalid) quiet = 1'b0;
        end
        if (quiet) $display("  dst-IP filter: no output for a foreign dst IP");
        else begin
            $display("  ERROR: data appeared for a foreign dst IP");
            error_count = error_count + 1;
        end
    end

    // TEST 4c : limited broadcast (255.255.255.255) is still accepted
    $display("TEST4c: dst IP 255.255.255.255 (limited broadcast) -> accepted");
    build_ip_header(32'hC0A8010A, 32'hFFFFFFFF, 8'h11, 20);
    fill_payload(20, 32'h21);
    fork
        send_frame(total_len, 1'b0);
        capture_output;
    join
    check_output(1'b0);
    repeat (4) @(posedge clk);

    // ------------------------------------------------------------------
    // Backpressure stress: a 6000-byte payload (750 beats) exceeds the
    // 512-beat output FIFO, so with a throttled downstream the DUT must
    // deassert frame_rx_axis_tready and still deliver byte-perfect data.
    // ------------------------------------------------------------------
    $display("BACKPRESSURE: payload=6000, downstream throttled 1/10");
    saw_tready_low  = 1'b0;
    tready_throttle = 1'b1;
    build_ip_header(32'hC0A8010A, 32'hC0A80114, 8'h11, 6000);
    fill_payload(6000, 32'h00);
    fork
        send_frame(total_len, 1'b0);
        capture_output;
    join
    check_output(1'b0);
    tready_throttle = 1'b0;
    repeat (4) @(posedge clk);
    if (saw_tready_low)
        $display("  backpressure propagated: frame_rx_axis_tready deasserted");
    else begin
        $display("  NOTE: frame_rx_axis_tready never deasserted");
        error_count = error_count + 1;
    end

    // ------------------------------------------------------------------
    // Payload-length sweep 65..129: every length is built, transmitted and
    // checked (data + keep + tlast + tuser + input-vs-output consistency).
    // ------------------------------------------------------------------
    $display("SWEEP: payload length 65..129 (full rate)");
    for (L = 65; L <= 129; L = L + 1) begin
        build_ip_header(32'hC0A8010A, 32'hC0A80114, 8'h11, L);
        fill_payload(L, L);
        fork
            send_frame(total_len, 1'b0);
            capture_output;
        join
        check_output(1'b0);
    end
    $display("SWEEP done: lengths 65..129 checked");

    if (error_count == 0)
        $display("TEST_PASS: all ip_rx checks passed");
    else
        $display("TEST_FAIL: %0d error(s)", error_count);
    $finish;
end

// watchdog
initial begin
    #5000000;
    $display("TEST_FAIL: watchdog timeout");
    $finish;
end

endmodule
`resetall
