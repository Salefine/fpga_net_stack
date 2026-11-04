`timescale 1ns / 1ps
`default_nettype none

/****************************************************************************
 * @file    tb_tcp_echo.sv
 * @brief   Echo-loopback testbench for rtl/tcp_stack_top.v
 *
 *          app_rx_axis -> xpm_fifo_axis -> app_tx_axis (echo loopback),
 *          the same topology as the fpga.sv loopback test.
 *
 *          Covers:
 *            PHASE0  ARP resolution -> configuration_done
 *            PHASE1  TCP 3-way handshake
 *            PHASE2  small payload echo (4 bytes) -- must come back intact
 *            PHASE3  large payload echo (1500 bytes) -- must come back intact
 *            PHASE4  multiple large segments -- server must not spam/repeat
 * ***************************************************************************/

module tb_tcp_echo;

localparam [47:0] FPGA_MAC  = 48'h00_0a_35_74_51_23;
localparam [31:0] FPGA_IP   = {8'd192, 8'd168, 8'd10, 8'd13};
localparam [47:0] PEER_MAC  = 48'h35_46_7e_65_12_65;
localparam [31:0] PEER_IP   = {8'd192, 8'd168, 8'd10, 8'd72};
localparam [15:0] FPGA_PORT = 16'd80;
localparam [15:0] PEER_PORT = 16'd12345;
localparam [31:0] GATEWAY_IP  = {8'd192, 8'd168, 8'd10, 8'd1};
localparam [31:0] SUBNET_MASK = {8'd255, 8'd255, 8'd255, 8'd0};

localparam [31:0] CLIENT_ISN = 32'h0000_1000;
localparam [31:0] SERVER_ISN = 32'h0000_5000;

localparam [15:0] ETHERTYPE_ARP = 16'h0806;
localparam [15:0] ETHERTYPE_IP  = 16'h0800;
localparam [7:0]  IP_PROTO_TCP  = 8'h06;

localparam [7:0] FLAG_SYN      = 8'h02;
localparam [7:0] FLAG_ACK      = 8'h10;
localparam [7:0] FLAG_SYN_ACK  = 8'h12;
localparam [7:0] FLAG_PSH_ACK  = 8'h18;

localparam integer MIN_ETH_FRAME = 60;
localparam integer PAD_BYTE      = 8'h5A;

localparam RCV_TIMEOUT_CYC = 40000;
localparam integer RETX_TIMEOUT_CYC = 1000;
localparam integer RETX_RETRY_CNT   = 2;

reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;

integer pass_count = 0;
integer fail_count = 0;

// DUT signals
reg  desc_axis_tvalid = 1'b0;
wire desc_axis_tready;
wire configuration_done;
reg [31:0] src_ip_addr     = FPGA_IP;
reg [31:0] gateway_ip_addr = GATEWAY_IP;
reg [31:0] subnet_mask     = SUBNET_MASK;
reg [31:0] dst_ip_addr     = PEER_IP;
reg [47:0] src_mac_addr    = FPGA_MAC;
reg [15:0] tcp_src_port    = FPGA_PORT;
reg [15:0] tcp_dst_port    = PEER_PORT;
wire       tcp_linkup;

// app loopback
wire [63:0] app_rx_axis_tdata;
wire [7:0]  app_rx_axis_tkeep;
wire        app_rx_axis_tvalid;
wire        app_rx_axis_tlast;
wire        app_rx_axis_tuser;
wire        app_rx_axis_tready;

wire [63:0] app_tx_axis_tdata;
wire [7:0]  app_tx_axis_tkeep;
wire        app_tx_axis_tvalid;
wire        app_tx_axis_tlast;
wire        app_tx_axis_tready;

wire [63:0] mac_tx_axis_tdata;
wire [7:0]  mac_tx_axis_tkeep;
wire        mac_tx_axis_tvalid;
wire        mac_tx_axis_tlast;
wire        mac_tx_axis_tuser;
reg         mac_tx_axis_tready = 1'b1;

