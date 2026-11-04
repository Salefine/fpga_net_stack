`timescale 1ns / 1ps
`default_nettype none

/**************************************************************************** 
 * Hardware-realistic ARP testbench for rtl/udp_stack_top.v
 *
 * Reproduces exactly what the 10G MAC (eth_mac_10g_fifo, FCS stripped,
 * padding NOT stripped) delivers to the stack when a host NIC sends an
 * ARP request: a 60-byte frame = 14B eth header + 28B ARP + 18B padding.
 *
 * Addresses taken from the user's Wireshark capture:
 *   host : IP 192.168.2.10   MAC 00:02:c9:53:ee:10
 *   FPGA : IP 192.168.2.35   MAC 00:0a:35:74:51:23
 ***************************************************************************/

module tb_arp_hw;

localparam [47:0] HOST_MAC = 48'h00_02_c9_53_ee_10;
localparam [31:0] HOST_IP  = {8'd192, 8'd168, 8'd2, 8'd10};
localparam [47:0] FPGA_MAC = 48'h00_0a_35_74_51_23;
localparam [31:0] FPGA_IP  = {8'd192, 8'd168, 8'd2, 8'd35};

localparam integer REQUEST_RETRY_COUNT    = 2;
localparam integer REQUEST_RETRY_INTERVAL = 200;
localparam integer REQUEST_TIMEOUT        = 600;

reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;

integer fail_count = 0;

reg  desc_axis_tvalid = 1'b0;
wire desc_axis_tready;
wire configuration_done;
reg [31:0] src_ip_addr     = FPGA_IP;
reg [31:0] gateway_ip_addr = {8'd192, 8'd168, 8'd2, 8'd1};
reg [31:0] subnet_mask     = {8'd255, 8'd255, 8'd255, 8'd0};
reg [31:0] dst_ip_addr     = HOST_IP;
reg [47:0] src_mac_addr    = FPGA_MAC;
reg [15:0] udp_src_port    = 16'd8080;
reg [15:0] udp_dst_port    = 16'd5001;

reg  [63:0] app_tx_axis_tdata  = 64'd0;
reg  [7:0]  app_tx_axis_tkeep  = 8'hff;
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

// NOTE: REQUEST_* are localparam in udp_stack_top and cannot be overridden;
// the real 2s/30s timers apply. Tests wait long enough for the default timing.
udp_stack_top UUT (
    .clk(clk),
    .rst(rst),
    .desc_axis_tvalid(desc_axis_tvalid),
    .desc_axis_tready(desc_axis_tready),
    .configuration_done(configuration_done),
    .src_ip_addr(src_ip_addr),
    .gateway_ip_addr(gateway_ip_addr),
    .subnet_mask(subnet_mask),
    .dst_ip_addr(dst_ip_addr),
    .src_mac_addr(src_mac_addr),
    .udp_src_port(udp_src_port),
    .udp_dst_port(udp_dst_port),
    .app_tx_axis_tdata(app_tx_axis_tdata),
    .app_tx_axis_tkeep(app_tx_axis_tkeep),
    .app_tx_axis_tvalid(app_tx_axis_tvalid),
    .app_tx_axis_tlast(app_tx_axis_tlast),
    .app_tx_axis_tready(app_tx_axis_tready),
    .app_rx_axis_tdata(app_rx_axis_tdata),
    .app_rx_axis_tkeep(app_rx_axis_tkeep),
    .app_rx_axis_tvalid(app_rx_axis_tvalid),
    .app_rx_axis_tlast(app_rx_axis_tlast),
    .app_rx_axis_tuser(app_rx_axis_tuser),
    .app_rx_axis_tready(app_rx_axis_tready),
    .mac_tx_axis_tdata(mac_tx_axis_tdata),
    .mac_tx_axis_tkeep(mac_tx_axis_tkeep),
    .mac_tx_axis_tvalid(mac_tx_axis_tvalid),
    .mac_tx_axis_tlast(mac_tx_axis_tlast),
    .mac_tx_axis_tuser(mac_tx_axis_tuser),
    .mac_tx_axis_tready(mac_tx_axis_tready),
    .mac_rx_axis_tdata(mac_rx_axis_tdata),
    .mac_rx_axis_tkeep(mac_rx_axis_tkeep),
    .mac_rx_axis_tvalid(mac_rx_axis_tvalid),
    .mac_rx_axis_tuser(mac_rx_axis_tuser),
    .mac_rx_axis_tready(mac_rx_axis_tready),
    .mac_rx_axis_tlast(mac_rx_axis_tlast)
);

