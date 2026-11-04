`timescale 1ns / 1ps

/*
 * SystemVerilog testbench for verilog-ethernet rtl/eth_axis_tx.v (self-checking)
 *
 * eth_axis_tx prepends a 14-byte Ethernet header (given on parallel inputs) to
 * an AXIS payload and streams the complete frame on m_axis.
 *
 * Scenario (same addresses as tb_arp):
 *   local  : IP 192.168.1.24, MAC 00:0a:35:13:45:71
 *   remote : IP 192.168.1.33, MAC 00:0a:35:72:23:12
 *
 * Tests:
 *   1. ARP request frame first (broadcast, ethertype 0x0806, 28-byte ARP packet)
 *        -> 28 B < 46 B minimum: frame zero-padded to 60 bytes, verified
 *           field by field including the pad bytes
 *   2. 4 data frames (dst=remote MAC, ethertype 0x0800), each 1024 bytes =
 *      256 int (32-bit) words; word value increments across ALL frames
 *      (0..255, 256..511, 512..767, 768..1023), big-endian byte order
 *      -> already >= minimum, no padding, frame length stays 1038
 *   3. short data frame (20-byte payload = 5 int words continuing the
 *      counter at 1024..1028) -> padded to 60 bytes, pad bytes zero
 *   4. busy asserted during transfer, deasserted when idle
 *   5. output tuser clean; m_axis backpressure applied to data frames 2..4
 */

module tb_eth_axis_tx;

// DUT configuration
parameter DATA_WIDTH = 64;
parameter KEEP_ENABLE = (DATA_WIDTH > 8);
parameter KEEP_WIDTH = (DATA_WIDTH/8);

// scenario addresses
localparam [47:0] LOCAL_MAC   = 48'h00_0a_35_13_45_71;              // us
localparam [31:0] LOCAL_IP    = {8'd192, 8'd168, 8'd1, 8'd24};
localparam [47:0] REMOTE_MAC  = 48'h00_0a_35_72_23_12;              // peer
localparam [31:0] REMOTE_IP   = {8'd192, 8'd168, 8'd1, 8'd33};

// frame plan
localparam NFRAMES       = 4;      // data frames
localparam FRAME_LEN     = 1024;   // payload bytes per frame
localparam WORDS_FRAME   = FRAME_LEN/4;
parameter MIN_PAYLOAD    = 46;     // must match DUT MIN_PAYLOAD_BYTES (60-byte min frame); 0 = no padding

localparam [47:0] BCAST_MAC     = 48'hff_ff_ff_ff_ff_ff;
localparam [15:0] ETHERTYPE_ARP = 16'h0806;
localparam [15:0] ETHERTYPE_IP  = 16'h0800;
localparam [15:0] OPER_REQUEST  = 16'h0001;

// clock / reset
reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;    // 100 MHz

// scoreboard
integer pass_count = 0;
integer fail_count = 0;

// DUT inputs
reg  s_eth_hdr_valid = 1'b0;
reg  [47:0] s_eth_dest_mac = 48'd0;
reg  [47:0] s_eth_src_mac = 48'd0;
reg  [15:0] s_eth_type = 16'd0;
reg  [DATA_WIDTH-1:0] s_eth_payload_axis_tdata = {DATA_WIDTH{1'b0}};
reg  [KEEP_WIDTH-1:0] s_eth_payload_axis_tkeep = {KEEP_WIDTH{1'b1}};
reg  s_eth_payload_axis_tvalid = 1'b0;
reg  s_eth_payload_axis_tlast = 1'b0;
reg  s_eth_payload_axis_tuser = 1'b0;

// DUT outputs
wire s_eth_hdr_ready;
wire s_eth_payload_axis_tready;

wire [DATA_WIDTH-1:0] m_axis_tdata;
wire [KEEP_WIDTH-1:0] m_axis_tkeep;
wire m_axis_tvalid;
wire m_axis_tlast;
wire m_axis_tuser;

// output-side backpressure (updated on posedge so the negedge monitor samples
// exactly the values the next posedge will capture)
reg        m_axis_tready = 1'b1;
reg        bp_en = 1'b0;
integer    bp_cnt = 0;
always @(posedge clk) begin
    if (rst) begin
        m_axis_tready <= 1'b1;
        bp_cnt <= 0;
    end else if (bp_en) begin
        bp_cnt <= (bp_cnt + 1) % 8;
        m_axis_tready <= (bp_cnt < 6);   // 6 cycles on, 2 cycles off
    end else begin
        m_axis_tready <= 1'b1;
    end
end

wire busy;

eth_axis_tx_v1 #(
    .DATA_WIDTH(DATA_WIDTH),
    .KEEP_ENABLE(KEEP_ENABLE),
    .KEEP_WIDTH(KEEP_WIDTH)
)
UUT (
    .clk(clk),
    .rst(rst),
    // Ethernet frame input
    .s_eth_dest_mac(s_eth_dest_mac),
    .s_eth_src_mac(s_eth_src_mac),
    .s_eth_type(s_eth_type),
    .s_eth_payload_axis_tdata(s_eth_payload_axis_tdata),
    .s_eth_payload_axis_tkeep(s_eth_payload_axis_tkeep),
    .s_eth_payload_axis_tvalid(s_eth_payload_axis_tvalid),
    .s_eth_payload_axis_tready(s_eth_payload_axis_tready),
    .s_eth_payload_axis_tlast(s_eth_payload_axis_tlast),
    .s_eth_payload_axis_tuser(s_eth_payload_axis_tuser),
    // AXI output
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser),
    // Status
    .busy(busy)
);

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function automatic string mac_str(input [47:0] m);
    return $sformatf("%02x:%02x:%02x:%02x:%02x:%02x",
                     m[47:40], m[39:32], m[31:24], m[23:16], m[15:8], m[7:0]);
endfunction

function automatic string ip_str(input [31:0] ip);
    return $sformatf("%0d.%0d.%0d.%0d", ip[31:24], ip[23:16], ip[15:8], ip[7:0]);
endfunction

task automatic check(input logic cond, input string msg);
    if (cond) begin
        pass_count = pass_count + 1;
        $display("[%0t]   PASS: %0s", $time, msg);
    end else begin
        fail_count = fail_count + 1;
        $display("[%0t]   FAIL: %0s", $time, msg);
    end
endtask

// captured output frame (complete: header + payload)
byte rx_q[$];
reg busy_seen;
reg tuser_err;

// collect one frame from m_axis (lane-aware; a beat counts only when the
// next posedge will actually consume it: tvalid && tready at negedge)
task automatic recv_frame;
    integer lane;
begin
    rx_q.delete();
    busy_seen = 1'b0;
    tuser_err = 1'b0;
    @(negedge clk);
    while (!(m_axis_tvalid === 1'b1 && m_axis_tready === 1'b1)) begin
        if (busy) busy_seen = 1'b1;
        @(negedge clk);
    end
    forever begin
        if (m_axis_tvalid === 1'b1 && m_axis_tready === 1'b1) begin
            for (lane = 0; lane < KEEP_WIDTH; lane = lane + 1) begin
                if (m_axis_tkeep[lane] === 1'b1)
                    rx_q.push_back(m_axis_tdata[lane*8 +: 8]);
            end
            if (m_axis_tlast === 1'b1) begin
                if (m_axis_tuser !== 1'b0)
                    tuser_err = 1'b1;
                break;
            end
        end
        if (busy) busy_seen = 1'b1;
        @(negedge clk);
    end
    $display("[%0t] m_axis frame: len=%0d bytes", $time, rx_q.size());
end
endtask

// send one frame into s_eth (pack KEEP_WIDTH bytes per beat)
task automatic send_frame(input [47:0] dst, input [47:0] src,
                          input [15:0] eth_type, input byte payload[]);
    integer i, j;
    integer n;
begin
    // ethernet header
    @(negedge clk);
    s_eth_hdr_valid <= 1'b1;
    s_eth_dest_mac  <= dst;
    s_eth_src_mac   <= src;
    s_eth_type      <= eth_type;
    while (s_eth_hdr_ready !== 1'b1) @(negedge clk);
    @(negedge clk);
    s_eth_hdr_valid <= 1'b0;
    // payload: pack KEEP_WIDTH bytes per beat (byte i -> lane i%KEEP_WIDTH)
    for (i = 0; i < payload.size(); i = i + KEEP_WIDTH) begin
        n = (payload.size() - i) > KEEP_WIDTH ? KEEP_WIDTH : (payload.size() - i);
        s_eth_payload_axis_tvalid <= 1'b1;
        s_eth_payload_axis_tdata  <= {DATA_WIDTH{1'b0}};
        for (j = 0; j < KEEP_WIDTH; j = j + 1) begin
            if (j < n)
                s_eth_payload_axis_tdata[j*8 +: 8] <= payload[i + j];
        end
        s_eth_payload_axis_tkeep <= {KEEP_WIDTH{1'b1}} >> (KEEP_WIDTH - n);
        s_eth_payload_axis_tlast <= (i + KEEP_WIDTH >= payload.size());
        while (s_eth_payload_axis_tready !== 1'b1) @(negedge clk);
        @(negedge clk);
    end
    s_eth_payload_axis_tvalid <= 1'b0;
    s_eth_payload_axis_tlast  <= 1'b0;
    s_eth_payload_axis_tkeep  <= {KEEP_WIDTH{1'b1}};
end
endtask

// build a 28-byte ARP request packet
function automatic void build_arp_request(output byte p[]);
begin
    p = new[28];
    p[0]  = 8'h00; p[1]  = 8'h01;                          // HTYPE = 1 (Ethernet)
    p[2]  = 8'h08; p[3]  = 8'h00;                          // PTYPE = 0x0800 (IPv4)
    p[4]  = 8'h06;                                         // HLEN = 6
    p[5]  = 8'h04;                                         // PLEN = 4
    p[6]  = OPER_REQUEST[15:8]; p[7]  = OPER_REQUEST[7:0]; // OPER = request
    p[8]  = LOCAL_MAC[47:40];  p[9]  = LOCAL_MAC[39:32];
    p[10] = LOCAL_MAC[31:24];  p[11] = LOCAL_MAC[23:16];
    p[12] = LOCAL_MAC[15:8];   p[13] = LOCAL_MAC[7:0];
    p[14] = LOCAL_IP[31:24];   p[15] = LOCAL_IP[23:16];
    p[16] = LOCAL_IP[15:8];    p[17] = LOCAL_IP[7:0];
    p[18] = 8'h00; p[19] = 8'h00; p[20] = 8'h00;           // THA = 0 (unknown)
    p[21] = 8'h00; p[22] = 8'h00; p[23] = 8'h00;
    p[24] = REMOTE_IP[31:24];  p[25] = REMOTE_IP[23:16];
    p[26] = REMOTE_IP[15:8];   p[27] = REMOTE_IP[7:0];
end
endfunction

// build a payload of incrementing 32-bit words (big-endian), starting at base
function automatic void build_data_payload(input integer base, input integer nwords,
                                           output byte p[]);
    integer i;
begin
    p = new[nwords*4];
    for (i = 0; i < nwords; i = i + 1) begin
        p[i*4+0] = (base + i) >> 24;
        p[i*4+1] = (base + i) >> 16;
        p[i*4+2] = (base + i) >> 8;
        p[i*4+3] = (base + i);
    end
end
endfunction

// receive one frame and verify the complete ARP request field by field
task automatic expect_arp_frame(input [47:0] dst, input [47:0] src,
                                input [15:0] oper,
                                input [47:0] sha, input [31:0] spa,
                                input [47:0] tha, input [31:0] tpa);
    reg [15:0] v16;
    reg [31:0] v32;
    reg [47:0] v48;
    integer k, perr, exp_len;
begin
    recv_frame();
    exp_len = 14 + (28 < MIN_PAYLOAD ? MIN_PAYLOAD : 28);
    check(rx_q.size() == exp_len,
          $sformatf("ARP frame length = %0d (14 + %0d)", exp_len, rx_q.size() - 14));
    v48 = {rx_q[0], rx_q[1], rx_q[2], rx_q[3], rx_q[4], rx_q[5]};
    check(v48 == dst, $sformatf("eth dst  = %s", mac_str(dst)));
    v48 = {rx_q[6], rx_q[7], rx_q[8], rx_q[9], rx_q[10], rx_q[11]};
    check(v48 == src, $sformatf("eth src  = %s", mac_str(src)));
    v16 = {rx_q[12], rx_q[13]};
    check(v16 == ETHERTYPE_ARP,                    "ethertype = 0x0806");
    v16 = {rx_q[14], rx_q[15]};
    check(v16 == 16'h0001,                         "HTYPE = 1");
    v16 = {rx_q[16], rx_q[17]};
    check(v16 == 16'h0800,                         "PTYPE = 0x0800");
    check(rx_q[18] == 8'h06,                       "HLEN = 6");
    check(rx_q[19] == 8'h04,                       "PLEN = 4");
    v16 = {rx_q[20], rx_q[21]};
    check(v16 == oper, $sformatf("OPER = 0x%04x", oper));
    v48 = {rx_q[22], rx_q[23], rx_q[24], rx_q[25], rx_q[26], rx_q[27]};
    check(v48 == sha, $sformatf("SHA = %s", mac_str(sha)));
    v32 = {rx_q[28], rx_q[29], rx_q[30], rx_q[31]};
    check(v32 == spa, $sformatf("SPA = %s", ip_str(spa)));
    v48 = {rx_q[32], rx_q[33], rx_q[34], rx_q[35], rx_q[36], rx_q[37]};
    check(v48 == tha, $sformatf("THA = %s", mac_str(tha)));
    v32 = {rx_q[38], rx_q[39], rx_q[40], rx_q[41]};
    check(v32 == tpa, $sformatf("TPA = %s", ip_str(tpa)));
    perr = 0;
    for (k = 42; k < rx_q.size(); k = k + 1)
        if (rx_q[k] != 0) perr = perr + 1;
    check(perr == 0, $sformatf("ARP pad bytes all zero (%0d pad bytes)", rx_q.size() - 42));
    check(busy_seen === 1'b1,                      "busy asserted during frame");
    check(tuser_err === 1'b0,                      "output tuser clean");
end
endtask

// receive one data frame and verify header, incrementing int words and the
// minimum-length zero padding (nbytes = actual payload bytes sent)
task automatic expect_data_frame(input [47:0] dst, input [47:0] src,
                                 input [15:0] eth_type,
                                 input integer base, input integer idx,
                                 input integer nbytes);
    reg [47:0] v48;
    reg [15:0] v16;
    reg [31:0] wexp, wgot;
    integer i, k, werr, perr, exp_len;
begin
    recv_frame();
    exp_len = 14 + (nbytes < MIN_PAYLOAD ? MIN_PAYLOAD : nbytes);
    check(rx_q.size() == exp_len,
          $sformatf("frame %0d length = %0d (14 + %0d payload + %0d pad)",
                    idx, exp_len, nbytes, exp_len - 14 - nbytes));
    v48 = {rx_q[0], rx_q[1], rx_q[2], rx_q[3], rx_q[4], rx_q[5]};
    check(v48 == dst, $sformatf("frame %0d eth dst = %s", idx, mac_str(dst)));
    v48 = {rx_q[6], rx_q[7], rx_q[8], rx_q[9], rx_q[10], rx_q[11]};
    check(v48 == src, $sformatf("frame %0d eth src = %s", idx, mac_str(src)));
    v16 = {rx_q[12], rx_q[13]};
    check(v16 == eth_type, $sformatf("frame %0d ethertype = 0x%04x", idx, eth_type));
    werr = 0;
    for (i = 0; i < nbytes/4; i = i + 1) begin
        wexp = base + i;
        wgot = {rx_q[14 + i*4], rx_q[14 + i*4 + 1], rx_q[14 + i*4 + 2], rx_q[14 + i*4 + 3]};
        if (wgot !== wexp) begin
            werr = werr + 1;
            $display("[%0t]   first mismatch: word %0d got 0x%08x exp 0x%08x",
                     $time, i, wgot, wexp);
        end
    end
    check(werr == 0, $sformatf("frame %0d: %0d int words increment from %0d to %0d (%0d mismatches)",
                               idx, nbytes/4, base, base + nbytes/4 - 1, werr));
    perr = 0;
    for (k = 14 + nbytes; k < rx_q.size(); k = k + 1)
        if (rx_q[k] != 0) perr = perr + 1;
    check(perr == 0, $sformatf("frame %0d pad bytes all zero (%0d pad bytes)",
                               idx, rx_q.size() - 14 - nbytes));
    check(busy_seen === 1'b1, $sformatf("frame %0d busy asserted during transfer", idx));
    check(tuser_err === 1'b0, $sformatf("frame %0d output tuser clean", idx));
end
endtask

// ---------------------------------------------------------------------------
// main stimulus
// ---------------------------------------------------------------------------

integer f;
byte p[];

initial begin
    $timeformat(-9, 2, " ns", 12);

    // reset
    rst = 1'b1;
    repeat (20) @(negedge clk);
    rst = 1'b0;
    repeat (20) @(negedge clk);

    check(busy === 1'b0, "idle after reset (busy = 0)");
    check(m_axis_tvalid === 1'b0, "no output traffic after reset");

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST 1: ARP request frame =====", $time);
    build_arp_request(p);
    fork
        send_frame(BCAST_MAC, LOCAL_MAC, ETHERTYPE_ARP, p);
        expect_arp_frame(BCAST_MAC, LOCAL_MAC, OPER_REQUEST,
                         LOCAL_MAC, LOCAL_IP, 48'h0, REMOTE_IP);
    join
    repeat (4) @(negedge clk);
    check(busy === 1'b0, "TEST1: idle after ARP frame (busy = 0)");

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST 2: %0d data frames, %0d bytes each, int-incrementing payload =====",
             $time, NFRAMES, FRAME_LEN);
    for (f = 0; f < NFRAMES; f = f + 1) begin
        // apply output backpressure to frames 2..4
        bp_en = (f >= 1);
        build_data_payload(f*WORDS_FRAME, WORDS_FRAME, p);
        fork
            send_frame(REMOTE_MAC, LOCAL_MAC, ETHERTYPE_IP, p);
            expect_data_frame(REMOTE_MAC, LOCAL_MAC, ETHERTYPE_IP,
                              f*WORDS_FRAME, f, FRAME_LEN);
        join
        repeat (4) @(negedge clk);
        check(busy === 1'b0, $sformatf("frame %0d: idle afterwards (busy = 0)", f));
    end
    bp_en = 1'b0;

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST 3: short frame (20 B payload) padded to minimum =====", $time);
    build_data_payload(NFRAMES*WORDS_FRAME, 5, p);   // 5 int words, counter continues at 1024
    fork
        send_frame(REMOTE_MAC, LOCAL_MAC, ETHERTYPE_IP, p);
        expect_data_frame(REMOTE_MAC, LOCAL_MAC, ETHERTYPE_IP,
                          NFRAMES*WORDS_FRAME, NFRAMES, 20);
    join
    repeat (4) @(negedge clk);
    check(busy === 1'b0, "short frame: idle afterwards (busy = 0)");

    // -----------------------------------------------------------------
    repeat (10) @(negedge clk);
    check(m_axis_tvalid === 1'b0, "no output traffic at end");

    if (fail_count == 0)
        $display("[%0t] ================ ALL %0d CHECKS PASSED ================", $time, pass_count);
    else
        $display("[%0t] ================ %0d/%0d CHECKS FAILED ================", $time, fail_count, pass_count + fail_count);
    $finish;
end

// global watchdog
initial begin
    #1_000_000;   // 1 ms
    $display("FATAL: global timeout");
    $fatal(1);
end

endmodule
