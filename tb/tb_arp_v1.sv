`timescale 1ns / 1ps

/*
 * SystemVerilog testbench for rtl/arp/arp_v1.v (self-checking)
 *
 * Same scenarios as tb_arp.sv, but the ethernet header is NOT part of the
 * interface: the AXI streams carry only the 28 byte ARP packet (the ethernet
 * header is added by eth_axis_tx / removed by eth_axis_rx in the full stack).
 *
 *   local  (DUT)  : IP 192.168.1.24, MAC 00:0a:35:13:45:71
 *   remote (peer) : IP 192.168.1.33, MAC 00:0a:35:72:23:12
 *
 * Tests:
 *   1. cache miss  -> ARP request packet on wire -> peer replies -> arp_response with MAC
 *   2. same IP again -> cache hit, no new packet on wire
 *   3. incoming ARP request for local IP -> DUT auto-generates ARP reply
 *   4. clear_cache -> entry gone -> full wire exchange again
 *   5. destination outside subnet -> ARP request asks for gateway IP instead
 *   6. peer never answers -> retries exhausted -> arp_response with error
 */

module tb_arp_v1;

// DUT configuration (small timers so the simulation runs fast)
parameter DATA_WIDTH = 64;
parameter KEEP_ENABLE = (DATA_WIDTH > 8);
parameter KEEP_WIDTH = (DATA_WIDTH/8);
parameter CACHE_ADDR_WIDTH = 4;           // 16-entry cache
parameter REQUEST_RETRY_COUNT = 2;
parameter REQUEST_RETRY_INTERVAL = 200;   // cycles
parameter REQUEST_TIMEOUT = 600;          // cycles

// scenario addresses
localparam [47:0] LOCAL_MAC   = 48'h00_0a_35_13_45_71;              // us
localparam [31:0] LOCAL_IP    = {8'd192, 8'd168, 8'd1, 8'd24};
localparam [47:0] REMOTE_MAC  = 48'h00_0a_35_72_23_12;              // peer
localparam [31:0] REMOTE_IP   = {8'd192, 8'd168, 8'd1, 8'd33};
localparam [31:0] GATEWAY_IP  = {8'd192, 8'd168, 8'd1, 8'd1};
localparam [47:0] GATEWAY_MAC = 48'h00_0a_35_aa_bb_cc;
localparam [31:0] SUBNET_MASK = {8'd255, 8'd255, 8'd255, 8'd0};
localparam [31:0] OUTSIDE_IP  = {8'd192, 8'd168, 8'd5, 8'd33};      // outside /24
localparam [31:0] DEAD_IP     = {8'd192, 8'd168, 8'd1, 8'd99};      // nobody answers

localparam [15:0] OPER_REQUEST  = 16'h0001;
localparam [15:0] OPER_REPLY    = 16'h0002;

// clock / reset
reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;    // 100 MHz

// scoreboard
integer pass_count = 0;
integer fail_count = 0;
integer tx_packet_count = 0;

// DUT inputs (28 byte ARP packet, no ethernet header)
reg  [DATA_WIDTH-1:0] s_arp_axis_tdata = {DATA_WIDTH{1'b0}};
reg  [KEEP_WIDTH-1:0] s_arp_axis_tkeep = {KEEP_WIDTH{1'b1}};
reg  s_arp_axis_tvalid = 1'b0;
reg  s_arp_axis_tlast = 1'b0;
reg  s_arp_axis_tuser = 1'b0;

reg  arp_request_valid = 1'b0;
reg  [31:0] arp_request_ip = 32'd0;
wire arp_response_ready = 1'b1;

reg  [47:0] local_mac = LOCAL_MAC;
reg  [31:0] local_ip = LOCAL_IP;
reg  [31:0] gateway_ip = GATEWAY_IP;
reg  [31:0] subnet_mask = SUBNET_MASK;
reg  clear_cache = 1'b0;

// DUT outputs
wire s_arp_axis_tready;
wire m_arp_axis_tready = 1'b1;            // no backpressure on TX side

wire [DATA_WIDTH-1:0] m_arp_axis_tdata;
wire [KEEP_WIDTH-1:0] m_arp_axis_tkeep;
wire m_arp_axis_tvalid;
wire m_arp_axis_tlast;
wire m_arp_axis_tuser;

wire arp_request_ready;
wire arp_response_valid;
wire arp_response_error;
wire [47:0] arp_response_mac;

// count complete ARP packets handed out on the wire
always @(posedge clk) begin
    if (!rst && m_arp_axis_tvalid && m_arp_axis_tlast && m_arp_axis_tready) begin
        tx_packet_count <= tx_packet_count + 1;
    end
end

arp_layer #(
    .DATA_WIDTH(DATA_WIDTH),
    .KEEP_ENABLE(KEEP_ENABLE),
    .KEEP_WIDTH(KEEP_WIDTH),
    .CACHE_ADDR_WIDTH(CACHE_ADDR_WIDTH),
    .REQUEST_RETRY_COUNT(REQUEST_RETRY_COUNT),
    .REQUEST_RETRY_INTERVAL(REQUEST_RETRY_INTERVAL),
    .REQUEST_TIMEOUT(REQUEST_TIMEOUT)
)
UUT (
    .clk(clk),
    .rst(rst),
    // ARP packet input
    .s_arp_axis_tdata(s_arp_axis_tdata),
    .s_arp_axis_tkeep(s_arp_axis_tkeep),
    .s_arp_axis_tvalid(s_arp_axis_tvalid),
    .s_arp_axis_tready(s_arp_axis_tready),
    .s_arp_axis_tlast(s_arp_axis_tlast),
    .s_arp_axis_tuser(s_arp_axis_tuser),
    // ARP packet output
    .m_arp_axis_tdata(m_arp_axis_tdata),
    .m_arp_axis_tkeep(m_arp_axis_tkeep),
    .m_arp_axis_tvalid(m_arp_axis_tvalid),
    .m_arp_axis_tready(m_arp_axis_tready),
    .m_arp_axis_tlast(m_arp_axis_tlast),
    .m_arp_axis_tuser(m_arp_axis_tuser),
    // ARP requests
    .arp_request_valid(arp_request_valid),
    .arp_request_ready(arp_request_ready),
    .arp_request_ip(arp_request_ip),
    .arp_response_valid(arp_response_valid),
    .arp_response_ready(arp_response_ready),
    .arp_response_error(arp_response_error),
    .arp_response_mac(arp_response_mac),
    // Configuration
    .local_mac(local_mac),
    .local_ip(local_ip),
    .gateway_ip(gateway_ip),
    .subnet_mask(subnet_mask),
    .clear_cache(clear_cache)
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

// captured RX packet (28 byte ARP packet)
byte rx_payload_q[$];

// receive one ARP packet from m_arp_axis (assumes downstream always ready)
task automatic recv_packet;
    integer lane;
begin
    rx_payload_q.delete();
    @(negedge clk);
    while (m_arp_axis_tvalid !== 1'b1) @(negedge clk);
    forever begin
        if (m_arp_axis_tvalid === 1'b1) begin
            // capture all byte lanes; on the last beat honor tkeep
            for (lane = 0; lane < KEEP_WIDTH; lane = lane + 1) begin
                if (m_arp_axis_tlast !== 1'b1 || m_arp_axis_tkeep[lane] === 1'b1)
                    rx_payload_q.push_back(m_arp_axis_tdata[lane*8 +: 8]);
            end
            if (m_arp_axis_tlast === 1'b1)
                break;
        end
        @(negedge clk);
    end
    $display("[%0t] TX-wire ARP packet: len=%0d", $time, rx_payload_q.size());
end
endtask

// send one byte array into s_arp_axis (no header, raw ARP packet bytes)
task automatic send_bytes(input byte payload[]);
    integer i, j;
    integer n;
begin
    @(negedge clk);
    for (i = 0; i < payload.size(); i = i + KEEP_WIDTH) begin
        n = (payload.size() - i) > KEEP_WIDTH ? KEEP_WIDTH : (payload.size() - i);
        s_arp_axis_tvalid <= 1'b1;
        s_arp_axis_tdata  <= {DATA_WIDTH{1'b0}};
        for (j = 0; j < KEEP_WIDTH; j = j + 1) begin
            if (j < n)
                s_arp_axis_tdata[j*8 +: 8] <= payload[i + j];
        end
        s_arp_axis_tkeep <= {KEEP_WIDTH{1'b1}} >> (KEEP_WIDTH - n);
        s_arp_axis_tlast <= (i + KEEP_WIDTH >= payload.size());
        while (s_arp_axis_tready !== 1'b1) @(negedge clk);
        @(negedge clk);
    end
    s_arp_axis_tvalid <= 1'b0;
    s_arp_axis_tlast  <= 1'b0;
    s_arp_axis_tkeep  <= {KEEP_WIDTH{1'b1}};
end
endtask

// send an ARP packet (28 bytes)
task automatic send_arp_packet(input [15:0] oper,
                               input [47:0] sha, input [31:0] spa,
                               input [47:0] tha, input [31:0] tpa);
    byte p[];
begin
    p = new[28];
    p[0]  = 8'h00; p[1]  = 8'h01;              // HTYPE = 1 (Ethernet)
    p[2]  = 8'h08; p[3]  = 8'h00;              // PTYPE = 0x0800 (IPv4)
    p[4]  = 8'h06;                             // HLEN = 6
    p[5]  = 8'h04;                             // PLEN = 4
    p[6]  = oper[15:8]; p[7]  = oper[7:0];     // OPER
    p[8]  = sha[47:40]; p[9]  = sha[39:32]; p[10] = sha[31:24];
    p[11] = sha[23:16]; p[12] = sha[15:8];  p[13] = sha[7:0];
    p[14] = spa[31:24]; p[15] = spa[23:16]; p[16] = spa[15:8];  p[17] = spa[7:0];
    p[18] = tha[47:40]; p[19] = tha[39:32]; p[20] = tha[31:24];
    p[21] = tha[23:16]; p[22] = tha[15:8];  p[23] = tha[7:0];
    p[24] = tpa[31:24]; p[25] = tpa[23:16]; p[26] = tpa[15:8];  p[27] = tpa[7:0];
    $display("[%0t] RX-wire ARP packet: oper=0x%04x sha=%s spa=%s tha=%s tpa=%s",
             $time, oper, mac_str(sha), ip_str(spa), mac_str(tha), ip_str(tpa));
    send_bytes(p);
end
endtask

// receive an ARP packet and verify it field by field
task automatic expect_arp_packet(input [15:0] oper,
                                 input [47:0] sha, input [31:0] spa,
                                 input [47:0] tha, input [31:0] tpa);
    reg [15:0] v16;
    reg [31:0] v32;
    reg [47:0] v48;
begin
    recv_packet();
    check(rx_payload_q.size() == 28,                 "ARP packet length = 28");
    v16 = {rx_payload_q[0], rx_payload_q[1]};
    check(v16 == 16'h0001,                           "HTYPE = 1");
    v16 = {rx_payload_q[2], rx_payload_q[3]};
    check(v16 == 16'h0800,                           "PTYPE = 0x0800");
    check(rx_payload_q[4] == 8'h06,                  "HLEN = 6");
    check(rx_payload_q[5] == 8'h04,                  "PLEN = 4");
    v16 = {rx_payload_q[6], rx_payload_q[7]};
    check(v16 == oper, $sformatf("OPER = 0x%04x", oper));
    v48 = {rx_payload_q[8],  rx_payload_q[9],  rx_payload_q[10],
           rx_payload_q[11], rx_payload_q[12], rx_payload_q[13]};
    check(v48 == sha, $sformatf("SHA = %s", mac_str(sha)));
    v32 = {rx_payload_q[14], rx_payload_q[15], rx_payload_q[16], rx_payload_q[17]};
    check(v32 == spa, $sformatf("SPA = %s", ip_str(spa)));
    v48 = {rx_payload_q[18], rx_payload_q[19], rx_payload_q[20],
           rx_payload_q[21], rx_payload_q[22], rx_payload_q[23]};
    check(v48 == tha, $sformatf("THA = %s", mac_str(tha)));
    v32 = {rx_payload_q[24], rx_payload_q[25], rx_payload_q[26], rx_payload_q[27]};
    check(v32 == tpa, $sformatf("TPA = %s", ip_str(tpa)));
end
endtask

// issue one arp_request and wait for the response
task automatic do_arp_request(input [31:0] ip,
                              output logic err, output [47:0] mac);
begin
    @(negedge clk);
    arp_request_valid <= 1'b1;
    arp_request_ip    <= ip;
    while (arp_request_ready !== 1'b1) @(negedge clk);
    @(negedge clk);
    arp_request_valid <= 1'b0;
    while (arp_response_valid !== 1'b1) @(negedge clk);
    err = arp_response_error;
    mac = arp_response_mac;
    $display("[%0t] arp_request(%s) -> err=%0d mac=%s",
             $time, ip_str(ip), err, mac_str(mac));
end
endtask

// ---------------------------------------------------------------------------
// main stimulus
// ---------------------------------------------------------------------------
integer frames_before;
logic  err;
reg [47:0] mac;

initial begin
    $timeformat(-9, 2, " ns", 12);

    // reset (arp_cache also runs its full invalidation sweep after reset)
    rst = 1'b1;
    repeat (20) @(negedge clk);
    rst = 1'b0;
    repeat (20) @(negedge clk);

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST 1: cache miss -> ARP request on wire -> peer reply -> response =====", $time);
    frames_before = tx_packet_count;
    fork
        begin : peer1
            // peer sees broadcast request, verifies it, then replies
            expect_arp_packet(OPER_REQUEST, LOCAL_MAC, LOCAL_IP, 48'h0, REMOTE_IP);
            send_arp_packet(OPER_REPLY, REMOTE_MAC, REMOTE_IP, LOCAL_MAC, LOCAL_IP);
        end
        begin : requester1
            do_arp_request(REMOTE_IP, err, mac);
            check(err == 1'b0, "TEST1: response without error");
            check(mac == REMOTE_MAC, $sformatf("TEST1: MAC = %s", mac_str(REMOTE_MAC)));
        end
    join
    check(tx_packet_count == frames_before + 1, "TEST1: exactly 1 packet went out on the wire");

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST 2: same IP again -> cache hit, no wire traffic =====", $time);
    frames_before = tx_packet_count;
    do_arp_request(REMOTE_IP, err, mac);
    check(err == 1'b0, "TEST2: response without error");
    check(mac == REMOTE_MAC, $sformatf("TEST2: MAC = %s", mac_str(REMOTE_MAC)));
    check(tx_packet_count == frames_before, "TEST2: no new packet on the wire");

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST 3: peer asks for our IP -> DUT auto-replies =====", $time);
    send_arp_packet(OPER_REQUEST, REMOTE_MAC, REMOTE_IP, 48'h0, LOCAL_IP);
    expect_arp_packet(OPER_REPLY, LOCAL_MAC, LOCAL_IP, REMOTE_MAC, REMOTE_IP);

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST 4: clear_cache -> entry evicted -> full exchange again =====", $time);
    @(negedge clk);
    clear_cache <= 1'b1;
    @(negedge clk);
    clear_cache <= 1'b0;
    repeat (2 ** CACHE_ADDR_WIDTH + 10) @(negedge clk);   // wait for sweep to finish
    frames_before = tx_packet_count;
    fork
        begin : peer4
            expect_arp_packet(OPER_REQUEST, LOCAL_MAC, LOCAL_IP, 48'h0, REMOTE_IP);
            send_arp_packet(OPER_REPLY, REMOTE_MAC, REMOTE_IP, LOCAL_MAC, LOCAL_IP);
        end
        begin : requester4
            do_arp_request(REMOTE_IP, err, mac);
            check(err == 1'b0, "TEST4: response without error");
            check(mac == REMOTE_MAC, $sformatf("TEST4: MAC = %s", mac_str(REMOTE_MAC)));
        end
    join
    check(tx_packet_count == frames_before + 1, "TEST4: cache cleared -> new packet on the wire");

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST 5: destination outside subnet -> ARP for gateway =====", $time);
    fork
        begin : peer5
            // request must target the GATEWAY IP, not the outside IP
            expect_arp_packet(OPER_REQUEST, LOCAL_MAC, LOCAL_IP, 48'h0, GATEWAY_IP);
            send_arp_packet(OPER_REPLY, GATEWAY_MAC, GATEWAY_IP, LOCAL_MAC, LOCAL_IP);
        end
        begin : requester5
            do_arp_request(OUTSIDE_IP, err, mac);
            check(err == 1'b0, "TEST5: response without error");
            check(mac == GATEWAY_MAC, $sformatf("TEST5: MAC = gateway %s", mac_str(GATEWAY_MAC)));
        end
    join

    // -----------------------------------------------------------------
    $display("[%0t] ===== TEST 6: nobody answers -> retries -> error response =====", $time);
    fork
        begin : peer6
            // drain: initial request + (REQUEST_RETRY_COUNT-1) retries, never reply
            expect_arp_packet(OPER_REQUEST, LOCAL_MAC, LOCAL_IP, 48'h0, DEAD_IP);
            expect_arp_packet(OPER_REQUEST, LOCAL_MAC, LOCAL_IP, 48'h0, DEAD_IP);
        end
        begin : requester6
            do_arp_request(DEAD_IP, err, mac);
            check(err == 1'b1, "TEST6: response with error after retries exhausted");
        end
    join

    // -----------------------------------------------------------------
    if (fail_count == 0)
        $display("[%0t] ================ ALL %0d CHECKS PASSED ================", $time, pass_count);
    else
        $display("[%0t] ================ %0d/%0d CHECKS FAILED ================", $time, fail_count, pass_count + fail_count);
    $finish;
end

// global watchdog
initial begin
    #20_000_000;   // 20 ms
    $display("FATAL: global timeout");
    $fatal(1);
end

endmodule

`default_nettype wire
