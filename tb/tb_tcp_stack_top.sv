`timescale 1ns / 1ps
`default_nettype none

/****************************************************************************
 * @file    tb_tcp_stack_top.sv
 * @brief   End-to-end testbench for rtl/tcp_stack_top.v (MAC-frame level)
 *
 *          以太网帧级行为client模型, 覆盖完整连接生命周期:
 *            PHASE0  ARP配置: desc脉冲 -> ARP请求(广播) -> ARP应答
 *                    -> configuration_done
 *            PHASE1  三次握手: client SYN -> SYN+ACK -> ACK
 *                    (SYN/ACK帧均padding到60B, 逐字段校验ETH/IP/TCP)
 *            PHASE1b 分段接收: 1500B拆成536+536+428三段, 背靠背连续发送
 *                    (不等ACK), 前两段仅ACK(不带PSH)、末段PSH+ACK,
 *                    验证按序接收并逐段回ACK
 *            PHASE2  接收数据: client发送 1..64 字节共64个数据段,
 *                    小帧全部带以太网padding(0x5A), 验证:
 *                    - app_rx投递字节数与内容精确匹配(padding被裁剪)
 *                    - server回ACK号 = client seq + paylen
 *            PHASE3  超时重传: app数据不回ACK -> 超时重传相同TCP段,
 *                    ACK后停止重传并释放发送通路
 *            PHASE4  四次挥手: client FIN -> ACK+FIN+ACK -> 最后ACK
 *                    -> tcp_linkup拉低, 发送通路关闭
 *
 *          Addresses:
 *            FPGA  : IP 192.168.10.13  MAC 00:0a:35:74:51:23  port 80
 *            peer  : IP 192.168.10.72  MAC 35:46:7e:65:12:65  port 12345
 *
 * Run (Vivado xsim, from the repository root): scripts\sim_tcp_stack_top.bat
 * ***************************************************************************/

module tb_tcp_stack_top;

// ---------------------------------------------------------------------------
// addresses / constants
// ---------------------------------------------------------------------------
localparam [47:0] FPGA_MAC  = 48'h00_0a_35_74_51_23;
localparam [31:0] FPGA_IP   = {8'd192, 8'd168, 8'd10, 8'd13};
localparam [47:0] PEER_MAC  = 48'h35_46_7e_65_12_65;
localparam [31:0] PEER_IP   = {8'd192, 8'd168, 8'd10, 8'd72};
localparam [15:0] FPGA_PORT = 16'd80;
localparam [15:0] PEER_PORT = 16'd12345;
localparam [31:0] GATEWAY_IP  = {8'd192, 8'd168, 8'd10, 8'd1};
localparam [31:0] SUBNET_MASK = {8'd255, 8'd255, 8'd255, 8'd0};

localparam [31:0] CLIENT_ISN = 32'h0000_1000;
localparam [31:0] SERVER_ISN = 32'h0000_5000;   // tcp_ctrl复位值

localparam [15:0] ETHERTYPE_ARP = 16'h0806;
localparam [15:0] ETHERTYPE_IP  = 16'h0800;
localparam [7:0]  IP_PROTO_TCP  = 8'h06;

localparam [7:0] FLAG_SYN      = 8'h02;
localparam [7:0] FLAG_ACK      = 8'h10;
localparam [7:0] FLAG_SYN_ACK  = 8'h12;
localparam [7:0] FLAG_PSH_ACK  = 8'h18;
localparam [7:0] FLAG_FIN      = 8'h01;
localparam [7:0] FLAG_FIN_ACK  = 8'h11;

localparam integer MIN_ETH_FRAME = 60;   //以太网最小帧长(不含FCS)
localparam integer PAD_BYTE      = 8'h5A; //padding图样: 若泄漏进app_rx会被检出

localparam RCV_TIMEOUT_CYC = 4000;        //等待一个TX帧/应用帧的超时
//重传参数(经tcp_stack_top参数缩短, 硬件默认125M周期不可仿真)
localparam integer RETX_TIMEOUT_CYC = 1000;
localparam integer RETX_RETRY_CNT   = 2;

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
// DUT signals
// ---------------------------------------------------------------------------
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

reg  [63:0] app_tx_axis_tdata  = 64'd0;
reg  [7:0]  app_tx_axis_tkeep  = 8'h00;
reg         app_tx_axis_tvalid = 1'b0;
reg         app_tx_axis_tlast  = 1'b0;
wire        app_tx_axis_tready;

wire [63:0] app_rx_axis_tdata;
wire [7:0]  app_rx_axis_tkeep;
wire        app_rx_axis_tvalid;
wire        app_rx_axis_tlast;
wire        app_rx_axis_tuser;
reg         app_rx_axis_tready = 1'b1;

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

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// captured frame state (TX wire side)
// ---------------------------------------------------------------------------
byte tx_bytes[$];      // full MAC TX frame
byte tx_ip[$];         // IP packet portion (after 14B eth header)
byte tx_tcp[$];        // TCP segment portion (after IP header)
reg [47:0] tx_dst_mac, tx_src_mac;
reg [15:0] tx_type;
reg [7:0]  tx_ip_proto;
reg [15:0] tx_ip_total_len;
reg [31:0] tx_ip_src, tx_ip_dst;
reg [7:0]  tx_tcp_off;     // data offset * 4 (header bytes)
reg [7:0]  tx_tcp_flags;
reg [31:0] tx_tcp_seq, tx_tcp_ack;