reg  [63:0] mac_rx_axis_tdata  = 64'd0;
reg  [7:0]  mac_rx_axis_tkeep  = 8'hff;
reg         mac_rx_axis_tvalid = 1'b0;
reg         mac_rx_axis_tuser  = 1'b0;
reg         mac_rx_axis_tlast  = 1'b0;
wire        mac_rx_axis_tready;

tcp_stack_top #(
    .RETRANSMIT_RETRY_COUNT (RETX_RETRY_CNT  ),
    .RETRANSMIT_TIMEOUT     (RETX_TIMEOUT_CYC)
) UUT (
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
    .tcp_src_port       (tcp_src_port),
    .tcp_dst_port       (tcp_dst_port),
    .tcp_linkup         (tcp_linkup),

    .app_tx_axis_tdata  (app_tx_axis_tdata),
    .app_tx_axis_tkeep  (app_tx_axis_tkeep),
    .app_tx_axis_tvalid (app_tx_axis_tvalid),
    .app_tx_axis_tlast  (app_tx_axis_tlast),
    .app_tx_axis_tready (app_tx_axis_tready),

    .app_rx_axis_tdata  (app_rx_axis_tdata),
    .app_rx_axis_tkeep  (app_rx_axis_tkeep),
    .app_rx_axis_tvalid (app_rx_axis_tvalid),
    .app_rx_axis_tlast  (app_rx_axis_tlast),
    .app_rx_axis_tuser  (app_rx_axis_tuser),
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

// echo loopback FIFO (same as fpga.sv axis_data_fifo_0, but wired correctly)
xpm_fifo_axis #(
    .TDATA_WIDTH       (64),
    .TUSER_WIDTH       (1),
    .FIFO_MEMORY_TYPE  ("auto"),
    .FIFO_DEPTH        (512),
    .PACKET_FIFO       ("false")
) echo_fifo (
    .s_aclk        (clk),
    .s_aresetn     (~rst),
    .s_axis_tvalid (app_rx_axis_tvalid),
    .s_axis_tready (app_rx_axis_tready),
    .s_axis_tdata  (app_rx_axis_tdata),
    .s_axis_tkeep  (app_rx_axis_tkeep),
    .s_axis_tlast  (app_rx_axis_tlast),
    .s_axis_tuser  (app_rx_axis_tuser),

    .m_aclk        (clk),
    .m_axis_tvalid (app_tx_axis_tvalid),
    .m_axis_tready (app_tx_axis_tready),
    .m_axis_tdata  (app_tx_axis_tdata),
    .m_axis_tkeep  (app_tx_axis_tkeep),
    .m_axis_tlast  (app_tx_axis_tlast),
    .m_axis_tuser  ()
);

// captured TX frame state
byte tx_bytes[$];
byte tx_ip[$];
byte tx_tcp[$];
reg [47:0] tx_dst_mac, tx_src_mac;
reg [15:0] tx_type;
reg [7:0]  tx_ip_proto;
reg [15:0] tx_ip_total_len;
reg [31:0] tx_ip_src, tx_ip_dst;
reg [7:0]  tx_tcp_off;
reg [7:0]  tx_tcp_flags;
reg [31:0] tx_tcp_seq, tx_tcp_ack;
byte        tx_tcp_payload[$];

task automatic check(input logic cond, input string msg);
    if (cond) pass_count = pass_count + 1;
    else begin
        fail_count = fail_count + 1;
        $display("[%0t]   FAIL: %0s", $time, msg);
    end
endtask

function automatic string mac_str(input [47:0] m);
    return $sformatf("%02x:%02x:%02x:%02x:%02x:%02x",
                     m[47:40], m[39:32], m[31:24], m[23:16], m[15:8], m[7:0]);
endfunction

function automatic string ip_str(input [31:0] ip);
    return $sformatf("%0d.%0d.%0d.%0d", ip[31:24], ip[23:16], ip[15:8], ip[7:0]);
endfunction

function automatic [15:0] ocsum(input [15:0] a, input [15:0] b);
    logic [16:0] s;
begin
    s = a + b;
    ocsum = s[15:0] + s[16];
