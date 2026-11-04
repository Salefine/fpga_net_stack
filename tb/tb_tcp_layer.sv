`timescale 1ns / 1ps

/****************************************************************************
 * @file    tb_tcp_layer.sv
 * @brief   Integration testbench for rtl/tcp/tcp_layer.v
 *
 * 以行为级TCP client模型跑完整连接生命周期:
 *   PHASE1  三次握手(1/3): client SYN    -> server SYN+ACK (ctrl仲裁)
 *   PHASE2  三次握手(3/3): client ACK    -> tcp_linkup=1 (ESTABLISHED)
 *   PHASE3  发送数据: app payload         -> data包(PSH+ACK), stop-and-wait背压
 *   PHASE4  发送数据: client纯ACK         -> 释放发送通路(app_tx_tready回高)
 *   PHASE5  接收数据: client数据段        -> app_rx_axis投递负载 + ctrl ACK
 *   PHASE6  重传(放弃): 不回ACK           -> 超时重传RETX_RETRY_CNT次相同包,
 *           次数耗尽后放弃本包并释放发送通路
 *   PHASE7  重传(恢复): 重传一次后回ACK   -> 停止重传并释放发送通路
 *   PHASE8  四次挥手(1/2): client FIN     -> server ACK + FIN+ACK (ctrl)
 *   PHASE9  四次挥手(3/4): client最后ACK  -> tcp_linkup=0 (CLOSED)
 *
 * 重传超时/次数经tcp_layer参数在仿真中缩短(硬件默认125M周期不可仿真)。
 *
 * Run (Vivado xsim, from the repository root): scripts\sim_tcp_layer.bat 或
 *   xvlog -sv rtl/tcp/tcp_tx.v rtl/tcp/tcp_rx.v rtl/tcp/tcp_ctrl.v \
 *              rtl/tcp/tcp_layer.v tb/tb_tcp_layer.sv
 *   xelab tb_tcp_layer -s tb_tcp_layer_sim -O0 -mt off -L xpm
 *   xsim  tb_tcp_layer_sim -runall
 * ***************************************************************************/

module tb_tcp_layer;

localparam CLOCK_PERIOD = 100;   // 10 MHz

localparam [31:0] SERVER_IP   = 32'hC0A8010A;   // 192.168.1.10 (FPGA)
localparam [31:0] CLIENT_IP   = 32'hC0A80114;   // 192.168.1.20
localparam [15:0] SERVER_PORT = 16'h0050;       // 80
localparam [15:0] CLIENT_PORT = 16'h3039;       // 12345
localparam [31:0] SERVER_ISN  = 32'h00005000;
localparam [31:0] CLIENT_ISN  = 32'h00001000;

localparam [7:0] FLAG_SYN      = 8'h02;
localparam [7:0] FLAG_ACK      = 8'h10;
localparam [7:0] FLAG_SYN_ACK  = 8'h12;
localparam [7:0] FLAG_PSH_ACK  = 8'h18;
localparam [7:0] FLAG_FIN      = 8'h01;
localparam [7:0] FLAG_FIN_ACK  = 8'h11;

localparam RCV_TIMEOUT_CYC = 4000;   //等待一个TX包/应用帧的超时(周期数)

//重传参数(仿真缩短; 超时需远小于RCV_TIMEOUT_CYC以便捕获重传包)
localparam integer RETX_TIMEOUT_CYC = 1000;   //重传超时周期数
localparam integer RETX_RETRY_CNT   = 2;      //超时重传次数

// ---------------------------------------------------------------------------
// clock / reset
// ---------------------------------------------------------------------------
logic clk = 1'b0;
logic rst = 1'b1;
always #(CLOCK_PERIOD/2) clk = ~clk;

// app -> tcp_layer (data to transmit)
logic [63:0] app_tx_axis_tdata  = '0;
logic [7:0]  app_tx_axis_tkeep  = '0;
logic        app_tx_axis_tvalid = 1'b0;
logic        app_tx_axis_tlast  = 1'b0;
wire         app_tx_axis_tready;

// tcp_layer -> ip
wire [63:0]  tcp_tx_axis_tdata;
wire [7:0]   tcp_tx_axis_tkeep;
wire         tcp_tx_axis_tvalid;
wire         tcp_tx_axis_tlast;
logic        tcp_tx_axis_tready = 1'b1;

// ip_rx -> tcp_layer (client segments)
logic [63:0] tcp_rx_axis_tdata  = '0;
logic [7:0]  tcp_rx_axis_tkeep  = '0;
logic        tcp_rx_axis_tvalid = 1'b0;
logic        tcp_rx_axis_tlast  = 1'b0;
logic        tcp_rx_axis_tuser  = 1'b0;
wire         tcp_rx_axis_tready;

// tcp_layer -> app (received payload)
wire [63:0]  app_rx_axis_tdata;
wire [7:0]   app_rx_axis_tkeep;
wire         app_rx_axis_tvalid;
wire         app_rx_axis_tlast;
wire         app_rx_axis_tuser;
logic        app_rx_axis_tready = 1'b1;

logic [15:0] tcp_paylen = 16'd20;
wire         tcp_linkup;

tcp_layer #(
    .RETRANSMIT_RETRY_COUNT (RETX_RETRY_CNT  ),
    .RETRANSMIT_TIMEOUT     (RETX_TIMEOUT_CYC)
) dut (
    .src_ip_addr         (SERVER_IP          ),
    .dst_ip_addr         (CLIENT_IP          ),
    .recv_src_ip_addr    (CLIENT_IP          ),
    .recv_dst_ip_addr    (SERVER_IP          ),
    .tcp_src_port        (SERVER_PORT        ),
    // 故意配错: 动态端口学习应无视该静态配置, 回复目的端口=client实际源端口
    .tcp_dst_port        (16'hFFFF           ),
    .tcp_linkup          (tcp_linkup         ),
    .tcp_paylen          (tcp_paylen         ),
    .clk                 (clk                ),
    .rst                 (rst                ),
    .app_tx_axis_tdata   (app_tx_axis_tdata  ),
    .app_tx_axis_tkeep   (app_tx_axis_tkeep  ),
    .app_tx_axis_tvalid  (app_tx_axis_tvalid ),
    .app_tx_axis_tlast   (app_tx_axis_tlast  ),
    .app_tx_axis_tready  (app_tx_axis_tready ),
    .tcp_tx_axis_tdata   (tcp_tx_axis_tdata  ),
    .tcp_tx_axis_tkeep   (tcp_tx_axis_tkeep  ),
    .tcp_tx_axis_tvalid  (tcp_tx_axis_tvalid ),
    .tcp_tx_axis_tlast   (tcp_tx_axis_tlast  ),
    .tcp_tx_axis_tready  (tcp_tx_axis_tready ),
    .tcp_rx_axis_tdata   (tcp_rx_axis_tdata  ),
    .tcp_rx_axis_tkeep   (tcp_rx_axis_tkeep  ),
    .tcp_rx_axis_tvalid  (tcp_rx_axis_tvalid ),
    .tcp_rx_axis_tlast   (tcp_rx_axis_tlast  ),
    .tcp_rx_axis_tready  (tcp_rx_axis_tready ),
    .tcp_rx_axis_tuser   (tcp_rx_axis_tuser  ),
    .app_rx_axis_tdata   (app_rx_axis_tdata  ),
    .app_rx_axis_tkeep   (app_rx_axis_tkeep  ),
    .app_rx_axis_tvalid  (app_rx_axis_tvalid ),
    .app_rx_axis_tlast   (app_rx_axis_tlast  ),
    .app_rx_axis_tuser   (app_rx_axis_tuser  ),
    .app_rx_axis_tready  (app_rx_axis_tready )
);

// ---------------------------------------------------------------------------
// scoreboard
// ---------------------------------------------------------------------------
integer pass_count = 0;
integer fail_count = 0;

// ---------------------------------------------------------------------------
// stimulus queues / state (供下方task与initial块共享)
// ---------------------------------------------------------------------------
logic [7:0] seg [$];
logic [7:0] pkt [$];
logic [7:0] pl_tx [$];        //app -> dut payload
logic [7:0] pl_rx [$];        //client -> dut payload
logic [7:0] app_rx_buf [$];   //collected app_rx frame
logic [7:0] tx_first [$];     //original transmitted packet
logic [7:0] tx_ret [$];       //retransmitted packet
logic [31:0] cli_seq;         //client下一个待发送seq
bit         timed_out;
bit         ok1;
bit         app_to;    //app_rx采集超时
bit         tx_to;     //tcp_tx采集超时

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
// one's complement checksum (pseudo header + TCP segment)
// ---------------------------------------------------------------------------
function automatic [15:0] ones_add (input [15:0] a, input [15:0] b);
    logic [31:0] s;
    s = a + b;
    while (s > 32'hFFFF)
        s = (s & 32'hFFFF) + (s >> 16);
    return s[15:0];
endfunction

// TCP checksum of a client->server segment (header + optional payload)
function automatic [15:0] tcp_checksum (input [7:0]  flags,
                                        input [31:0] seqn,
                                        input [31:0] ackn,
                                        input logic [7:0] payload [$]);
    logic [15:0] sum;
    sum = 16'h0000;
    // pseudo header (src=client, dst=server)
    sum = ones_add(sum, CLIENT_IP[31:16]); sum = ones_add(sum, CLIENT_IP[15:0]);
    sum = ones_add(sum, SERVER_IP[31:16]); sum = ones_add(sum, SERVER_IP[15:0]);
    sum = ones_add(sum, 16'h0006);
    sum = ones_add(sum, 16'(20 + payload.size()));
    // header
    sum = ones_add(sum, CLIENT_PORT);   // source port
    sum = ones_add(sum, SERVER_PORT);   // destination port
    sum = ones_add(sum, seqn[31:16]);   sum = ones_add(sum, seqn[15:0]);
    sum = ones_add(sum, ackn[31:16]);   sum = ones_add(sum, ackn[15:0]);
    sum = ones_add(sum, {8'h50, flags});
    sum = ones_add(sum, 16'hFFFF);      // window
    sum = ones_add(sum, 16'h0000);      // checksum placeholder
    sum = ones_add(sum, 16'h0000);      // urgent pointer
    // payload
    for (integer i = 0; i < payload.size(); i = i + 2)
        sum = ones_add(sum, (i + 1 < payload.size()) ? {payload[i], payload[i+1]}
                                                     : {payload[i], 8'h00});
    sum = ~sum;
    if (sum == 16'h0000) sum = 16'hFFFF;
    return sum;
endfunction

// build a full client->server TCP segment (20 byte header + payload)
function automatic void build_segment (output logic [7:0] seg [$],
                                       input  [7:0]  flags,
                                       input  [31:0] seqn,
                                       input  [31:0] ackn,
                                       input  logic [7:0] payload [$]);
    logic [15:0] ck;
    seg.delete();
    ck = tcp_checksum(flags, seqn, ackn, payload);
    seg.push_back(CLIENT_PORT[15:8]); seg.push_back(CLIENT_PORT[7:0]);
    seg.push_back(SERVER_PORT[15:8]); seg.push_back(SERVER_PORT[7:0]);
    seg.push_back(seqn[31:24]); seg.push_back(seqn[23:16]);
    seg.push_back(seqn[15:8]);  seg.push_back(seqn[7:0]);
    seg.push_back(ackn[31:24]); seg.push_back(ackn[23:16]);
    seg.push_back(ackn[15:8]);  seg.push_back(ackn[7:0]);
    seg.push_back(8'h50);              // data offset = 5
    seg.push_back(flags);
    seg.push_back(8'hFF); seg.push_back(8'hFF);   // window
    seg.push_back(ck[15:8]); seg.push_back(ck[7:0]);
    seg.push_back(8'h00); seg.push_back(8'h00);   // urgent pointer
    for (integer i = 0; i < payload.size(); i = i + 1)
        seg.push_back(payload[i]);
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

// seq/ack number of a collected TCP packet (byte 0 first)
function automatic [31:0] pkt_seq (input logic [7:0] pkt [$]);
    return {pkt[4], pkt[5], pkt[6], pkt[7]};
endfunction

function automatic [31:0] pkt_ack (input logic [7:0] pkt [$]);
    return {pkt[8], pkt[9], pkt[10], pkt[11]};
endfunction

// packet payload (after hdr_len bytes) matches the expected byte queue
function automatic bit payload_match (input logic [7:0] pkt [$],
                                      input integer hdr_len,
                                      input logic [7:0] pl [$]);
    bit ok;
    ok = (pkt.size() == hdr_len + pl.size());
    if (ok)
        for (integer i = 0; i < pl.size(); i = i + 1)
            if (pkt[hdr_len + i] !== pl[i]) ok = 1'b0;
    return ok;
endfunction

// two collected packets are byte-identical (重传内容比对)
function automatic bit packets_equal (input logic [7:0] a [$],
                                      input logic [7:0] b [$]);
    bit ok;
    ok = (a.size() == b.size());
    if (ok)
        for (integer i = 0; i < a.size(); i = i + 1)
            if (a[i] !== b[i]) ok = 1'b0;
    return ok;
endfunction

// n-byte test payload: base, base+1, ...
function automatic void make_pl (output logic [7:0] pl [$],
                                 input [7:0] base, input integer n);
    pl.delete();
    for (integer i = 0; i < n; i = i + 1)
        pl.push_back(base + 8'(i));
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

// drive a client segment into tcp_rx_axis (honoring tready)
task automatic drive_rx_segment (input logic [7:0] seg [$]);
    //IP层提供的TCP段总长(含TCP头, 不含以太网padding):
    //供tcp_rx做padding裁剪与校验和length字段
    tcp_paylen = 16'(seg.size());
    for (integer i = 0; i < seg.size(); i = i + 8) begin
        integer lanes;
        lanes = (seg.size() - i) > 8 ? 8 : (seg.size() - i);
        tcp_rx_axis_tdata = 64'h0;
        tcp_rx_axis_tkeep = 8'h00;
        for (integer j = 0; j < lanes; j = j + 1) begin
            tcp_rx_axis_tdata[j*8 +: 8] = seg[i+j];
            tcp_rx_axis_tkeep[j]        = 1'b1;
        end
        tcp_rx_axis_tvalid = 1'b1;
        tcp_rx_axis_tlast  = (i + 8 >= seg.size());
        do @(negedge clk); while (!tcp_rx_axis_tready);
    end
    tcp_rx_axis_tvalid = 1'b0;
    tcp_rx_axis_tlast  = 1'b0;
    @(negedge clk);
endtask

// drive application payload into app_tx_axis (honoring tready)
task automatic drive_app_payload (input logic [7:0] pl [$]);
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
            @(negedge clk);   //最后一拍: 保持一拍被接收
        else
            do @(negedge clk); while (!app_tx_axis_tready);
    end
    app_tx_axis_tvalid = 1'b0;
    app_tx_axis_tlast  = 1'b0;
    @(negedge clk);
endtask

// collect one full packet from tcp_tx_axis (byte 0 first)
task automatic recv_tx_packet (output logic [7:0] pkt [$],
                               output bit          timed_out);
    integer guard;
    pkt.delete();
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
                pkt.push_back(tcp_tx_axis_tdata[lane*8 +: 8]);
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

// wait until tcp_linkup reaches the expected value
task automatic wait_linkup (input logic exp, output bit timed_out);
    integer guard;
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
endtask

// wait until app_tx_axis_tready reaches the expected value
task automatic wait_tready (input logic exp, output bit timed_out);
    integer guard;
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
endtask

// assert nothing appears on tcp_tx_axis for the next N cycles
task automatic expect_no_tx (input integer cycles, input string msg);
    bit saw_tx;
    saw_tx = 1'b0;
    repeat (cycles) begin
        @(negedge clk);
        if (tcp_tx_axis_tvalid === 1'b1) saw_tx = 1'b1;
    end
    check(!saw_tx, msg);
endtask

// collect one full application frame from app_rx_axis (byte 0 first)
task automatic recv_app_payload (output logic [7:0] frame [$],
                                 output bit          timed_out);
    integer guard;
    frame.delete();
    timed_out = 1'b0;
    guard = 0;
    while (app_rx_axis_tvalid !== 1'b1) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard >= RCV_TIMEOUT_CYC) begin
            timed_out = 1'b1;
            return;
        end
    end
    forever begin
        for (integer lane = 0; lane < 8; lane = lane + 1)
            if (app_rx_axis_tkeep[lane])
                frame.push_back(app_rx_axis_tdata[lane*8 +: 8]);
        if (app_rx_axis_tlast)
            break;
        @(negedge clk);
        guard = 0;
        while (app_rx_axis_tvalid !== 1'b1) begin
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

// build + drive one client->server segment
task automatic client_send (input [7:0] flags, input [31:0] seqn, input [31:0] ackn,
                            input logic [7:0] payload [$]);
    build_segment(seg, flags, seqn, ackn, payload);
    drive_rx_segment(seg);
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
initial begin
    $timeformat(-9, 2, " ns", 12);

    reset_dut;

    //握手完成后client待发送的下一个seq
    cli_seq = CLIENT_ISN + 32'd1;

    // =====================================================================
    $display("[%0t] ===== PHASE1: 三次握手(1/3) client SYN -> SYN+ACK =====", $time);
    client_send(FLAG_SYN, CLIENT_ISN, 32'h0, {} /*no payload*/);

    recv_tx_packet(pkt, timed_out);
    check(!timed_out, "PHASE1: SYN+ACK received on tcp_tx_axis");
    if (!timed_out) begin
        $display("[%0t]   tx      : %s", $time, bytes_str(pkt, 24));
        //动态端口学习: SYN+ACK目的端口必须=client源端口(0x3039), 而非配置值
        check({pkt[0],pkt[1]} == SERVER_PORT,
              $sformatf("PHASE1: src port = 0x%02x%02x (server)", pkt[0], pkt[1]));
        check({pkt[2],pkt[3]} == CLIENT_PORT,
              $sformatf("PHASE1: dst port = 0x%02x%02x (learned client port)", pkt[2], pkt[3]));
        check(pkt[12] == 8'h50, "PHASE1: data offset = 0x50 (ctrl 20B header)");
        check(pkt[13] == FLAG_SYN_ACK,
              $sformatf("PHASE1: flags = 0x%02x (SYN+ACK)", FLAG_SYN_ACK));
        check({pkt[4],pkt[5],pkt[6],pkt[7]} == SERVER_ISN,
              "PHASE1: server seq = 0x00005000");
        check({pkt[8],pkt[9],pkt[10],pkt[11]} == CLIENT_ISN + 1'b1,
              "PHASE1: server ack = client_isn + 1");
        check(tcp_linkup == 1'b0, "PHASE1: link still down after SYN+ACK");
    end
    expect_no_tx(50, "PHASE1: no extra tx before 3rd handshake ACK");

    // =====================================================================
    $display("[%0t] ===== PHASE2: 三次握手(3/3) client ACK -> ESTABLISHED =====", $time);
    client_send(FLAG_ACK, CLIENT_ISN + 32'd1, SERVER_ISN + 32'd1, {});
    wait_linkup(1'b1, timed_out);
    check(!timed_out, "PHASE2: tcp_linkup went high");
    expect_no_tx(50, "PHASE2: no tx in response to 3rd ACK");

    // =====================================================================
    $display("[%0t] ===== PHASE3: 发送数据 app payload -> data包(PSH+ACK) =====", $time);
    make_pl(pl_tx, 8'hA0, 8);
    drive_app_payload(pl_tx);
    recv_tx_packet(pkt, timed_out);
    check(!timed_out, "PHASE3: data packet received on tcp_tx_axis");
    if (!timed_out) begin
        $display("[%0t]   tx      : %s", $time, bytes_str(pkt, 32));
        check(pkt[12] == 8'h60, "PHASE3: data offset = 0x60 (24B header)");
        check(pkt[13] == FLAG_PSH_ACK,
              $sformatf("PHASE3: flags = 0x%02x (PSH+ACK)", FLAG_PSH_ACK));
        check(pkt_seq(pkt) == SERVER_ISN + 32'd1, "PHASE3: seq = server_isn + 1");
        check(pkt_ack(pkt) == cli_seq, "PHASE3: ack = client seq (no rx data yet)");
        check(payload_match(pkt, 24, pl_tx), "PHASE3: payload bytes match");
    end
    // stop-and-wait: data path busy until client ACKs
    check(app_tx_axis_tready == 1'b0, "PHASE3: app back-pressured (awaiting ACK)");

    // =====================================================================
    $display("[%0t] ===== PHASE4: 发送数据 client纯ACK -> 释放发送通路 =====", $time);
    client_send(FLAG_ACK, cli_seq, SERVER_ISN + 32'd1 + 32'd8, {});
    //等待tcp_psh_ack传播并清除tx_busy
    wait_tready(1'b1, timed_out);
    check(!timed_out, "PHASE4: app released after ACK");

    // =====================================================================
    $display("[%0t] ===== PHASE5: 接收数据 client数据段 -> app_rx + ctrl ACK =====", $time);
    make_pl(pl_rx, 8'hB0, 13);   //13B: 覆盖offset跨拍拼接与末拍部分字节(tkeep)
    client_send(FLAG_PSH_ACK, cli_seq, SERVER_ISN + 32'd1, pl_rx);

    //ctrl ACK与app_rx负载投递并行发生, 需同时监听两路输出(否则先到者会被常高的tready冲掉)
    fork
        recv_app_payload(app_rx_buf, app_to);
        recv_tx_packet (pkt,         tx_to);
    join

    check(!app_to, "PHASE5: payload delivered on app_rx_axis");
    if (!app_to) begin
        $display("[%0t]   app_rx  : %s", $time, bytes_str(app_rx_buf, 32));
        check(app_rx_buf.size() == pl_rx.size(),
              $sformatf("PHASE5: app_rx byte count = %0d", pl_rx.size()));
        ok1 = 1'b1;
        for (integer i = 0; i < pl_rx.size(); i = i + 1)
            if (app_rx_buf[i] !== pl_rx[i]) ok1 = 1'b0;
        check(ok1, "PHASE5: app_rx payload bytes match");
    end

    check(!tx_to, "PHASE5: ctrl ACK received on tcp_tx_axis");
    if (!tx_to) begin
        $display("[%0t]   tx      : %s", $time, bytes_str(pkt, 24));
        check(pkt[12] == 8'h50, "PHASE5: ACK packet is ctrl (offset 0x50)");
        check(pkt[13] == FLAG_ACK,
              $sformatf("PHASE5: flags = 0x%02x (ACK)", FLAG_ACK));
        check(pkt_ack(pkt) == cli_seq + 32'(pl_rx.size()),
              "PHASE5: server ack = client seq + paylen");
        check(pkt_seq(pkt) == SERVER_ISN + 32'd1 + 32'd8,
              "PHASE5: server seq advanced by 8 after PHASE4 ACK");
    end
    cli_seq = cli_seq + 32'(pl_rx.size());

    // =====================================================================
    $display("[%0t] ===== PHASE6: 重传(放弃) 不回ACK -> 超时重传x%0d后放弃 =====",
             $time, RETX_RETRY_CNT);
    make_pl(pl_tx, 8'hC0, 8);
    drive_app_payload(pl_tx);

    recv_tx_packet(tx_first, timed_out);
    check(!timed_out, "PHASE6: original data packet received");
    if (!timed_out) begin
        $display("[%0t]   tx      : %s", $time, bytes_str(tx_first, 32));
        check(payload_match(tx_first, 24, pl_tx), "PHASE6: original payload match");
    end
    check(app_tx_axis_tready == 1'b0, "PHASE6: back-pressured awaiting ACK");

    //超时后应自动重传内容完全相同的段
    recv_tx_packet(tx_ret, timed_out);
    check(!timed_out, "PHASE6: 1st retransmission after timeout");
    if (!timed_out) begin
        $display("[%0t]   retx    : %s", $time, bytes_str(tx_ret, 32));
        check(packets_equal(tx_ret, tx_first), "PHASE6: 1st retransmission identical");
    end

    recv_tx_packet(tx_ret, timed_out);
    check(!timed_out, "PHASE6: 2nd retransmission after timeout");
    if (!timed_out)
        check(packets_equal(tx_ret, tx_first), "PHASE6: 2nd retransmission identical");

    //重传次数耗尽: 放弃本包, 释放发送通路, 之后不再有任何发送
    wait_tready(1'b1, timed_out);
    check(!timed_out, "PHASE6: tready released after retries exhausted");
    expect_no_tx(RETX_TIMEOUT_CYC + 100, "PHASE6: no further tx after give-up");

    // =====================================================================
    $display("[%0t] ===== PHASE7: 重传(恢复) 重传一次后回ACK -> 停止重传 =====", $time);
    make_pl(pl_tx, 8'hD0, 12);
    drive_app_payload(pl_tx);

    recv_tx_packet(tx_first, timed_out);
    check(!timed_out, "PHASE7: original data packet received");
    if (!timed_out)
        check(payload_match(tx_first, 24, pl_tx), "PHASE7: original payload match");

    recv_tx_packet(tx_ret, timed_out);
    check(!timed_out, "PHASE7: retransmission after timeout");
    if (!timed_out)
        check(packets_equal(tx_ret, tx_first), "PHASE7: retransmission identical");

    //重传到达后client回ACK: 应停止后续重传并释放发送通路
    //server seq已推进到 ISN+1+8(前8B被PHASE4确认), 本段12B的ACK号 = seq+12
    client_send(FLAG_ACK, cli_seq, SERVER_ISN + 32'd1 + 32'd8 + 32'd12, {});
    wait_tready(1'b1, timed_out);
    check(!timed_out, "PHASE7: tready released after ACK");
    expect_no_tx(RETX_TIMEOUT_CYC + 100, "PHASE7: no retransmission after ACK");

    // =====================================================================
    $display("[%0t] ===== PHASE8: 四次挥手(1/2) client FIN -> ACK + FIN+ACK =====", $time);
    //FIN携带的ack = server当前发送序号(ISN+1+8+12)
    client_send(FLAG_FIN, cli_seq, SERVER_ISN + 32'd1 + 32'd8 + 32'd12, {});

    // 挥手第1步应答: 纯ACK, ack = client FIN seq + 1
    recv_tx_packet(pkt, timed_out);
    check(!timed_out, "PHASE8: 1st ctrl packet received");
    if (!timed_out) begin
        $display("[%0t]   tx      : %s", $time, bytes_str(pkt, 24));
        check(pkt[12] == 8'h50, "PHASE8: 1st packet is ctrl (offset 0x50)");
        check(pkt[13] == FLAG_ACK,
              $sformatf("PHASE8: 1st packet flags = 0x%02x (ACK)", FLAG_ACK));
        check(pkt_ack(pkt) == cli_seq + 32'd1, "PHASE8: ACK number = fin_seq + 1");
    end

    // 挥手第2步: FIN+ACK
    recv_tx_packet(pkt, timed_out);
    check(!timed_out, "PHASE8: 2nd ctrl packet received");
    if (!timed_out) begin
        $display("[%0t]   tx      : %s", $time, bytes_str(pkt, 24));
        check(pkt[12] == 8'h50, "PHASE8: 2nd packet is ctrl (offset 0x50)");
        check(pkt[13] == FLAG_FIN_ACK,
              $sformatf("PHASE8: 2nd packet flags = 0x%02x (FIN+ACK)", FLAG_FIN_ACK));
        check(pkt_ack(pkt) == cli_seq + 32'd1, "PHASE8: FIN+ACK number = fin_seq + 1");
        check(pkt_seq(pkt) == SERVER_ISN + 32'd1 + 32'd8 + 32'd12,
              "PHASE8: server seq = pre-FIN seq");
    end
    check(tcp_linkup == 1'b1, "PHASE8: link still up before final ACK");

    // =====================================================================
    $display("[%0t] ===== PHASE9: 四次挥手(3/4) client最后ACK -> CLOSED =====", $time);
    //server的FIN消耗一个序号: client ack = server_seq + 1
    client_send(FLAG_ACK, cli_seq + 32'd1, SERVER_ISN + 32'd1 + 32'd8 + 32'd12 + 32'd1, {});
    wait_linkup(1'b0, timed_out);
    check(!timed_out, "PHASE9: tcp_linkup deasserted (CLOSED)");
    check(app_tx_axis_tready == 1'b0, "PHASE9: app tx gated by link-down");
    expect_no_tx(100, "PHASE9: no tx after close");

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