// app / state
byte        app_rx_buf[$];
byte        exp_pl[$];
reg [31:0]  cli_seq;       // client下一个待发送seq
bit         timed_out;
bit         app_to, tx_to;
integer     len_ok_cnt;
integer     len_cnt;
string      current_phase = "reset";

// ---------------------------------------------------------------------------
// helpers: scoreboard / formatting
// ---------------------------------------------------------------------------
task automatic check(input logic cond, input string msg);
    if (cond) begin
        pass_count = pass_count + 1;
    end else begin
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

function automatic string bytes_str(input byte b[$], input integer max_n);
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
// helpers: checksums
// ---------------------------------------------------------------------------
function automatic [15:0] ocsum(input [15:0] a, input [15:0] b);
    logic [16:0] s;
begin
    s = a + b;
    ocsum = s[15:0] + s[16];
end
endfunction

// one's complement sum over a byte queue (big-endian 16-bit words)
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

function automatic [15:0] bytes_sum_offset(input byte b[$],
                                           input integer start,
                                           input integer n);
    logic [15:0] sum;
begin
    sum = 16'd0;
    for (integer i = 0; i < n; i = i + 2)
        if (i + 1 < n) sum = ocsum(sum, {b[start+i], b[start+i+1]});
        else           sum = ocsum(sum, {b[start+i], 8'h00});
    bytes_sum_offset = sum;
end
endfunction

// IPv4 header checksum self-consistency: sum over 20B header == 0xffff
function automatic bit ip_hdr_ok(input byte ip_pkt[$]);
    logic [15:0] sum;
begin
    sum = bytes_sum(ip_pkt, 20);
    ip_hdr_ok = (sum == 16'hffff);
end
endfunction

// TCP checksum self-consistency over pseudo-header + captured segment
function automatic bit tcp_seg_ok(input byte ip_pkt[$], input integer tcp_len);
    logic [15:0] sum;
    byte seg[$];
begin
    for (integer i = 0; i < tcp_len; i = i + 1) seg.push_back(ip_pkt[20 + i]);
    sum  = ocsum(16'd0, {ip_pkt[12], ip_pkt[13]});   // src ip hi
    sum  = ocsum(sum,  {ip_pkt[14], ip_pkt[15]});    // src ip lo
    sum  = ocsum(sum,  {ip_pkt[16], ip_pkt[17]});    // dst ip hi
    sum  = ocsum(sum,  {ip_pkt[18], ip_pkt[19]});    // dst ip lo
    sum  = ocsum(sum,  16'h0006);                    // proto TCP
    sum  = ocsum(sum,  tcp_len[15:0]);               // tcp length
    sum  = ocsum(sum, bytes_sum(seg, tcp_len));
    tcp_seg_ok = (sum == 16'hffff);
end
endfunction

// TCP checksum of a client->server segment (header + optional payload)
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
    sum = ocsum(sum, PEER_PORT);   // source port
    sum = ocsum(sum, FPGA_PORT);   // destination port
    sum = ocsum(sum, seqn[31:16]); sum = ocsum(sum, seqn[15:0]);
    sum = ocsum(sum, ackn[31:16]); sum = ocsum(sum, ackn[15:0]);
    sum = ocsum(sum, {8'h50, flags});
    sum = ocsum(sum, 16'hFFFF);      // window
    sum = ocsum(sum, 16'h0000);      // checksum placeholder
    sum = ocsum(sum, 16'h0000);      // urgent pointer
    for (integer i = 0; i < payload.size(); i = i + 2)
        sum = ocsum(sum, (i + 1 < payload.size()) ? {payload[i], payload[i+1]}
                                                 : {payload[i], 8'h00});
    tcp_checksum = ~sum;
    if (tcp_checksum == 16'd0) tcp_checksum = 16'hFFFF;
end
endfunction

// ---------------------------------------------------------------------------
// helpers: frame injection (client wire side)
// ---------------------------------------------------------------------------
task automatic send_rx_frame(input byte f[$]);
    integer i, j, n;
begin
    @(negedge clk);
    for (i = 0; i < f.size(); i = i + 8) begin
        n = (f.size() - i) > 8 ? 8 : (f.size() - i);
        mac_rx_axis_tdata  = 64'd0;
        for (j = 0; j < 8; j = j + 1)
            if (j < n)
                mac_rx_axis_tdata[j*8 +: 8] = f[i + j];
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

// inject an ARP frame (eth header + 28-byte ARP packet)
task automatic send_arp_frame(input [47:0] dst, input [47:0] src,
                              input [15:0] oper,
                              input [47:0] sha, input [31:0] spa,
                              input [47:0] tha, input [31:0] tpa,
                              input integer pad = 0);
    byte f[$];
begin
    f.delete();
    for (integer i = 0; i < 6; i = i + 1) f.push_back(dst[47 - 8*i -: 8]);
    for (integer i = 0; i < 6; i = i + 1) f.push_back(src[47 - 8*i -: 8]);
    f.push_back(ETHERTYPE_ARP[15:8]); f.push_back(ETHERTYPE_ARP[7:0]);
    f.push_back(8'h00); f.push_back(8'h01);           // HTYPE
    f.push_back(8'h08); f.push_back(8'h00);           // PTYPE
    f.push_back(8'h06);                                // HLEN
    f.push_back(8'h04);                                // PLEN
    f.push_back(oper[15:8]); f.push_back(oper[7:0]);   // OPER
    for (integer i = 0; i < 6; i = i + 1) f.push_back(sha[47 - 8*i -: 8]);
    for (integer i = 0; i < 4; i = i + 1) f.push_back(spa[31 - 8*i -: 8]);
    for (integer i = 0; i < 6; i = i + 1) f.push_back(tha[47 - 8*i -: 8]);
    for (integer i = 0; i < 4; i = i + 1) f.push_back(tpa[31 - 8*i -: 8]);
    for (integer p = 0; p < pad; p = p + 1) f.push_back(8'h00);
    $display("[%0t] RX-wire: ARP oper=0x%04x spa=%s tpa=%s pad=%0d",
             $time, oper, ip_str(spa), ip_str(tpa), pad);
    send_rx_frame(f);
end
endtask

// build+send one client->server TCP segment as a full Ethernet/IPv4 frame;
// small frames are padded with PAD_BYTE up to the Ethernet minimum
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
    // eth header
    for (integer i = 0; i < 6; i = i + 1) f.push_back(FPGA_MAC[47 - 8*i -: 8]);
    for (integer i = 0; i < 6; i = i + 1) f.push_back(PEER_MAC[47 - 8*i -: 8]);
    f.push_back(ETHERTYPE_IP[15:8]); f.push_back(ETHERTYPE_IP[7:0]);
    // IP header (checksum computed with field zeroed)
    f.push_back(8'h45); f.push_back(8'h00);
    f.push_back(ip_total[15:8]); f.push_back(ip_total[7:0]);
    f.push_back(8'h12); f.push_back(8'h34);           // id
    f.push_back(8'h40); f.push_back(8'h00);           // flags/frag
    f.push_back(8'h40); f.push_back(IP_PROTO_TCP);    // ttl, proto
    f.push_back(8'h00); f.push_back(8'h00);           // checksum placeholder
    for (integer i = 0; i < 4; i = i + 1) f.push_back(PEER_IP[31 - 8*i -: 8]);
    for (integer i = 0; i < 4; i = i + 1) f.push_back(FPGA_IP[31 - 8*i -: 8]);
    ip_ck = ~(bytes_sum_offset(f, 14, 20));
    f[24] = ip_ck[15:8]; f[25] = ip_ck[7:0];
    // TCP header
    tcp_ck = tcp_checksum(flags, seqn, ackn, payload);
    f.push_back(PEER_PORT[15:8]); f.push_back(PEER_PORT[7:0]);
    f.push_back(FPGA_PORT[15:8]); f.push_back(FPGA_PORT[7:0]);
    f.push_back(seqn[31:24]); f.push_back(seqn[23:16]); f.push_back(seqn[15:8]);  f.push_back(seqn[7:0]);
    f.push_back(ackn[31:24]); f.push_back(ackn[23:16]); f.push_back(ackn[15:8]);  f.push_back(ackn[7:0]);
    f.push_back(8'h50);              // data offset = 5
    f.push_back(flags);
    f.push_back(8'hFF); f.push_back(8'hFF);   // window
    f.push_back(tcp_ck[15:8]); f.push_back(tcp_ck[7:0]);
    f.push_back(8'h00); f.push_back(8'h00);   // urgent pointer
    for (integer i = 0; i < payload.size(); i = i + 1) f.push_back(payload[i]);
    //以太网padding: 最小帧长60B(不含FCS), padding字节用可识别图样
    pad_idx = 0;
    while (f.size() < MIN_ETH_FRAME) begin
        f.push_back(PAD_BYTE + pad_idx);
        pad_idx = pad_idx + 1;
    end
    $display("[%0t] RX-wire: TCP flags=0x%02x seq=0x%08x ack=0x%08x plen=%0d pad=%0d framelen=%0d",
             $time, flags, seqn, ackn, payload.size(), pad_idx, f.size());
    send_rx_frame(f);
end
endtask

// ---------------------------------------------------------------------------
// helpers: TX frame capture + field extraction
// ---------------------------------------------------------------------------
task automatic recv_tx_frame(output bit timed_out);
    integer lane, guard;
begin
    tx_bytes.delete();
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
        if (mac_tx_axis_tlast)
            break;
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
    // field extraction
    tx_dst_mac = 48'd0;
    tx_src_mac = 48'd0;
    tx_type    = 16'd0;
    tx_ip.delete();
    tx_tcp.delete();
    tx_ip_total_len = 16'd0;
    tx_ip_proto     = 8'd0;
    tx_ip_src       = 32'd0;
    tx_ip_dst       = 32'd0;
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
            tx_tcp_off      = {2'b00, tx_ip[32][7:4], 2'b00};   // (offset nibble)*4
            for (integer i = 20; i < tx_ip.size(); i = i + 1)
                tx_tcp.push_back(tx_ip[i]);
            tx_tcp_seq   = {tx_tcp[4], tx_tcp[5], tx_tcp[6], tx_tcp[7]};
            tx_tcp_ack   = {tx_tcp[8], tx_tcp[9], tx_tcp[10], tx_tcp[11]};
            tx_tcp_flags = tx_tcp[13];
        end
    end
    $display("[%0t] TX-wire: dst=%s type=0x%04x len=%0d flags=0x%02x seq=0x%04x ack=0x%04x",
             $time, mac_str(tx_dst_mac), tx_type, tx_bytes.size(),
             tx_tcp_flags, tx_tcp_seq, tx_tcp_ack);
end
endtask

// ---------------------------------------------------------------------------
// helpers: app / status
// ---------------------------------------------------------------------------
task automatic recv_app_payload(output byte frame[$], output bit timed_out);
    integer guard;
begin
    frame.delete();
    timed_out = 1'b0;
    guard = 0;
    app_rx_axis_tready = 1'b1;
    do begin
        @(posedge clk);
        guard = guard + 1;
        if (guard >= RCV_TIMEOUT_CYC) begin
            timed_out = 1'b1;
            return;
        end
    end while (!(app_rx_axis_tvalid && app_rx_axis_tready));
    forever begin
        for (integer lane = 0; lane < 8; lane = lane + 1)
            if (app_rx_axis_tkeep[lane])
                frame.push_back(app_rx_axis_tdata[lane*8 +: 8]);
        if (app_rx_axis_tlast)
            break;
        guard = 0;
        do begin
            @(posedge clk);
            guard = guard + 1;
            if (guard >= RCV_TIMEOUT_CYC) begin
                timed_out = 1'b1;
                return;
            end
        end while (!(app_rx_axis_tvalid && app_rx_axis_tready));
    end
    @(negedge clk);
end
endtask

task automatic wait_linkup(input logic exp, output bit timed_out);
    integer guard;
begin
    timed_out = 1'b0;
    guard = 0;
    while (tcp_linkup !== exp) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard >= RCV_TIMEOUT_CYC) begin
            timed_out = 1'b1;
            return;
        end
    end
end
endtask

task automatic wait_tready(input logic exp, output bit timed_out);
    integer guard;
begin
    timed_out = 1'b0;
    guard = 0;
    while (app_tx_axis_tready !== exp) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard >= RCV_TIMEOUT_CYC) begin
            timed_out = 1'b1;
            return;
        end
    end
end
endtask

task automatic expect_no_tx(input integer cycles, input string msg);
    bit saw_tx;
begin
    saw_tx = 1'b0;
    repeat (cycles) begin
        @(negedge clk);
        if (mac_tx_axis_tvalid === 1'b1 && mac_tx_axis_tready === 1'b1) saw_tx = 1'b1;
    end
    check(!saw_tx, msg);
end
endtask

// drive application payload into app_tx_axis
task automatic drive_app_payload(input byte pl[$]);
begin
    for (integer i = 0; i < pl.size(); i = i + 8) begin
        integer lanes;
        @(negedge clk);
        lanes = (pl.size() - i) > 8 ? 8 : (pl.size() - i);
        app_tx_axis_tdata = 64'd0;
        app_tx_axis_tkeep = 8'h00;
        for (integer j = 0; j < lanes; j = j + 1) begin
            app_tx_axis_tdata[j*8 +: 8] = pl[i+j];
            app_tx_axis_tkeep[j]        = 1'b1;
        end
        app_tx_axis_tvalid = 1'b1;
        app_tx_axis_tlast  = (i + 8 >= pl.size());
        do @(posedge clk); while (app_tx_axis_tready !== 1'b1);
    end
    @(negedge clk);
    app_tx_axis_tvalid = 1'b0;
    app_tx_axis_tlast  = 1'b0;
    @(negedge clk);
end
endtask

task automatic reset_dut;
begin
    rst = 1'b1;
    repeat (20) @(negedge clk);
    rst = 1'b0;
    repeat (20) @(negedge clk);
end
endtask

// PHASE3 payload compare helper: TCP payload after data-offset bytes
function automatic bit tcp_payload_ok();
    bit ok;
    integer hdr;
begin
    hdr = {tx_tcp[12][7:4], 2'b00};
    ok = (tx_tcp.size() == hdr + exp_pl.size());
    if (ok)
        for (integer i = 0; i < exp_pl.size(); i = i + 1)
            if (tx_tcp[hdr + i] !== exp_pl[i]) ok = 1'b0;
    tcp_payload_ok = ok;
end
endfunction

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

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
byte seg_tcp_prev[$];   // TCP segment of previous (original) frame
byte seg_tcp_now[$];
bit seg_equal;

function automatic bit tcp_segs_equal(input byte a[$], input byte b[$]);
    bit ok;
begin
    ok = (a.size() == b.size());
    if (ok)
        for (integer i = 0; i < a.size(); i = i + 1)
            if (a[i] !== b[i]) ok = 1'b0;
    tcp_segs_equal = ok;
end
endfunction

initial begin
    $timeformat(-9, 2, " ns", 12);

    current_phase = "reset";
    reset_dut;
    cli_seq = CLIENT_ISN + 32'd1;

    // =====================================================================
    current_phase = "ARP resolution";
    $display("[%0t] ===== PHASE0: ARP ask -> configuration_done =====", $time);
    @(negedge clk);
    desc_axis_tvalid = 1'b1;
    @(negedge clk);
    while (desc_axis_tready !== 1'b1) @(negedge clk);
    @(negedge clk);
    desc_axis_tvalid = 1'b0;

    // FPGA发出ARP请求(广播, 询问PEER_IP的MAC)
    recv_tx_frame(tx_to);
    check(!tx_to, "PHASE0: ARP request frame received");
    if (!tx_to && tx_ip.size() >= 28) begin
        check(tx_type == ETHERTYPE_ARP, "PHASE0: ARP ethertype = 0x0806");
        check(tx_dst_mac == 48'hffffffffffff, "PHASE0: ARP request broadcast");
        check(tx_ip.size() == 28, "PHASE0: ARP packet length = 28");
        check({tx_ip[6], tx_ip[7]} == 16'h0001, "PHASE0: ARP OPER = request");
        check({tx_ip[8], tx_ip[9], tx_ip[10], tx_ip[11], tx_ip[12], tx_ip[13]} == FPGA_MAC,
              "PHASE0: ARP SHA = FPGA MAC");
        check({tx_ip[24], tx_ip[25], tx_ip[26], tx_ip[27]} == PEER_IP,
              "PHASE0: ARP TPA = peer IP");
    end

    // client回复ARP reply -> configuration_done
    send_arp_frame(FPGA_MAC, PEER_MAC, 16'h0002,
                   PEER_MAC, PEER_IP, FPGA_MAC, FPGA_IP);
    wait_config_done(timed_out);
    check(!timed_out, "PHASE0: configuration_done asserted");
    expect_no_tx(50, "PHASE0: no tx after ARP resolution");

    // =====================================================================
    current_phase = "unknown ethertype drain";
    $display("[%0t] ===== PHASE0b: unknown ethertype (0x86dd) must not wedge RX =====", $time);
    begin : ph0b
        byte f6[$];
        integer guard;
        bit stuck;
        // a typical IPv6 multicast frame (Solicited-node NS / MLD) as
        // periodically emitted by Windows, ethertype 0x86dd
        f6.push_back(8'h33); f6.push_back(8'h33); f6.push_back(8'h00);
        f6.push_back(8'h00); f6.push_back(8'h00); f6.push_back(8'h01);
        for (integer i = 0; i < 6; i = i + 1) f6.push_back(PEER_MAC[47 - 8*i -: 8]);
        f6.push_back(8'h86); f6.push_back(8'hdd);
        for (integer p = 0; p < 48; p = p + 1) f6.push_back(8'h5a);
        // bounded injection: every beat must be accepted promptly
        stuck = 1'b0;
        guard = 0;
        @(negedge clk);
        for (integer i = 0; i < f6.size() && !stuck; i = i + 8) begin
            integer n;
            n = (f6.size() - i) > 8 ? 8 : (f6.size() - i);
            mac_rx_axis_tdata  = 64'd0;
            for (integer j = 0; j < 8; j = j + 1)
                if (j < n) mac_rx_axis_tdata[j*8 +: 8] = f6[i + j];
            mac_rx_axis_tkeep  = 8'hff >> (8 - n);
            mac_rx_axis_tlast  = (i + 8 >= f6.size());
            mac_rx_axis_tvalid = 1'b1;
            do begin
                @(posedge clk);
                guard = guard + 1;
            end while (mac_rx_axis_tready !== 1'b1 && guard < 500);
            if (mac_rx_axis_tready !== 1'b1) stuck = 1'b1;
            @(negedge clk);
        end
        mac_rx_axis_tvalid = 1'b0;
        mac_rx_axis_tlast  = 1'b0;
        mac_rx_axis_tkeep  = 8'hff;
        check(!stuck, "PHASE0b: IPv6 frame drained (mac_rx_axis_tready stayed live)");
    end

    // padded ARP request (like a real NIC, 60-byte frame) must still get a
    // unicast reply after the unknown-ethertype frame
    $display("[%0t] ===== PHASE0c: padded ARP request -> unicast reply =====", $time);
    current_phase = "padded arp request";
    send_arp_frame(48'hffffffffffff, PEER_MAC, 16'h0001,
                   PEER_MAC, PEER_IP, 48'h0, FPGA_IP, 18);
    recv_tx_frame(tx_to);
    check(!tx_to, "PHASE0c: ARP reply emitted after IPv6 frame");
    if (!tx_to) begin
        check(tx_type == ETHERTYPE_ARP, "PHASE0c: reply ethertype = 0x0806");
        check(tx_dst_mac == PEER_MAC,   "PHASE0c: reply unicast to requester");
        check(tx_ip.size() == 28,       "PHASE0c: ARP packet length = 28");
        check({tx_ip[6], tx_ip[7]} == 16'h0002, "PHASE0c: ARP OPER = reply");
    end

    // =====================================================================
    current_phase = "TCP handshake";
    $display("[%0t] ===== PHASE1: three times handshake client SYN -> SYN+ACK -> ACK =====", $time);
    mac_tx_axis_tready = 1'b0;
    send_tcp_frame(FLAG_SYN, CLIENT_ISN, 32'h0, {} /*no payload*/);

    recv_tx_frame(tx_to);
    check(!tx_to, "PHASE1: SYN+ACK frame received on mac_tx");
    if (!tx_to) begin
        check(tx_type == ETHERTYPE_IP, "PHASE1: ethertype = 0x0800");
        check(tx_dst_mac == PEER_MAC,  "PHASE1: eth dst = peer MAC");
        check(tx_src_mac == FPGA_MAC,  "PHASE1: eth src = FPGA MAC");
        check(tx_ip_proto == IP_PROTO_TCP, "PHASE1: IP protocol = 6 (TCP)");
        check(tx_ip_src == FPGA_IP,    "PHASE1: IP src = FPGA IP");
        check(tx_ip_dst == PEER_IP,    "PHASE1: IP dst = peer IP");
        check(ip_hdr_ok(tx_ip),        "PHASE1: IP header checksum ok");
        check(tx_ip_total_len == 20 + tx_tcp.size(), "PHASE1: IP total length ok");
        check(tcp_seg_ok(tx_ip, tx_ip.size() - 20),  "PHASE1: TCP checksum ok");
        check(tx_tcp_off == 8'd20,     "PHASE1: TCP data offset = 5 (ctrl)");
        check(tx_tcp_flags == FLAG_SYN_ACK, "PHASE1: flags = SYN+ACK");
        check(tx_tcp_seq == SERVER_ISN,     "PHASE1: server seq = 0x5000");
        check(tx_tcp_ack == CLIENT_ISN + 32'd1, "PHASE1: ack = client_isn + 1");
        check({tx_tcp[0],tx_tcp[1]} == FPGA_PORT, "PHASE1: TCP src port = 80");
        check({tx_tcp[2],tx_tcp[3]} == PEER_PORT, "PHASE1: TCP dst port = 12345");
    end
    check(tcp_linkup == 1'b0, "PHASE1: link still down after SYN+ACK");

    //第三次握手
    send_tcp_frame(FLAG_ACK, CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, {});
    wait_linkup(1'b1, timed_out);
    check(!timed_out, "PHASE1: tcp_linkup went high (ESTABLISHED)");
    expect_no_tx(50, "PHASE1: no tx in response to 3rd ACK");

    // =====================================================================
    current_phase = "TCP segmented receive (536+536+428)";
    $display("[%0t] ===== PHASE1b: segmented 1500B=536+536+428 back-to-back, only last PSH =====", $time);
    //发送端把1500字节拆成三段, 背靠背连续发送(不等server的ACK), 每段是独立
    //MAC帧(各自带tlast)。前两段仅ACK(不带PSH), 末段PSH+ACK。
    //验证栈按序接收每一段、逐段回ACK, 而不是只认PSH+ACK。
    begin : ph1b
        integer seg_lens[3];
        integer ack_arr[3];       //捕获到的server ACK号
        integer plen_arr[3];      //捕获到的app_rx负载长度
        bit     ack_to_arr[3];    //捕获ACK是否超时
        bit     app_ok_arr[3];    //负载长度+内容是否匹配
        integer base_seq;

        seg_lens[0] = 536;
        seg_lens[1] = 536;
        seg_lens[2] = 428;
        base_seq    = CLIENT_ISN + 32'd1;

        //三路并行: 注入三段 + 按序收3个ctrl ACK + 按序收3段app_rx负载。
        //各线程使用独立循环变量(块内变量为static, 并行线程不能共享)。
        fork
            begin : ph1b_inject
                byte pl[$];
                integer acc;
                acc = 0;
                for (integer si = 0; si < 3; si = si + 1) begin
                    pl.delete();
                    for (integer sij = 0; sij < seg_lens[si]; sij = sij + 1)
                        pl.push_back((seg_lens[si] + si*32 + sij) & 8'hff);
                    if (si == 2)
                        send_tcp_frame(FLAG_PSH_ACK, base_seq + acc, SERVER_ISN + 32'd1, pl);
                    else
                        send_tcp_frame(FLAG_ACK,      base_seq + acc, SERVER_ISN + 32'd1, pl);
                    acc = acc + seg_lens[si];
                end
            end
            begin : ph1b_cap_ack
                for (integer sa = 0; sa < 3; sa = sa + 1) begin
                    recv_tx_frame(tx_to);
                    ack_to_arr[sa] = tx_to;
                    ack_arr[sa] = tx_to ? 32'h0 : tx_tcp_ack;
                end
            end
            begin : ph1b_cap_app
                for (integer sp = 0; sp < 3; sp = sp + 1) begin
                    recv_app_payload(app_rx_buf, app_to);
                    plen_arr[sp] = app_rx_buf.size();
                    app_ok_arr[sp] = !app_to && (app_rx_buf.size() == seg_lens[sp]);
                    if (app_ok_arr[sp]) begin
                        for (integer spj = 0; spj < seg_lens[sp]; spj = spj + 1) begin
                            if (app_rx_buf[spj] !== ((seg_lens[sp] + sp*32 + spj) & 8'hff)) begin
                                app_ok_arr[sp] = 1'b0;
                                break;
                            end
                        end
                    end
                end
            end
        join

        //按序校验三段: 每段回ACK号 = base + 累计负载长度, app_rx负载长度/内容匹配
        for (integer sv = 0; sv < 3; sv = sv + 1) begin
            integer exp_ack;
            integer acc_v;
            acc_v = 0;
            for (integer k = 0; k <= sv; k = k + 1) acc_v = acc_v + seg_lens[k];
            exp_ack = base_seq + acc_v;

            if (!ack_to_arr[sv] && ack_arr[sv] == exp_ack) begin
                pass_count = pass_count + 1;
            end else begin
                $display("[%0t]   FAIL: PHASE1b seg%0d ack: to=%0b got=0x%04x exp=0x%04x",
                         $time, sv, ack_to_arr[sv], ack_arr[sv], exp_ack);
                fail_count = fail_count + 1;
            end

            if (app_ok_arr[sv] && plen_arr[sv] == seg_lens[sv]) begin
                pass_count = pass_count + 1;
            end else begin
                $display("[%0t]   FAIL: PHASE1b seg%0d app_rx: ok=%0b len=%0d exp=%0d",
                         $time, sv, app_ok_arr[sv], plen_arr[sv], seg_lens[sv]);
                fail_count = fail_count + 1;
            end
        end

        cli_seq = base_seq + 32'd1500;
    end

    // =====================================================================
    current_phase = "TCP receive lengths 1..64";
    $display("[%0t] ===== PHASE2: receive data client->server 1..64byte(add padding) =====", $time);
    len_ok_cnt = 0;
    len_cnt = 0;
    for (integer len = 1; len <= 64; len = len + 1) begin
        bit len_ok;
        exp_pl.delete();
        for (integer i = 0; i < len; i = i + 1)
            exp_pl.push_back((len + i*7) & 8'hff);
        app_rx_axis_tready = 1'b0;
        mac_tx_axis_tready = 1'b0;
        send_tcp_frame(FLAG_PSH_ACK, cli_seq, SERVER_ISN + 32'd1, exp_pl);

        //server的ctrl ACK与app_rx投递并行, 两路同时监听
        fork
            recv_app_payload(app_rx_buf, app_to);
            recv_tx_frame(tx_to);
        join

        len_ok = !app_to && !tx_to
              && (app_rx_buf.size() == len)
              && (tx_type == ETHERTYPE_IP)
              && (tx_ip_proto == IP_PROTO_TCP)
              && (tx_ip_total_len == 16'd40)
              && (tx_tcp.size() == 20)
              && (tx_tcp_flags == FLAG_ACK)
              && (tx_tcp_ack == cli_seq + len)
              && tcp_seg_ok(tx_ip, tx_ip.size() - 20);
        for (integer i = 0; i < len && len_ok; i = i + 1)
            if (app_rx_buf[i] !== exp_pl[i]) len_ok = 1'b0;
        if (len_ok) len_ok_cnt = len_ok_cnt + 1;
        else begin
            $display("[%0t]   FAIL: PHASE2 len=%0d: app_to=%0b tx_to=%0b rxlen=%0d flags=0x%02x ack=0x%04x (exp 0x%04x)",
                     $time, len, app_to, tx_to, app_rx_buf.size(),
                     tx_tcp_flags, tx_tcp_ack, cli_seq + len);
            fail_count = fail_count + 1;
        end
        len_cnt = len_cnt + 1;
        cli_seq = cli_seq + len;
    end
    check(len_ok_cnt == len_cnt,
          $sformatf("PHASE2: all %0d/%0d lengths delivered+acked, padding trimmed", len_ok_cnt, len_cnt));
    $display("[%0t]   PHASE2 summary: %0d/%0d lengths ok", $time, len_ok_cnt, len_cnt);

    // =====================================================================
    current_phase = "TCP retransmission";
    $display("[%0t] ===== PHASE3: retransmission timeout (no ACK -> retransmission -> ACK stop) =====", $time);
    exp_pl.delete();
    for (integer i = 0; i < 16; i = i + 1) exp_pl.push_back(8'hA0 + 8'(i));
    drive_app_payload(exp_pl);

    recv_tx_frame(tx_to);
    check(!tx_to, "PHASE3: original data frame received");
    if (!tx_to) begin
        check(tx_tcp_flags == FLAG_PSH_ACK, "PHASE3: flags = PSH+ACK");
        check(tx_tcp_off == 8'd24, "PHASE3: TCP data offset = 6 (24B header)");
        check(tx_tcp_seq == SERVER_ISN + 32'd1, "PHASE3: seq = server_isn + 1");
        check(tcp_seg_ok(tx_ip, tx_ip.size() - 20), "PHASE3: TCP checksum ok");
        check(tx_tcp.size() == 24 + exp_pl.size(), "PHASE3: frame payload length ok");
        check(tcp_payload_ok(), "PHASE3: payload bytes match");
    end
    seg_tcp_prev.delete();
    for (integer i = 0; i < tx_tcp.size(); i = i + 1) seg_tcp_prev.push_back(tx_tcp[i]);
    //stop-and-wait: 等待ACK期间背压应用侧
    check(app_tx_axis_tready == 1'b0, "PHASE3: app back-pressured awaiting ACK");

    //超时后自动重传相同TCP段
    recv_tx_frame(tx_to);
    check(!tx_to, "PHASE3: retransmitted frame received after timeout");
    seg_tcp_now.delete();
    for (integer i = 0; i < tx_tcp.size(); i = i + 1) seg_tcp_now.push_back(tx_tcp[i]);
    seg_equal = tcp_segs_equal(seg_tcp_now, seg_tcp_prev);
    check(seg_equal, "PHASE3: retransmitted TCP segment identical");

    //重传到达后client回ACK: 停止重传并释放发送通路
    send_tcp_frame(FLAG_ACK, cli_seq, SERVER_ISN + 32'd1 + 32'd16, {});
    wait_tready(1'b1, timed_out);
    check(!timed_out, "PHASE3: app released after ACK");
    expect_no_tx(RETX_TIMEOUT_CYC + 100, "PHASE3: no retransmission after ACK");

    // =====================================================================
    current_phase = "TCP close";
    $display("[%0t] ===== PHASE4: Four waves FIN -> ACK+FIN+ACK -> link down =====", $time);
    mac_tx_axis_tready = 1'b0;
    send_tcp_frame(FLAG_FIN, cli_seq, SERVER_ISN + 32'd1 + 32'd16, {});

    recv_tx_frame(tx_to);
    check(!tx_to, "PHASE4: 1st ctrl frame (ACK) received");
    if (!tx_to) begin
        check(tx_tcp_flags == FLAG_ACK, "PHASE4: 1st flags = ACK");
        check(tx_tcp_ack == cli_seq + 32'd1, "PHASE4: ACK number = fin_seq + 1");
    end

    recv_tx_frame(tx_to);
    check(!tx_to, "PHASE4: 2nd ctrl frame (FIN+ACK) received");
    if (!tx_to) begin
        check(tx_tcp_flags == FLAG_FIN_ACK, "PHASE4: 2nd flags = FIN+ACK");
        check(tx_tcp_ack == cli_seq + 32'd1, "PHASE4: FIN+ACK number = fin_seq + 1");
        check(tx_tcp_seq == SERVER_ISN + 32'd1 + 32'd16,
              "PHASE4: server seq = client ACK number");
    end
    check(tcp_linkup == 1'b1, "PHASE4: link still up before final ACK");

    //第四次挥手: client最后ACK (server的FIN消耗一个序号)
    send_tcp_frame(FLAG_ACK, cli_seq + 32'd1, SERVER_ISN + 32'd2 + 32'd16, {});
    wait_linkup(1'b0, timed_out);
    check(!timed_out, "PHASE4: tcp_linkup deasserted (CLOSED)");
    check(app_tx_axis_tready == 1'b0, "PHASE4: app tx gated by link-down");
    expect_no_tx(100, "PHASE4: no tx after close");

    // =====================================================================
    if (fail_count == 0)
        $display("[%0t] ================ ALL %0d CHECKS PASSED ================", $time, pass_count);
    else
        $display("[%0t] ================ %0d/%0d CHECKS FAILED ================",
                 $time, fail_count, pass_count + fail_count);
    if (fail_count != 0)
        $fatal(1, "tb_tcp_stack_top failed %0d of %0d checks",
               fail_count, pass_count + fail_count);
    $display("TEST_PASS: %0d checks completed", pass_count);
    $finish;
end

// global watchdog
initial begin
    #(10 * 400000);
    $fatal(1, "WATCHDOG: phase=%0s time=%0t", current_phase, $time);
end

endmodule

`default_nettype wire