end
endfunction

function automatic [15:0] bytes_sum(input byte b[$], input integer n);
    logic [15:0] sum;
begin
    sum = 16'd0;
    for (integer i = 0; i < n; i = i + 2)
        if (i + 1 < n) sum = ocsum(sum, {b[i], b[i+1]});
        else           sum = ocsum(sum, {b[i], 8'h00});
    bytes_sum = sum;
end
endfunction

function automatic [15:0] tcp_checksum(input [7:0]  flags,
                                       input [31:0] seqn,
                                       input [31:0] ackn,
                                       input byte   payload[$]);
    logic [15:0] sum;
begin
    sum = 16'd0;
    sum = ocsum(sum, PEER_IP[31:16]);  sum = ocsum(sum, PEER_IP[15:0]);
    sum = ocsum(sum, FPGA_IP[31:16]);  sum = ocsum(sum, FPGA_IP[15:0]);
    sum = ocsum(sum, 16'h0006);
    sum = ocsum(sum, 16'(20 + payload.size()));
    sum = ocsum(sum, PEER_PORT);
    sum = ocsum(sum, FPGA_PORT);
    sum = ocsum(sum, seqn[31:16]); sum = ocsum(sum, seqn[15:0]);
    sum = ocsum(sum, ackn[31:16]); sum = ocsum(sum, ackn[15:0]);
    sum = ocsum(sum, {8'h50, flags});
    sum = ocsum(sum, 16'hFFFF);
    sum = ocsum(sum, 16'h0000);
    sum = ocsum(sum, 16'h0000);
    for (integer i = 0; i < payload.size(); i = i + 2)
        sum = ocsum(sum, (i + 1 < payload.size()) ? {payload[i], payload[i+1]}
                                                 : {payload[i], 8'h00});
    tcp_checksum = ~sum;
    if (tcp_checksum == 16'd0) tcp_checksum = 16'hFFFF;
end
endfunction

task automatic send_rx_frame(input byte f[$]);
    integer i, j, n;
begin
    @(negedge clk);
    for (i = 0; i < f.size(); i = i + 8) begin
        n = (f.size() - i) > 8 ? 8 : (f.size() - i);
        mac_rx_axis_tdata  = 64'd0;
        for (j = 0; j < 8; j = j + 1)
            if (j < n) mac_rx_axis_tdata[j*8 +: 8] = f[i + j];
        mac_rx_axis_tkeep  = 8'hff >> (8 - n);
        mac_rx_axis_tlast  = (i + 8 >= f.size());
        mac_rx_axis_tvalid = 1'b1;
        do @(posedge clk); while (mac_rx_axis_tready !== 1'b1);
        @(negedge clk);
    end
    mac_rx_axis_tvalid = 1'b0;
    mac_rx_axis_tlast  = 1'b0;
    mac_rx_axis_tkeep  = 8'hff;
    @(negedge clk);
end
endtask

task automatic send_arp_frame(input [47:0] dst, input [47:0] src,
                              input [15:0] oper,
                              input [47:0] sha, input [31:0] spa,
                              input [47:0] tha, input [31:0] tpa);
    byte f[$];
begin
    f.delete();
    for (integer i = 0; i < 6; i = i + 1) f.push_back(dst[47 - 8*i -: 8]);
    for (integer i = 0; i < 6; i = i + 1) f.push_back(src[47 - 8*i -: 8]);
    f.push_back(ETHERTYPE_ARP[15:8]); f.push_back(ETHERTYPE_ARP[7:0]);
    f.push_back(8'h00); f.push_back(8'h01);
    f.push_back(8'h08); f.push_back(8'h00);
    f.push_back(8'h06);
    f.push_back(8'h04);
    f.push_back(oper[15:8]); f.push_back(oper[7:0]);
    for (integer i = 0; i < 6; i = i + 1) f.push_back(sha[47 - 8*i -: 8]);
    for (integer i = 0; i < 4; i = i + 1) f.push_back(spa[31 - 8*i -: 8]);
    for (integer i = 0; i < 6; i = i + 1) f.push_back(tha[47 - 8*i -: 8]);
    for (integer i = 0; i < 4; i = i + 1) f.push_back(tpa[31 - 8*i -: 8]);
    send_rx_frame(f);
end
endtask

task automatic send_tcp_frame(input [7:0]  flags,
                              input [31:0] seqn, input [31:0] ackn,
                              input byte   payload[$]);
    byte f[$];
    logic [15:0] ip_ck, tcp_ck;
    integer ip_total, tcp_len, pad_idx;
begin
    f.delete();
    tcp_len   = 20 + payload.size();
    ip_total  = 20 + tcp_len;
    for (integer i = 0; i < 6; i = i + 1) f.push_back(FPGA_MAC[47 - 8*i -: 8]);
    for (integer i = 0; i < 6; i = i + 1) f.push_back(PEER_MAC[47 - 8*i -: 8]);
    f.push_back(ETHERTYPE_IP[15:8]); f.push_back(ETHERTYPE_IP[7:0]);
    f.push_back(8'h45); f.push_back(8'h00);
    f.push_back(ip_total[15:8]); f.push_back(ip_total[7:0]);
    f.push_back(8'h12); f.push_back(8'h34);
    f.push_back(8'h40); f.push_back(8'h00);
    f.push_back(8'h40); f.push_back(IP_PROTO_TCP);
    f.push_back(8'h00); f.push_back(8'h00);
    for (integer i = 0; i < 4; i = i + 1) f.push_back(PEER_IP[31 - 8*i -: 8]);
    for (integer i = 0; i < 4; i = i + 1) f.push_back(FPGA_IP[31 - 8*i -: 8]);
    ip_ck = ~(bytes_sum_offset(f, 14, 20));
    f[24] = ip_ck[15:8]; f[25] = ip_ck[7:0];
    tcp_ck = tcp_checksum(flags, seqn, ackn, payload);
    f.push_back(PEER_PORT[15:8]); f.push_back(PEER_PORT[7:0]);
    f.push_back(FPGA_PORT[15:8]); f.push_back(FPGA_PORT[7:0]);
    f.push_back(seqn[31:24]); f.push_back(seqn[23:16]); f.push_back(seqn[15:8]);  f.push_back(seqn[7:0]);
    f.push_back(ackn[31:24]); f.push_back(ackn[23:16]); f.push_back(ackn[15:8]);  f.push_back(ackn[7:0]);
    f.push_back(8'h50);
    f.push_back(flags);
    f.push_back(8'hFF); f.push_back(8'hFF);
    f.push_back(tcp_ck[15:8]); f.push_back(tcp_ck[7:0]);
    f.push_back(8'h00); f.push_back(8'h00);
    for (integer i = 0; i < payload.size(); i = i + 1) f.push_back(payload[i]);
    pad_idx = 0;
    while (f.size() < MIN_ETH_FRAME) begin
        f.push_back(PAD_BYTE + pad_idx);
        pad_idx = pad_idx + 1;
    end
    $display("[%0t] RX-wire: TCP flags=0x%02x seq=0x%08x ack=0x%08x plen=%0d",
             $time, flags, seqn, ackn, payload.size());
    send_rx_frame(f);
end
endtask

function automatic [15:0] bytes_sum_offset(input byte b[$], input integer start, input integer n);
    logic [15:0] sum;
begin
    sum = 16'd0;
    for (integer i = 0; i < n; i = i + 2)
        if (i + 1 < n) sum = ocsum(sum, {b[start+i], b[start+i+1]});
        else           sum = ocsum(sum, {b[start+i], 8'h00});
    bytes_sum_offset = sum;
end
endfunction

task automatic recv_tx_frame(output bit timed_out);
    integer lane, guard;
begin
    tx_bytes.delete();
    tx_ip.delete();
    tx_tcp.delete();
    tx_tcp_payload.delete();
    timed_out = 1'b0;
    guard = 0;
    mac_tx_axis_tready = 1'b1;
    do begin
        @(posedge clk);
        guard = guard + 1;
        if (guard >= RCV_TIMEOUT_CYC) begin
            timed_out = 1'b1;
            return;
        end
    end while (!(mac_tx_axis_tvalid && mac_tx_axis_tready));
    forever begin
        for (lane = 0; lane < 8; lane = lane + 1)
            if (mac_tx_axis_tkeep[lane])
                tx_bytes.push_back(mac_tx_axis_tdata[lane*8 +: 8]);
        if (mac_tx_axis_tlast) break;
        guard = 0;
        do begin
            @(posedge clk);
            guard = guard + 1;
            if (guard >= RCV_TIMEOUT_CYC) begin
                timed_out = 1'b1;
                return;
            end
        end while (!(mac_tx_axis_tvalid && mac_tx_axis_tready));
    end
    @(negedge clk);
    tx_dst_mac = 48'd0;
    tx_src_mac = 48'd0;
    tx_type    = 16'd0;
    tx_tcp_off      = 8'd0;
    tx_tcp_flags    = 8'd0;
    tx_tcp_seq      = 32'd0;
    tx_tcp_ack      = 32'd0;
    if (tx_bytes.size() >= 14) begin
        tx_dst_mac = {tx_bytes[0], tx_bytes[1], tx_bytes[2], tx_bytes[3], tx_bytes[4], tx_bytes[5]};
        tx_src_mac = {tx_bytes[6], tx_bytes[7], tx_bytes[8], tx_bytes[9], tx_bytes[10], tx_bytes[11]};
        tx_type    = {tx_bytes[12], tx_bytes[13]};
        for (integer i = 14; i < tx_bytes.size(); i = i + 1)
            tx_ip.push_back(tx_bytes[i]);
        if (tx_type == ETHERTYPE_IP && tx_ip.size() >= 40) begin
            tx_ip_total_len = {tx_ip[2], tx_ip[3]};
            tx_ip_proto     = tx_ip[9];
            tx_ip_src       = {tx_ip[12], tx_ip[13], tx_ip[14], tx_ip[15]};
            tx_ip_dst       = {tx_ip[16], tx_ip[17], tx_ip[18], tx_ip[19]};
            tx_tcp_off      = {2'b00, tx_ip[32][7:4], 2'b00};
            for (integer i = 20; i < tx_ip.size(); i = i + 1)
                tx_tcp.push_back(tx_ip[i]);
            tx_tcp_seq   = {tx_tcp[4], tx_tcp[5], tx_tcp[6], tx_tcp[7]};
            tx_tcp_ack   = {tx_tcp[8], tx_tcp[9], tx_tcp[10], tx_tcp[11]};
            tx_tcp_flags = tx_tcp[13];
            for (integer i = tx_tcp_off; i < tx_tcp.size(); i = i + 1)
                tx_tcp_payload.push_back(tx_tcp[i]);
        end
    end
    $display("[%0t] TX-wire: dst=%s type=0x%04x len=%0d flags=0x%02x seq=0x%08x ack=0x%08x plen=%0d",
             $time, mac_str(tx_dst_mac), tx_type, tx_bytes.size(),
             tx_tcp_flags, tx_tcp_seq, tx_tcp_ack, tx_tcp_payload.size());
end
endtask

task automatic wait_config_done(output bit timed_out);
    integer g;
begin
    timed_out = 1'b0;
    g = 0;
    while (configuration_done !== 1'b1 && g < RCV_TIMEOUT_CYC) begin
        @(negedge clk);
        g = g + 1;
    end
    timed_out = (g >= RCV_TIMEOUT_CYC);
end
endtask

task automatic wait_linkup(output bit timed_out);
    integer guard;
begin
    timed_out = 1'b0;
    guard = 0;
    while (tcp_linkup !== 1'b1) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard >= RCV_TIMEOUT_CYC) begin
            timed_out = 1'b1;
            return;
        end
    end
end
endtask

// ---------------------------------------------------------------------------
reg [31:0] cli_seq;

task automatic init_conn(output bit ok);
    bit to;
    byte pl0[$];
begin
    ok = 1'b0;

    // PHASE0: ARP
    @(negedge clk);
    desc_axis_tvalid = 1'b1;
    @(negedge clk);
    while (desc_axis_tready !== 1'b1) @(negedge clk);
    @(negedge clk);
    desc_axis_tvalid = 1'b0;

    // FPGA sends ARP request
    recv_tx_frame(to);
    if (to) return;
    send_arp_frame(FPGA_MAC, PEER_MAC, 16'h0002,
                   PEER_MAC, PEER_IP, FPGA_MAC, FPGA_IP);
    wait_config_done(to);
    if (to) return;

    // PHASE1: handshake
    cli_seq = CLIENT_ISN + 32'd1;
    send_tcp_frame(FLAG_SYN, CLIENT_ISN, 32'h0, pl0);
    recv_tx_frame(to);          // SYN+ACK
    if (to) return;
    send_tcp_frame(FLAG_ACK, CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, pl0);
    wait_linkup(to);
    if (to) return;
    ok = 1'b1;
end
endtask

// send a data segment, then consume frames until the echo (PSH|ACK) arrives;
// ACK the echo (pure ACK) like a real client, and track server seq advance
task automatic echo_test(input integer len, input string label, inout reg [31:0] srv_seq);
    byte payload[$];
    bit to;
    integer guard;
    bit got_echo;
    byte exp_pl[$];
    byte ack_payload[$];
begin
    payload.delete();
    ack_payload.delete();
    for (integer i = 0; i < len; i = i + 1) payload.push_back(i[7:0]);
    exp_pl = payload;
    got_echo = 1'b0;

    $display("[%0t] ===== echo %0s (len=%0d) =====", $time, label, len);
    send_tcp_frame(FLAG_PSH_ACK, cli_seq, srv_seq, payload);

    for (guard = 0; guard < 4000 && !got_echo; guard = guard + 1) begin
        recv_tx_frame(to);
        if (to) begin
            check(1'b0, {label, ": timeout waiting for echo"});
            return;
        end
        if (tx_type == ETHERTYPE_IP && (tx_tcp_flags & 8'h08)) begin // PSH -> echo
            check(tx_tcp_seq == srv_seq, {label, ": echo seq advances correctly"});
            check(tx_tcp_payload.size() == len, {label, ": echo length matches"});
            if (tx_tcp_payload.size() == len) begin
                bit same;
                same = 1'b1;
                for (integer i = 0; i < len; i = i + 1)
                    if (tx_tcp_payload[i] !== exp_pl[i]) same = 1'b0;
                check(same, {label, ": echo content matches"});
            end
            // client ACKs the echo (pure ACK, ack = echo_seq + echo_len)
            send_tcp_frame(FLAG_ACK, cli_seq + len, tx_tcp_seq + len, ack_payload);
            srv_seq = srv_seq + len;   // server seq advances by payload length
            got_echo = 1'b1;
        end
    end
    check(got_echo, {label, ": received echo data frame"});
    cli_seq = cli_seq + len;   // advance client send sequence
end
endtask

initial begin
    bit ok;
    reg [31:0] srv_seq;
    $timeformat(-9, 2, " ns", 12);

    @(negedge clk);
    rst = 1'b1;
    repeat (20) @(negedge clk);
    rst = 1'b0;
    repeat (20) @(negedge clk);

    init_conn(ok);
    check(ok, "connection established");

    if (ok) begin
        srv_seq = SERVER_ISN + 32'd1;   // server ISN+1 after SYN+ACK
        echo_test(4,    "small",  srv_seq);
        echo_test(1500, "large",  srv_seq);
        echo_test(64,   "medium", srv_seq);
        echo_test(1,    "tiny",   srv_seq);
        echo_test(8,    "small2", srv_seq);
    end

    $display("=============== RESULT: %0d pass, %0d fail ===============",
             pass_count, fail_count);
    if (fail_count == 0)
        $display("TEST_PASS: all echo checks passed");
    else
        $display("TEST_FAIL");
    $finish;
end

endmodule

`resetall
