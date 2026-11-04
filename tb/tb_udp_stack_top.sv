`timescale 1ns / 1ps
`default_nettype none

/****************************************************************************
 * @file    tb_udp_stack_top_full.sv
 * @brief   End-to-end testbench for rtl/udp_stack_top.v
 *
 *          Addresses:
 *            FPGA  : IP 192.168.10.13  MAC 00:0a:35:74:51:23  port 8080
 *            peer  : IP 192.168.10.72  MAC 35:46:7e:65:12:65  port 5001
 *
 *          Tests:
 *            1. descriptor config -> FPGA sends ARP request for dst_ip,
 *               peer replies -> configuration_done asserted
 *            2. peer sends an ARP request for the FPGA IP -> FPGA
 *               auto-generates the ARP reply with its MAC
 *            3. FPGA transmits a UDP frame (app_tx -> wire) while the
 *               wire-side (mac_tx_axis_tready) applies backpressure;
 *               the emitted Ethernet/IPv4/UDP frame is checked field by
 *               field including payload integrity
 *            4. peer sends an Ethernet/IPv4/UDP frame to the FPGA
 *               (mac_rx) -> payload appears on app_rx_axis intact
 ***************************************************************************/

module tb_udp_stack_top;

// ---------------------------------------------------------------------------
// addresses / constants
// ---------------------------------------------------------------------------
localparam [47:0] FPGA_MAC  = 48'h00_0a_35_74_51_23;   // 00:0a:35:74:51:23
localparam [31:0] FPGA_IP   = {8'd192, 8'd168, 8'd10, 8'd13};  // 192.168.10.13
localparam [47:0] PEER_MAC  = 48'h35_46_7e_65_12_65;   // 35:46:7e:65:12:65
localparam [31:0] PEER_IP   = {8'd192, 8'd168, 8'd10, 8'd72};  // 192.168.10.72
localparam [15:0] FPGA_PORT = 16'd8080;                 // local UDP port
localparam [15:0] PEER_PORT = 16'd5001;                 // remote UDP port
localparam [31:0] GATEWAY_IP  = {8'd192, 8'd168, 8'd10, 8'd1};
localparam [31:0] SUBNET_MASK = {8'd255, 8'd255, 8'd255, 8'd0};

// small ARP retry timers so the test runs in simulation time
localparam integer REQUEST_RETRY_COUNT    = 2;
localparam integer REQUEST_RETRY_INTERVAL = 200;
localparam integer REQUEST_TIMEOUT        = 600;

localparam [47:0] BCAST_MAC     = 48'hff_ff_ff_ff_ff_ff;
localparam [15:0] ETHERTYPE_ARP = 16'h0806;
localparam [15:0] ETHERTYPE_IP  = 16'h0800;
localparam [15:0] OPER_REQUEST  = 16'h0001;
localparam [15:0] OPER_REPLY    = 16'h0002;

// ---------------------------------------------------------------------------
// clock / reset
// ---------------------------------------------------------------------------
reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;   // 100 MHz

// ---------------------------------------------------------------------------
// scoreboard
// ---------------------------------------------------------------------------
integer pass_count = 0;
integer fail_count = 0;

// ---------------------------------------------------------------------------
// DUT configuration
// ---------------------------------------------------------------------------
reg  desc_axis_tvalid = 1'b0;
wire desc_axis_tready;
wire configuration_done;
reg [31:0] src_ip_addr     = FPGA_IP;
reg [31:0] gateway_ip_addr = GATEWAY_IP;
reg [31:0] subnet_mask     = SUBNET_MASK;
reg [31:0] dst_ip_addr     = PEER_IP;
reg [47:0] src_mac_addr    = FPGA_MAC;
reg [15:0] udp_src_port    = FPGA_PORT;
reg [15:0] udp_dst_port    = PEER_PORT;

// ---------------------------------------------------------------------------
// app TX (UDP payload in)
// ---------------------------------------------------------------------------
reg  [63:0] app_tx_axis_tdata  = 64'd0;
reg  [7:0]  app_tx_axis_tkeep  = 8'hff;
reg         app_tx_axis_tvalid = 1'b0;
reg         app_tx_axis_tlast  = 1'b0;
wire        app_tx_axis_tready;

// ---------------------------------------------------------------------------
// app RX (UDP payload out)
// ---------------------------------------------------------------------------
wire [63:0] app_rx_axis_tdata;
wire [7:0]  app_rx_axis_tkeep;
wire        app_rx_axis_tvalid;
wire        app_rx_axis_tlast;
reg         app_rx_axis_tready = 1'b1;

// ---------------------------------------------------------------------------
// MAC TX (wire out) ??backpressure-capable "PHY"
// ---------------------------------------------------------------------------
wire [63:0] mac_tx_axis_tdata;
wire [7:0]  mac_tx_axis_tkeep;
wire        mac_tx_axis_tvalid;
wire        mac_tx_axis_tlast;
wire        mac_tx_axis_tuser;
reg         mac_tx_axis_tready = 1'b1;