task automatic check(input logic cond, input string msg);
    if (cond) $display("[%0t]   PASS: %0s", $time, msg);
    else begin
        fail_count = fail_count + 1;
        $display("[%0t]   FAIL: %0s", $time, msg);
    end
endtask

// inject raw frame bytes into mac_rx (1 beat/cycle, full handshake)
task automatic send_rx_frame(input byte b[$]);
    integer i, j, n;
begin
    @(negedge clk);
    for (i = 0; i < b.size(); i = i + 8) begin
        n = (b.size() - i) > 8 ? 8 : (b.size() - i);
        mac_rx_axis_tdata  <= 64'd0;
        for (j = 0; j < 8; j = j + 1)
            if (j < n) mac_rx_axis_tdata[j*8 +: 8] <= b[i + j];
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

// host ARP request, wire-padded to 64B -> MAC delivers 60B (FCS stripped)
task automatic send_host_arp_request_padded(input integer pad_len);
    byte f[$];
    integer i;
begin
    f.push_back(8'hff); f.push_back(8'hff); f.push_back(8'hff); f.push_back(8'hff); f.push_back(8'hff); f.push_back(8'hff);
    f.push_back(8'h00); f.push_back(8'h02); f.push_back(8'hc9); f.push_back(8'h53); f.push_back(8'hee); f.push_back(8'h10);
    f.push_back(8'h08); f.push_back(8'h06);
    f.push_back(8'h00); f.push_back(8'h01);   // HTYPE
    f.push_back(8'h08); f.push_back(8'h00);   // PTYPE
    f.push_back(8'h06); f.push_back(8'h04);   // HLEN / PLEN
    f.push_back(8'h00); f.push_back(8'h01);   // OPER = request
    f.push_back(8'h00); f.push_back(8'h02); f.push_back(8'hc9); f.push_back(8'h53); f.push_back(8'hee); f.push_back(8'h10);  // SHA
    f.push_back(8'hc0); f.push_back(8'ha8); f.push_back(8'h02); f.push_back(8'h0a);  // SPA
    f.push_back(8'h00); f.push_back(8'h00); f.push_back(8'h00); f.push_back(8'h00); f.push_back(8'h00); f.push_back(8'h00);  // THA
    f.push_back(8'hc0); f.push_back(8'ha8); f.push_back(8'h02); f.push_back(8'h23);  // TPA = FPGA
    for (i = 0; i < pad_len; i = i + 1)
        f.push_back(8'h00);
    $display("[%0t] RX-wire: host ARP request (%0d bytes incl. %0d pad)", $time, f.size(), pad_len);
    send_rx_frame(f);
end
endtask

// capture one TX frame
byte tx_bytes[$];
reg [47:0] tx_dst_mac, tx_src_mac;
reg [15:0] tx_type;

task automatic recv_tx_frame(input integer max_wait);
    integer lane;
    integer waited;
begin
    tx_bytes.delete();
    waited = 0;
    while (!(mac_tx_axis_tvalid && mac_tx_axis_tready)) begin
        @(posedge clk);
        waited = waited + 1;
        if (waited > max_wait) begin
            $display("[%0t]   (no TX frame within %0d cycles)", $time, max_wait);
            disable recv_tx_frame;
        end
    end
    forever begin
        for (lane = 0; lane < 8; lane = lane + 1)
            if (mac_tx_axis_tkeep[lane]) tx_bytes.push_back(mac_tx_axis_tdata[lane*8 +: 8]);
        if (mac_tx_axis_tlast) break;
        @(posedge clk);
        while (!(mac_tx_axis_tvalid && mac_tx_axis_tready)) @(posedge clk);
    end
    tx_dst_mac = {tx_bytes[0], tx_bytes[1], tx_bytes[2], tx_bytes[3], tx_bytes[4], tx_bytes[5]};
    tx_src_mac = {tx_bytes[6], tx_bytes[7], tx_bytes[8], tx_bytes[9], tx_bytes[10], tx_bytes[11]};
    tx_type    = {tx_bytes[12], tx_bytes[13]};
    $display("[%0t] TX-wire: dst=%02x:%02x:%02x:%02x:%02x:%02x src=%02x:%02x:%02x:%02x:%02x:%02x type=0x%04x len=%0d",
             $time, tx_dst_mac[47:40], tx_dst_mac[39:32], tx_dst_mac[31:24], tx_dst_mac[23:16], tx_dst_mac[15:8], tx_dst_mac[7:0],
             tx_src_mac[47:40], tx_src_mac[39:32], tx_src_mac[31:24], tx_src_mac[23:16], tx_src_mac[15:8], tx_src_mac[7:0],
             tx_type, tx_bytes.size());
end
endtask

task automatic verify_arp_reply(input string tag);
    reg [15:0] oper;
    integer k;
begin
    recv_tx_frame(2000);
    if (tx_bytes.size() == 0) begin
        $display("[%0t]   FAIL(%0s): no ARP reply emitted", $time, tag);
        fail_count = fail_count + 1;
    end else begin
        $write("[%0t]   frame:", $time);
        for (k = 0; k < tx_bytes.size(); k = k + 1) $write(" %02x", tx_bytes[k]);
        $write("\n");
        check(tx_type == 16'h0806, $sformatf("%0s: ethertype 0x0806", tag));
        check({tx_bytes[22], tx_bytes[23], tx_bytes[24], tx_bytes[25], tx_bytes[26], tx_bytes[27]} == FPGA_MAC,
              $sformatf("%0s: ARP SHA = FPGA MAC", tag));
        check({tx_bytes[28], tx_bytes[29], tx_bytes[30], tx_bytes[31]} == FPGA_IP,
              $sformatf("%0s: ARP SPA = FPGA IP", tag));
        oper = {tx_bytes[20], tx_bytes[21]};
        check(oper == 16'h0002, $sformatf("%0s: OPER = reply", tag));
        check({tx_bytes[32], tx_bytes[33], tx_bytes[34], tx_bytes[35], tx_bytes[36], tx_bytes[37]} == HOST_MAC,
              $sformatf("%0s: ARP THA = requester MAC", tag));
        check({tx_bytes[38], tx_bytes[39], tx_bytes[40], tx_bytes[41]} == HOST_IP,
              $sformatf("%0s: ARP TPA = requester IP", tag));
        check(tx_dst_mac == HOST_MAC, $sformatf("%0s: eth dst MAC = requester %02x:%02x:%02x:%02x:%02x:%02x (got %02x:%02x:%02x:%02x:%02x:%02x)",
             tag, HOST_MAC[47:40], HOST_MAC[39:32], HOST_MAC[31:24], HOST_MAC[23:16], HOST_MAC[15:8], HOST_MAC[7:0],
             tx_dst_mac[47:40], tx_dst_mac[39:32], tx_dst_mac[31:24], tx_dst_mac[23:16], tx_dst_mac[15:8], tx_dst_mac[7:0]));
    end
end
endtask

// host ARP reply answering the FPGA's resolution request (unpadded)
task automatic send_rx_frame_pool;
    byte f[$];
begin
    f.push_back(FPGA_MAC[47:40]); f.push_back(FPGA_MAC[39:32]); f.push_back(FPGA_MAC[31:24]);
    f.push_back(FPGA_MAC[23:16]); f.push_back(FPGA_MAC[15:8]);  f.push_back(FPGA_MAC[7:0]);
    f.push_back(HOST_MAC[47:40]); f.push_back(HOST_MAC[39:32]); f.push_back(HOST_MAC[31:24]);
    f.push_back(HOST_MAC[23:16]); f.push_back(HOST_MAC[15:8]);  f.push_back(HOST_MAC[7:0]);
    f.push_back(8'h08); f.push_back(8'h06);
    f.push_back(8'h00); f.push_back(8'h01);   // HTYPE
    f.push_back(8'h08); f.push_back(8'h00);   // PTYPE
    f.push_back(8'h06); f.push_back(8'h04);   // HLEN / PLEN
    f.push_back(8'h00); f.push_back(8'h02);   // OPER = reply
    f.push_back(HOST_MAC[47:40]); f.push_back(HOST_MAC[39:32]); f.push_back(HOST_MAC[31:24]);
    f.push_back(HOST_MAC[23:16]); f.push_back(HOST_MAC[15:8]);  f.push_back(HOST_MAC[7:0]);
    f.push_back(HOST_IP[31:24]); f.push_back(HOST_IP[23:16]); f.push_back(HOST_IP[15:8]); f.push_back(HOST_IP[7:0]);
    f.push_back(FPGA_MAC[47:40]); f.push_back(FPGA_MAC[39:32]); f.push_back(FPGA_MAC[31:24]);
    f.push_back(FPGA_MAC[23:16]); f.push_back(FPGA_MAC[15:8]);  f.push_back(FPGA_MAC[7:0]);
    f.push_back(FPGA_IP[31:24]); f.push_back(FPGA_IP[23:16]); f.push_back(FPGA_IP[15:8]); f.push_back(FPGA_IP[7:0]);
    $display("[%0t] RX-wire: host ARP reply (42 bytes)", $time);
    send_rx_frame(f);
end
endtask

initial begin
    repeat (6) @(posedge clk);
    rst <= 1'b0;
    repeat (4) @(posedge clk);

    // ============ test A: padded request right after reset, no config = ====
    $display("[%0t] ===== test A: padded host ARP request, unconfigured =====", $time);
    send_host_arp_request_padded(18);
    verify_arp_reply("A padded");

    // ============ test B: unpadded request (TB-style) for reference ============
    $display("[%0t] ===== test B: unpadded host ARP request =====", $time);
    send_host_arp_request_padded(0);
    verify_arp_reply("B unpadded");

    // ============ test C: padded request again (state after B) ============
    $display("[%0t] ===== test C: padded request after unpadded =====", $time);
    send_host_arp_request_padded(18);
    verify_arp_reply("C padded");

    // ============ test D: hardware flow - configure, FPGA resolves host,
    //             then host sends padded request ============
    $display("[%0t] ===== test D: configure via descriptor, then padded request =====", $time);
    fork
        begin : d_cfg
            @(negedge clk);
            desc_axis_tvalid <= 1'b1;
            @(negedge clk);
            while (desc_axis_tready !== 1'b1) @(negedge clk);
            @(negedge clk);
            desc_axis_tvalid <= 1'b0;
        end
        begin : d_req
            // FPGA emits its own ARP request for the host; reply to it
            recv_tx_frame(100000);
            $display("[%0t]   (FPGA's own ARP request seen, len=%0d)", $time, tx_bytes.size());
            send_rx_frame_pool;
        end
    join
    // host's padded request now
    send_host_arp_request_padded(18);
    verify_arp_reply("D padded after config");

    // ============ summary ============
    $display("[%0t] ============ SUMMARY: fail = %0d ============", $time, fail_count);
    if (fail_count == 0) $display("=== ALL TESTS PASSED ===");
    else $display("=== FAILED ===");
    $finish;
end

initial begin
    #1000000;
    $display("GLOBAL TIMEOUT");
    $finish;
end

endmodule
`resetall