reg         bp_enable = 1'b0;
reg         stress_enable = 1'b0;
reg         stall_enable = 1'b0;
reg  [15:0] lfsr = 16'hACE1;
reg  [9:0]  stress_cycle = 10'd0;
always @(negedge clk) begin
    if (stall_enable) begin
        mac_tx_axis_tready <= 1'b0;   // hard stall: force the FIFOs to fill
    end else if (stress_enable) begin
        // intermittent backpressure: ready high 300 cycles, low 150 cycles
        stress_cycle <= (stress_cycle >= 10'd449) ? 10'd0 : stress_cycle + 10'd1;
        mac_tx_axis_tready <= (stress_cycle < 10'd300);
    end else if (bp_enable) begin
        lfsr = {lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5], lfsr[15:1]};
        mac_tx_axis_tready <= lfsr[0];
    end else begin
        mac_tx_axis_tready <= 1'b1;
    end
end

// ---------------------------------------------------------------------------
// MAC RX (wire in) ??frame injection
// ---------------------------------------------------------------------------
reg  [63:0] mac_rx_axis_tdata  = 64'd0;
reg  [7:0]  mac_rx_axis_tkeep  = 8'hff;
reg         mac_rx_axis_tvalid = 1'b0;
reg         mac_rx_axis_tuser  = 1'b0;
reg         mac_rx_axis_tlast  = 1'b0;
wire        mac_rx_axis_tready;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
udp_stack_top  UUT (
    .clk                (clk),
    .rst                (rst),

    .desc_axis_tvalid   (desc_axis_tvalid),
    .desc_axis_tready   (desc_axis_tready),
    .configuration_done (configuration_done),
    .src_ip_addr        (src_ip_addr),
    .gateway_ip_addr    (gateway_ip_addr),
    .subnet_mask        (subnet_mask),
    .dst_ip_addr        (dst_ip_addr),
    .src_mac_addr       (src_mac_addr),
    .udp_src_port       (udp_src_port),
    .udp_dst_port       (udp_dst_port),

    .app_tx_axis_tdata  (app_tx_axis_tdata),
    .app_tx_axis_tkeep  (app_tx_axis_tkeep),
    .app_tx_axis_tvalid (app_tx_axis_tvalid),
    .app_tx_axis_tlast  (app_tx_axis_tlast),
    .app_tx_axis_tready (app_tx_axis_tready),

    .app_rx_axis_tdata  (app_rx_axis_tdata),
    .app_rx_axis_tkeep  (app_rx_axis_tkeep),
    .app_rx_axis_tvalid (app_rx_axis_tvalid),
    .app_rx_axis_tlast  (app_rx_axis_tlast),
    .app_rx_axis_tready (app_rx_axis_tready),

    .mac_tx_axis_tdata  (mac_tx_axis_tdata),
    .mac_tx_axis_tkeep  (mac_tx_axis_tkeep),
    .mac_tx_axis_tvalid (mac_tx_axis_tvalid),
    .mac_tx_axis_tlast  (mac_tx_axis_tlast),
    .mac_tx_axis_tuser  (mac_tx_axis_tuser),
    .mac_tx_axis_tready (mac_tx_axis_tready),

    .mac_rx_axis_tdata  (mac_rx_axis_tdata),
    .mac_rx_axis_tkeep  (mac_rx_axis_tkeep),
    .mac_rx_axis_tvalid (mac_rx_axis_tvalid),
    .mac_rx_axis_tuser  (mac_rx_axis_tuser),
    .mac_rx_axis_tready (mac_rx_axis_tready),
    .mac_rx_axis_tlast  (mac_rx_axis_tlast)
);

// ---------------------------------------------------------------------------
// captured frames
// ---------------------------------------------------------------------------
byte tx_bytes[$];     // full MAC TX frame
byte tx_payload[$];   // IP packet portion of the TX frame
reg [47:0] tx_dst_mac, tx_src_mac;
reg [15:0] tx_type;

byte rx_app_bytes[$]; // received app payload
integer rx_app_count;

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

// one's-complement add
function automatic [15:0] ocsum(input [15:0] a, input [15:0] b);
    logic [16:0] s;
begin
    s = a + b;
    ocsum = s[15:0] + s[16];
end
endfunction

// IPv4 header checksum over 20 header bytes with the checksum field zeroed
function automatic [15:0] ip_hdr_checksum(input byte h[20]);
    logic [15:0] sum;
    integer i;
begin
    sum = 16'd0;
    for (i = 0; i < 20; i = i + 2) begin
        if (i == 10)
            sum = ocsum(sum, 16'h0000);   // checksum field = 0
        else
            sum = ocsum(sum, {h[i], h[i+1]});
    end
    ip_hdr_checksum = ~sum;
    if (ip_hdr_checksum == 16'd0) ip_hdr_checksum = 16'hFFFF;
end
endfunction

// RFC 768 UDP checksum: pseudo-header + UDP header (cksum=0) + payload
function automatic [15:0] udp_checksum_ref(
    input [31:0] src_ip, input [31:0] dst_ip,
    input [15:0] src_port, input [15:0] dst_port,
    input [15:0] udp_len,
    input byte payload[$], input integer plen);
    logic [15:0] sum;
    integer i;
begin
    sum = 16'd0;
    sum = ocsum(sum, src_ip[31:16]);
    sum = ocsum(sum, src_ip[15:0]);
    sum = ocsum(sum, dst_ip[31:16]);
    sum = ocsum(sum, dst_ip[15:0]);
    sum = ocsum(sum, 16'h0011);
    sum = ocsum(sum, udp_len);
    sum = ocsum(sum, src_port);
    sum = ocsum(sum, dst_port);
    sum = ocsum(sum, udp_len);
    i = 0;
    while (i < plen) begin
        if (i + 1 < plen)
            sum = ocsum(sum, {payload[i], payload[i+1]});
        else
            sum = ocsum(sum, {payload[i], 8'h00});
        i = i + 2;
    end
    udp_checksum_ref = ~sum;
    if (udp_checksum_ref == 16'd0) udp_checksum_ref = 16'hFFFF;
end
endfunction

// capture one complete MAC TX frame, handshake-aware (respects backpressure)
task automatic recv_tx_frame;
    integer lane;
    integer i;
begin
    tx_bytes.delete();
    do @(posedge clk); while (!(mac_tx_axis_tvalid && mac_tx_axis_tready));
    forever begin
        for (lane = 0; lane < 8; lane = lane + 1) begin
            if (mac_tx_axis_tkeep[lane])
                tx_bytes.push_back(mac_tx_axis_tdata[lane*8 +: 8]);
        end
        if (mac_tx_axis_tlast)
            break;
        do @(posedge clk); while (!(mac_tx_axis_tvalid && mac_tx_axis_tready));
    end

    tx_dst_mac = {tx_bytes[0], tx_bytes[1], tx_bytes[2], tx_bytes[3], tx_bytes[4], tx_bytes[5]};
    tx_src_mac = {tx_bytes[6], tx_bytes[7], tx_bytes[8], tx_bytes[9], tx_bytes[10], tx_bytes[11]};
    tx_type    = {tx_bytes[12], tx_bytes[13]};
    tx_payload.delete();
    for (i = 14; i < tx_bytes.size(); i = i + 1)
        tx_payload.push_back(tx_bytes[i]);

    $display("[%0t] TX-wire: dst=%s src=%s type=0x%04x len=%0d",
             $time, mac_str(tx_dst_mac), mac_str(tx_src_mac), tx_type, tx_bytes.size());
end
endtask

// inject one complete frame (byte queue) into mac_rx_axis
task automatic send_rx_frame(input byte b[$]);
    integer i, j;
    integer n;
begin
    @(negedge clk);
    for (i = 0; i < b.size(); i = i + 8) begin
        n = (b.size() - i) > 8 ? 8 : (b.size() - i);
        mac_rx_axis_tdata  <= 64'd0;
        for (j = 0; j < 8; j = j + 1)
            if (j < n)
                mac_rx_axis_tdata[j*8 +: 8] <= b[i + j];
        mac_rx_axis_tkeep  <= 8'hff >> (8 - n);
        mac_rx_axis_tlast  <= (i + 8 >= b.size());
        mac_rx_axis_tvalid <= 1'b1;
        while (mac_rx_axis_tready !== 1'b1) @(negedge clk);
        @(negedge clk);
    end
    mac_rx_axis_tvalid <= 1'b0;
    mac_rx_axis_tlast  <= 1'b0;
    mac_rx_axis_tkeep  <= 8'hff;
end
endtask

// inject an ARP frame (eth header + 28-byte ARP packet)
task automatic send_arp_frame(input [47:0] dst, input [47:0] src,
                              input [15:0] oper,
                              input [47:0] sha, input [31:0] spa,
                              input [47:0] tha, input [31:0] tpa);
    byte f[$];
begin
    f.push_back(dst[47:40]); f.push_back(dst[39:32]); f.push_back(dst[31:24]);
    f.push_back(dst[23:16]); f.push_back(dst[15:8]);  f.push_back(dst[7:0]);
    f.push_back(src[47:40]); f.push_back(src[39:32]); f.push_back(src[31:24]);
    f.push_back(src[23:16]); f.push_back(src[15:8]);  f.push_back(src[7:0]);
    f.push_back(ETHERTYPE_ARP[15:8]); f.push_back(ETHERTYPE_ARP[7:0]);
    f.push_back(8'h00); f.push_back(8'h01);           // HTYPE
    f.push_back(8'h08); f.push_back(8'h00);           // PTYPE
    f.push_back(8'h06);                                // HLEN
    f.push_back(8'h04);                                // PLEN
    f.push_back(oper[15:8]); f.push_back(oper[7:0]);   // OPER
    f.push_back(sha[47:40]); f.push_back(sha[39:32]); f.push_back(sha[31:24]);
    f.push_back(sha[23:16]); f.push_back(sha[15:8]);  f.push_back(sha[7:0]);
    f.push_back(spa[31:24]); f.push_back(spa[23:16]); f.push_back(spa[15:8]);  f.push_back(spa[7:0]);
    f.push_back(tha[47:40]); f.push_back(tha[39:32]); f.push_back(tha[31:24]);
    f.push_back(tha[23:16]); f.push_back(tha[15:8]);  f.push_back(tha[7:0]);
    f.push_back(tpa[31:24]); f.push_back(tpa[23:16]); f.push_back(tpa[15:8]);  f.push_back(tpa[7:0]);
    $display("[%0t] RX-wire: dst=%s src=%s ARP oper=0x%04x spa=%s tpa=%s",
             $time, mac_str(dst), mac_str(src), oper, ip_str(spa), ip_str(tpa));
    send_rx_frame(f);
end
endtask

// expect and verify a complete ARP packet on the wire
task automatic expect_arp_tx(input [15:0] oper,
                             input [47:0] sha, input [31:0] spa,
                             input [47:0] tha, input [31:0] tpa);
    reg [47:0] exp_dst;
    reg [15:0] v16;
    reg [31:0] v32;
    reg [47:0] v48;
begin
    recv_tx_frame();
    exp_dst = (oper == OPER_REQUEST) ? BCAST_MAC : tha;

    check(tx_type == ETHERTYPE_ARP,    "ARP: ethertype = 0x0806");
    check(tx_dst_mac == exp_dst,       $sformatf("ARP: eth dst = %s", mac_str(exp_dst)));
    check(tx_src_mac == FPGA_MAC,      $sformatf("ARP: eth src = %s", mac_str(FPGA_MAC)));
    check(tx_payload.size() == 28,     "ARP: payload length = 28");
    v16 = {tx_payload[0], tx_payload[1]};
    check(v16 == 16'h0001,             "ARP: HTYPE = 1");
    v16 = {tx_payload[2], tx_payload[3]};
    check(v16 == 16'h0800,             "ARP: PTYPE = 0x0800");
    check(tx_payload[4] == 8'h06,      "ARP: HLEN = 6");
    check(tx_payload[5] == 8'h04,      "ARP: PLEN = 4");
    v16 = {tx_payload[6], tx_payload[7]};
    check(v16 == oper,                 $sformatf("ARP: OPER = 0x%04x", oper));
    v48 = {tx_payload[8],  tx_payload[9],  tx_payload[10],
           tx_payload[11], tx_payload[12], tx_payload[13]};
    check(v48 == sha,                  $sformatf("ARP: SHA = %s", mac_str(sha)));
    v32 = {tx_payload[14], tx_payload[15], tx_payload[16], tx_payload[17]};
    check(v32 == spa,                  $sformatf("ARP: SPA = %s", ip_str(spa)));
    v48 = {tx_payload[18], tx_payload[19], tx_payload[20],
           tx_payload[21], tx_payload[22], tx_payload[23]};
    check(v48 == tha,                  $sformatf("ARP: THA = %s", mac_str(tha)));
    v32 = {tx_payload[24], tx_payload[25], tx_payload[26], tx_payload[27]};
    check(v32 == tpa,                  $sformatf("ARP: TPA = %s", ip_str(tpa)));
end
endtask

// present a destination IP through the descriptor interface
task automatic config_and_request(input [31:0] ip);
begin
    @(negedge clk);
    dst_ip_addr     <= ip;
    repeat (2) @(negedge clk);
    desc_axis_tvalid <= 1'b1;
    @(negedge clk);
    while (desc_axis_tready !== 1'b1) @(negedge clk);
    @(negedge clk);
    desc_axis_tvalid <= 1'b0;
end
endtask

task automatic wait_config_done(input integer max_cycles);
    integer cyc;
begin
    cyc = 0;
    @(negedge clk);
    while (configuration_done !== 1'b1 && cyc < max_cycles) begin
        @(negedge clk);
        cyc = cyc + 1;
    end
    check(configuration_done === 1'b1, "configuration_done asserted");
end
endtask

// pack 8 bytes starting at 'start' into a 64-bit word (byte0 -> bits[7:0])
function automatic [63:0] pack8(input byte b[$], input integer start);
    integer j;
    reg [63:0] w;
begin
    w = 64'd0;
    for (j = 0; j < 8; j = j + 1)
        w = w | ({56'd0, b[start + j]} << (8*j));
    pack8 = w;
end
endfunction

// deterministic 64-bit payload word for jumbo stress frames
function automatic [63:0] jumbo_word(input integer i);
    integer b;
    reg [63:0] w;
begin
    w = 64'd0;
    for (b = 0; b < 8; b = b + 1)
        w = w | ({56'd0, (((i*8 + b) * 7 + 3) & 8'hff)} << (8*b));
    jumbo_word = w;
end
endfunction

// expected byte-sum of a payload of 'plen' bytes built with the jumbo pattern
function automatic [31:0] payload_byte_sum(input integer plen);
    integer i;
    reg [31:0] s;
begin
    s = 32'd0;
    for (i = 0; i < plen; i = i + 1)
        s = s + ((i * 7 + 3) & 8'hff);
    payload_byte_sum = s;
end
endfunction

// drive a UDP payload into app_tx_axis
task automatic send_app_frame(input byte payload[$], input integer plen);
    integer i, n, words;
begin
    words = (plen + 7) / 8;
    for (i = 0; i < words; i = i + 1) begin
        @(negedge clk);
        n = (plen - i*8) > 8 ? 8 : (plen - i*8);
        app_tx_axis_tdata <= pack8(payload, i*8);
        app_tx_axis_tkeep <= 8'hff >> (8 - n);
        app_tx_axis_tlast <= (i == words - 1);
        app_tx_axis_tvalid <= 1'b1;
        @(posedge clk);
        while (!(app_tx_axis_tvalid && app_tx_axis_tready)) @(posedge clk);
        app_tx_axis_tvalid <= 1'b0;
    end
end
endtask

// drain one frame from app_rx_axis into rx_app_bytes
task automatic recv_app_frame;
    integer lane;
begin
    rx_app_bytes.delete();
    rx_app_count = 0;
    do @(posedge clk); while (!(app_rx_axis_tvalid && app_rx_axis_tready));
    forever begin
        for (lane = 0; lane < 8; lane = lane + 1) begin
            if (app_rx_axis_tkeep[lane]) begin
                rx_app_bytes.push_back(app_rx_axis_tdata[lane*8 +: 8]);
                rx_app_count = rx_app_count + 1;
            end
        end
        if (app_rx_axis_tlast)
            break;
        do @(posedge clk); while (!(app_rx_axis_tvalid && app_rx_axis_tready));
    end
end
endtask

// build a full Ethernet/IPv4/UDP frame (with correct checksums) for injection
task automatic build_udp_frame(input [47:0] eth_dst, input [47:0] eth_src,
                               input [31:0] ip_src, input [31:0] ip_dst,
                               input [15:0] udp_sp, input [15:0] udp_dp,
                               input byte payload[$], input integer plen,
                               output byte f[$]);
    byte h[20];
    integer i;
    logic [15:0] total_len, udp_len, cksum;
begin
    total_len = 20 + 8 + plen;
    udp_len   = 8 + plen;

    f.delete();
    // Ethernet header
    f.push_back(eth_dst[47:40]); f.push_back(eth_dst[39:32]); f.push_back(eth_dst[31:24]);
    f.push_back(eth_dst[23:16]); f.push_back(eth_dst[15:8]);  f.push_back(eth_dst[7:0]);
    f.push_back(eth_src[47:40]); f.push_back(eth_src[39:32]); f.push_back(eth_src[31:24]);
    f.push_back(eth_src[23:16]); f.push_back(eth_src[15:8]);  f.push_back(eth_src[7:0]);
    f.push_back(ETHERTYPE_IP[15:8]); f.push_back(ETHERTYPE_IP[7:0]);

    // IPv4 header (20 bytes)
    h[0]  = 8'h45;                 // version/IHL
    h[1]  = 8'h00;                 // DSCP/ECN
    h[2]  = total_len[15:8]; h[3] = total_len[7:0];
    h[4]  = 8'h00; h[5] = 8'h00;   // identification
    h[6]  = 8'h40; h[7] = 8'h00;   // flags/fragment
    h[8]  = 8'h40;                 // TTL
    h[9]  = 8'h11;                 // protocol = UDP
    h[10] = 8'h00; h[11] = 8'h00;  // header checksum placeholder
    h[12] = ip_src[31:24]; h[13] = ip_src[23:16]; h[14] = ip_src[15:8]; h[15] = ip_src[7:0];
    h[16] = ip_dst[31:24]; h[17] = ip_dst[23:16]; h[18] = ip_dst[15:8]; h[19] = ip_dst[7:0];

    cksum = ip_hdr_checksum(h);
    h[10] = cksum[15:8]; h[11] = cksum[7:0];
    for (i = 0; i < 20; i = i + 1)
        f.push_back(h[i]);

    // UDP header (checksum placeholder)
    f.push_back(udp_sp[15:8]);  f.push_back(udp_sp[7:0]);
    f.push_back(udp_dp[15:8]);  f.push_back(udp_dp[7:0]);
    f.push_back(udp_len[15:8]); f.push_back(udp_len[7:0]);
    f.push_back(8'h00);         f.push_back(8'h00);   // checksum placeholder

    // payload
    for (i = 0; i < plen; i = i + 1)
        f.push_back(payload[i]);

    // UDP checksum (pseudo-header + UDP header + payload)
    cksum = udp_checksum_ref(ip_src, ip_dst, udp_sp, udp_dp, udp_len, payload, plen);
    f[40] = cksum[15:8]; f[41] = cksum[7:0];
end
endtask

// verify a UDP/IP frame captured on the wire (TX direction)
task automatic expect_udp_tx(input byte payload[$], input integer plen);
    byte h[20];
    integer i;
    logic [15:0] v16;
    logic [15:0] total_len, udp_len, csum;
begin
    recv_tx_frame();

    total_len = 20 + 8 + plen;
    udp_len   = 8 + plen;

    check(tx_type == ETHERTYPE_IP,               "UDP: ethertype = 0x0800");
    check(tx_dst_mac == PEER_MAC,                $sformatf("UDP: eth dst = %s", mac_str(PEER_MAC)));
    check(tx_src_mac == FPGA_MAC,                $sformatf("UDP: eth src = %s", mac_str(FPGA_MAC)));
    check(tx_payload.size() == 20 + 8 + plen,    "UDP: frame length");

    // IPv4 header
    check(tx_payload[0] == 8'h45,                "IP: version/IHL = 0x45");
    v16 = {tx_payload[2], tx_payload[3]};
    check(v16 == total_len,                      $sformatf("IP: total length = %0d", total_len));
    check(tx_payload[9] == 8'h11,                "IP: protocol = 0x11 (UDP)");
    v16 = {tx_payload[12], tx_payload[13]};
    check(v16 == FPGA_IP[31:16],                 $sformatf("IP: src = %s", ip_str(FPGA_IP)));
    v16 = {tx_payload[14], tx_payload[15]};
    check(v16 == FPGA_IP[15:0],                  "IP: src (low half)");
    v16 = {tx_payload[16], tx_payload[17]};
    check(v16 == PEER_IP[31:16],                 $sformatf("IP: dst = %s", ip_str(PEER_IP)));
    v16 = {tx_payload[18], tx_payload[19]};
    check(v16 == PEER_IP[15:0],                  "IP: dst (low half)");

    // IPv4 header checksum self-consistency
    for (i = 0; i < 20; i = i + 1) h[i] = tx_payload[i];
    csum = ip_hdr_checksum(h);
    v16 = {tx_payload[10], tx_payload[11]};
    check(v16 == csum,                            $sformatf("IP: header checksum = 0x%04x", csum));

    // UDP header (offset 20 within the IP packet)
    v16 = {tx_payload[20], tx_payload[21]};
    check(v16 == FPGA_PORT,                      $sformatf("UDP: src port = %0d", FPGA_PORT));
    v16 = {tx_payload[22], tx_payload[23]};
    check(v16 == PEER_PORT,                      $sformatf("UDP: dst port = %0d", PEER_PORT));
    v16 = {tx_payload[24], tx_payload[25]};
    check(v16 == udp_len,                        $sformatf("UDP: length = %0d", udp_len));

    // UDP checksum self-consistency (pseudo-header + UDP header + payload)
    csum = 16'd0;
    csum = ocsum(csum, FPGA_IP[31:16]);
    csum = ocsum(csum, FPGA_IP[15:0]);
    csum = ocsum(csum, PEER_IP[31:16]);
    csum = ocsum(csum, PEER_IP[15:0]);
    csum = ocsum(csum, 16'h0011);
    csum = ocsum(csum, udp_len);
    for (i = 0; i < 8; i = i + 2)
        csum = ocsum(csum, {tx_payload[20+i], tx_payload[20+i+1]});
    for (i = 0; i < plen; i = i + 2) begin
        if (i + 1 < plen)
            csum = ocsum(csum, {tx_payload[28+i], tx_payload[28+i+1]});
        else
            csum = ocsum(csum, {tx_payload[28+i], 8'h00});
    end
    check(csum == 16'hFFFF,                       "UDP: checksum self-consistent (sum = 0xffff)");

    // payload
    for (i = 0; i < plen; i = i + 1) begin
        if (tx_payload[28+i] !== payload[i]) begin
            $display("   FAIL: UDP payload byte %0d = %h, expected %h", i, tx_payload[28+i], payload[i]);
            fail_count = fail_count + 1;
        end
    end
    $display("[%0t]   UDP payload verified (%0d bytes)", $time, plen);
end
endtask

// drive nframes x plen-byte payloads at FULL RATE (tvalid held high between
// beats and between frames, only advancing on tready)
task automatic send_app_fullrate(input integer nframes, input integer plen);
    integer f, i, words;
begin
    words = (plen + 7) / 8;
    @(negedge clk);
    for (f = 0; f < nframes; f = f + 1) begin
        for (i = 0; i < words; i = i + 1) begin
            app_tx_axis_tdata  <= jumbo_word(i);
            app_tx_axis_tkeep  <= 8'hff;
            app_tx_axis_tlast  <= (i == words - 1);
            app_tx_axis_tvalid <= 1'b1;
            @(posedge clk);
            while (!(app_tx_axis_tvalid && app_tx_axis_tready)) @(posedge clk);
        end
    end
    app_tx_axis_tvalid <= 1'b0;
end
endtask

// capture one emitted jumbo frame and verify it end-to-end
task automatic expect_jumbo_tx(input integer plen, input integer frame_idx);
    integer i;
    logic [31:0] sum;
    logic [15:0] v16;
begin
    recv_tx_frame();

    check(tx_type == ETHERTYPE_IP,           $sformatf("jumbo[%0d]: ethertype = 0x0800", frame_idx));
    check(tx_payload.size() == 20 + 8 + plen, $sformatf("jumbo[%0d]: frame length = %0d", frame_idx, 20 + 8 + plen));
    v16 = {tx_payload[2], tx_payload[3]};
    check(v16 == 20 + 8 + plen,              $sformatf("jumbo[%0d]: IP total length = %0d", frame_idx, 20 + 8 + plen));
    v16 = {tx_payload[24], tx_payload[25]};
    check(v16 == 8 + plen,                   $sformatf("jumbo[%0d]: UDP length = %0d", frame_idx, 8 + plen));

    // payload byte-sum (cheap corruption detector over the whole 9000 bytes)
    sum = 32'd0;
    for (i = 0; i < plen; i = i + 1)
        sum = sum + tx_payload[28 + i];
    check(sum == payload_byte_sum(plen),     $sformatf("jumbo[%0d]: payload byte-sum = 0x%08x", frame_idx, sum));
end
endtask

// ---------------------------------------------------------------------------
// stimulus payloads
// ---------------------------------------------------------------------------
byte hello_payload[$];
byte rx_payload[$];

task automatic load_hello;
begin
    hello_payload.delete();
    hello_payload.push_back(8'h68); hello_payload.push_back(8'h65);
    hello_payload.push_back(8'h6c); hello_payload.push_back(8'h6c);
    hello_payload.push_back(8'h6f); hello_payload.push_back(8'h2c);
    hello_payload.push_back(8'h20); hello_payload.push_back(8'h77);
    hello_payload.push_back(8'h6f); hello_payload.push_back(8'h72);
    hello_payload.push_back(8'h6c); hello_payload.push_back(8'h64);
end
endtask

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
initial begin
    repeat (6) @(posedge clk);
    rst <= 1'b0;
    repeat (2) @(posedge clk);

    // ============ test 1: config + ARP resolution ============
    $display("[%0t] ===== test 1: descriptor config -> ARP request -> configuration_done =====", $time);
    config_and_request(PEER_IP);
    expect_arp_tx(OPER_REQUEST, FPGA_MAC, FPGA_IP, 48'h0, PEER_IP);
    check(configuration_done !== 1'b1, "configuration_done low before ARP reply");
    send_arp_frame(FPGA_MAC, PEER_MAC, OPER_REPLY,
                   PEER_MAC, PEER_IP, FPGA_MAC, FPGA_IP);
    wait_config_done(2000);

    // ============ test 2: peer ARP request -> FPGA auto-reply ============
    $display("[%0t] ===== test 2: incoming ARP request -> FPGA reply =====", $time);
    send_arp_frame(BCAST_MAC, PEER_MAC, OPER_REQUEST,
                   PEER_MAC, PEER_IP, 48'h0, FPGA_IP);
    expect_arp_tx(OPER_REPLY, FPGA_MAC, FPGA_IP, PEER_MAC, PEER_IP);

    // ============ test 3: FPGA transmits UDP with wire backpressure ============
    $display("[%0t] ===== test 3: FPGA UDP TX with backpressure =====", $time);
    load_hello();
    bp_enable = 1'b1;
    send_app_frame(hello_payload, 12);
    expect_udp_tx(hello_payload, 12);
    bp_enable = 1'b0;

    // ============ test 4: peer sends UDP frame -> app_rx ============
    $display("[%0t] ===== test 4: peer UDP frame -> app_rx =====", $time);
    rx_payload.delete();
    begin
        integer rx_i;
        for (rx_i = 0; rx_i < 20; rx_i = rx_i + 1)
            rx_payload.push_back((rx_i * 7 + 3) & 8'hff);
    end
    begin
        byte f[$];
        build_udp_frame(FPGA_MAC, PEER_MAC, PEER_IP, FPGA_IP,
                        PEER_PORT, FPGA_PORT, rx_payload, 20, f);
        $display("[%0t] RX-wire: injecting IPv4/UDP frame (20-byte payload)", $time);
        send_rx_frame(f);
    end
    recv_app_frame();
    check(rx_app_count == 20, $sformatf("app_rx: %0d payload bytes", rx_app_count));
    begin
        integer rx_i;
        integer ok = 1;
        for (rx_i = 0; rx_i < 20; rx_i = rx_i + 1) begin
            if (rx_app_bytes[rx_i] !== rx_payload[rx_i]) begin
                $display("   FAIL: app_rx byte %0d = %h, expected %h", rx_i, rx_app_bytes[rx_i], rx_payload[rx_i]);
                ok = 0;
            end
        end
        check(ok == 1, "app_rx: payload matches injected frame");
    end

    // ============ test 4b: frames not addressed to us are dropped ============
    $display("[%0t] ===== test 4b: dst-IP / dst-port filtering =====", $time);
    begin
        byte f[$];
        integer quiet;

        // wrong destination IP: dropped at the IP layer
        build_udp_frame(FPGA_MAC, PEER_MAC, PEER_IP, PEER_IP,
                        PEER_PORT, FPGA_PORT, rx_payload, 20, f);
        send_rx_frame(f);
        quiet = 1;
        for (int c = 0; c < 100; c = c + 1) begin
            @(posedge clk);
            if (app_rx_axis_tvalid) quiet = 0;
        end
        check(quiet == 1, "filter: wrong dst IP produced no app_rx data");

        // correct IP, wrong destination port: dropped at the UDP layer
        build_udp_frame(FPGA_MAC, PEER_MAC, PEER_IP, FPGA_IP,
                        PEER_PORT, 16'd9999, rx_payload, 20, f);
        send_rx_frame(f);
        quiet = 1;
        for (int c = 0; c < 100; c = c + 1) begin
            @(posedge clk);
            if (app_rx_axis_tvalid) quiet = 0;
        end
        check(quiet == 1, "filter: wrong dst port produced no app_rx data");

        // matching frame after the drops: still received
        build_udp_frame(FPGA_MAC, PEER_MAC, PEER_IP, FPGA_IP,
                        PEER_PORT, FPGA_PORT, rx_payload, 20, f);
        send_rx_frame(f);
        recv_app_frame();
        check(rx_app_count == 20, $sformatf("filter: matching frame delivered after drops (%0d bytes)", rx_app_count));
    end

    // ============ test 5: 9000-byte full-rate TX with intermittent backpressure ============
    $display("[%0t] ===== test 5: 9000-byte jumbo frames, full-rate app_tx, intermittent mac_tx backpressure =====", $time);
    begin
        integer nframes = 100;
        stress_enable = 1'b1;
        fork
            begin
                send_app_fullrate(nframes, 9000);
            end
            begin
                integer fi;
                for (fi = 0; fi < nframes; fi = fi + 1)
                    expect_jumbo_tx(9000, fi);
            end
        join
        stress_enable = 1'b0;
        check(1'b1, $sformatf("test 5: %0d x 9000-byte frames drained without deadlock", nframes));
    end

    // ============ test 6: hard stall until the FIFOs actually fill ============
    $display("[%0t] ===== test 6: hard mac_tx stall -> FIFO almost-full -> app backpressure =====", $time);
    begin
        stall_enable = 1'b1;
        fork
            begin : s6_send
                send_app_fullrate(8, 9000);
            end
            begin : s6_mon
                integer c = 0;
                integer fi;
                @(negedge clk);
                while (app_tx_axis_tready !== 1'b0 && c < 200000) begin
                    @(negedge clk);
                    c = c + 1;
                end
                check(app_tx_axis_tready === 1'b0,
                      $sformatf("test 6: app_tx backpressured at cycle %0d (FIFO almost full)", c));
                stall_enable = 1'b0;
                for (fi = 0; fi < 8; fi = fi + 1)
                    expect_jumbo_tx(9000, fi);
                check(1'b1, "test 6: all frames drained after long stall");
            end
        join
    end

    // ============ summary ============
    $display("[%0t] ============ SUMMARY ============", $time);
    $display("[%0t]   pass = %0d, fail = %0d", $time, pass_count, fail_count);
    if (fail_count == 0)
        $display("[%0t] === ALL TESTS PASSED ===", $time);
    else
        $display("[%0t] === FAILED ===", $time);
    $finish;
end

initial begin
    #200000000;
    $display("[%0t] GLOBAL TIMEOUT (hung)", $time);
    $finish;
end

endmodule
`resetall

