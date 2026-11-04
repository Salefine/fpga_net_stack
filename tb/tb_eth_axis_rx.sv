`timescale 1ns / 1ps

module tb_eth_axis_rx;

localparam DATA_WIDTH = 64;
localparam KEEP_WIDTH = DATA_WIDTH/8;

localparam [47:0] DST_MAC = 48'h00_0a_35_74_85_62;
localparam [47:0] SRC_MAC = 48'h00_0a_35_74_56_12;
localparam [31:0] DST_IP = 32'hc0_a8_01_14; // 192.168.1.20
localparam [31:0] SRC_IP = 32'hc0_a8_01_4a; // 192.168.1.74
localparam [15:0] DST_PORT = 16'd8080;
localparam [15:0] SRC_PORT = 16'd40000;

reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;

reg [DATA_WIDTH-1:0] s_axis_tdata = 0;
reg [KEEP_WIDTH-1:0] s_axis_tkeep = 0;
reg s_axis_tvalid = 0;
wire s_axis_tready;
reg s_axis_tlast = 0;
reg s_axis_tuser = 0;

wire [47:0] m_eth_dest_mac;
wire [47:0] m_eth_src_mac;
wire [15:0] m_eth_type;
wire [DATA_WIDTH-1:0] m_eth_payload_axis_tdata;
wire [KEEP_WIDTH-1:0] m_eth_payload_axis_tkeep;
wire m_eth_payload_axis_tvalid;
reg m_eth_payload_axis_tready = 1'b1;
wire m_eth_payload_axis_tlast;
wire m_eth_payload_axis_tuser;
wire busy;
wire error_header_early_termination;

eth_axis_rx_v1 #(
    .DATA_WIDTH(DATA_WIDTH),
    .KEEP_ENABLE(1),
    .KEEP_WIDTH(KEEP_WIDTH)
)
dut (
    .clk(clk),
    .rst(rst),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .m_eth_dest_mac(m_eth_dest_mac),
    .m_eth_src_mac(m_eth_src_mac),
    .m_eth_type(m_eth_type),
    .m_eth_payload_axis_tdata(m_eth_payload_axis_tdata),
    .m_eth_payload_axis_tkeep(m_eth_payload_axis_tkeep),
    .m_eth_payload_axis_tvalid(m_eth_payload_axis_tvalid),
    .m_eth_payload_axis_tready(m_eth_payload_axis_tready),
    .m_eth_payload_axis_tlast(m_eth_payload_axis_tlast),
    .m_eth_payload_axis_tuser(m_eth_payload_axis_tuser),
    .busy(busy),
    .error_header_early_termination(error_header_early_termination)
);

reg [7:0] frame_mem [0:511];
reg [7:0] received_payload [0:511];
integer frame_len = 0;
integer received_count = 0;
integer received_frames = 0;
integer error_count = 0;
reg expect_tuser = 0;
reg saw_payload_tuser = 0;

always @(posedge clk) begin
    if (!rst) begin
        if (m_eth_payload_axis_tvalid && m_eth_payload_axis_tready) begin
            for (integer lane = 0; lane < KEEP_WIDTH; lane = lane + 1) begin
                if (m_eth_payload_axis_tkeep[lane]) begin
                    received_payload[received_count] =
                        m_eth_payload_axis_tdata[lane*8 +: 8];
                    received_count = received_count + 1;
                end
            end

            if (m_eth_payload_axis_tuser) begin
                saw_payload_tuser = 1'b1;
                if (!expect_tuser) begin
                    $display("[%0t] FAIL: unexpected payload tuser error", $time);
                    error_count = error_count + 1;
                end
            end

            if (m_eth_payload_axis_tlast)
                received_frames = received_frames + 1;
        end

        if (error_header_early_termination) begin
            $display("[%0t] FAIL: unexpected early Ethernet header termination", $time);
            error_count = error_count + 1;
        end
    end
end

task automatic build_frame(input string app_text);
    integer i;
    integer sum;
    integer checksum;
    integer ip_len;
    integer udp_len;
    begin
        ip_len = 20 + 8 + app_text.len();
        udp_len = 8 + app_text.len();
        frame_len = 14 + ip_len;

        // Ethernet header
        frame_mem[0] = DST_MAC[47:40];
        frame_mem[1] = DST_MAC[39:32];
        frame_mem[2] = DST_MAC[31:24];
        frame_mem[3] = DST_MAC[23:16];
        frame_mem[4] = DST_MAC[15:8];
        frame_mem[5] = DST_MAC[7:0];
        frame_mem[6] = SRC_MAC[47:40];
        frame_mem[7] = SRC_MAC[39:32];
        frame_mem[8] = SRC_MAC[31:24];
        frame_mem[9] = SRC_MAC[23:16];
        frame_mem[10] = SRC_MAC[15:8];
        frame_mem[11] = SRC_MAC[7:0];
        frame_mem[12] = 8'h08;
        frame_mem[13] = 8'h00;

        // IPv4 header
        frame_mem[14] = 8'h45;
        frame_mem[15] = 8'h00;
        frame_mem[16] = ip_len >> 8;
        frame_mem[17] = ip_len;
        frame_mem[18] = 8'h00;
        frame_mem[19] = 8'h01;
        frame_mem[20] = 8'h40;
        frame_mem[21] = 8'h00;
        frame_mem[22] = 8'h40;
        frame_mem[23] = 8'h11;
        frame_mem[24] = 8'h00;
        frame_mem[25] = 8'h00;
        frame_mem[26] = SRC_IP[31:24];
        frame_mem[27] = SRC_IP[23:16];
        frame_mem[28] = SRC_IP[15:8];
        frame_mem[29] = SRC_IP[7:0];
        frame_mem[30] = DST_IP[31:24];
        frame_mem[31] = DST_IP[23:16];
        frame_mem[32] = DST_IP[15:8];
        frame_mem[33] = DST_IP[7:0];

        sum = 0;
        for (i = 14; i < 34; i = i + 2)
            sum = sum + {frame_mem[i], frame_mem[i+1]};
        sum = (sum & 16'hffff) + (sum >> 16);
        sum = (sum & 16'hffff) + (sum >> 16);
        checksum = (~sum) & 16'hffff;
        frame_mem[24] = checksum >> 8;
        frame_mem[25] = checksum;

        // UDP header; UDP checksum zero means "not supplied" in IPv4.
        frame_mem[34] = SRC_PORT[15:8];
        frame_mem[35] = SRC_PORT[7:0];
        frame_mem[36] = DST_PORT[15:8];
        frame_mem[37] = DST_PORT[7:0];
        frame_mem[38] = udp_len >> 8;
        frame_mem[39] = udp_len;
        frame_mem[40] = 8'h00;
        frame_mem[41] = 8'h00;

        for (i = 0; i < app_text.len(); i = i + 1)
            frame_mem[42+i] = app_text[i];
    end
endtask

task automatic send_frame(input reg apply_backpressure, input reg apply_tuser);
    integer beat;
    integer lane;
    integer beat_count;
    integer byte_index;
    integer stall_cycle;
    reg stall_seen;
    reg [DATA_WIDTH-1:0] beat_data;
    reg [KEEP_WIDTH-1:0] beat_keep;
    reg beat_last;
    reg beat_user;
    begin
        stall_seen = 1'b0;
        beat_count = (frame_len + KEEP_WIDTH - 1) / KEEP_WIDTH;
        for (beat = 0; beat < beat_count; beat = beat + 1) begin
            @(negedge clk);
            beat_data = 0;
            beat_keep = 0;
            for (lane = 0; lane < KEEP_WIDTH; lane = lane + 1) begin
                byte_index = beat*KEEP_WIDTH + lane;
                if (byte_index < frame_len) begin
                    beat_data[lane*8 +: 8] = frame_mem[byte_index];
                    beat_keep[lane] = 1'b1;
                end
            end

            beat_last = (beat == beat_count - 1);
            beat_user = apply_tuser && beat_last;

            s_axis_tdata = beat_data;
            s_axis_tkeep = beat_keep;
            s_axis_tvalid = 1'b1;
            s_axis_tlast = beat_last;
            s_axis_tuser = beat_user;

            if (apply_backpressure && beat == 4)
                m_eth_payload_axis_tready = 1'b0;

            while (s_axis_tready !== 1'b1) begin
                if (apply_backpressure && !stall_seen) begin
                    stall_seen = 1'b1;
                    $display("[%0t] Observed s_axis_tready low; checking source hold", $time);
                    for (stall_cycle = 0; stall_cycle < 3; stall_cycle = stall_cycle + 1) begin
                        @(posedge clk);
                        if (s_axis_tready !== 1'b0 ||
                                s_axis_tvalid !== 1'b1 ||
                                s_axis_tdata !== beat_data ||
                                s_axis_tkeep !== beat_keep ||
                                s_axis_tlast !== beat_last ||
                                s_axis_tuser !== beat_user) begin
                            $display("[%0t] FAIL: AXI input was not held stable during backpressure",
                                     $time);
                            error_count = error_count + 1;
                        end
                    end
                    @(negedge clk);
                    m_eth_payload_axis_tready = 1'b1;
                end else begin
                    @(negedge clk);
                end
            end

            @(posedge clk);
        end

        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast = 1'b0;
        s_axis_tuser = 1'b0;
        s_axis_tkeep = 0;
        m_eth_payload_axis_tready = 1'b1;

        if (apply_backpressure && !stall_seen) begin
            $display("[%0t] FAIL: expected s_axis_tready to deassert under backpressure", $time);
            error_count = error_count + 1;
        end else if (apply_backpressure) begin
            $display("[%0t] PASS: s_axis_tready deasserted and input stayed stable", $time);
        end
    end
endtask

task automatic run_case(input string app_text, input reg apply_backpressure,
                        input reg apply_tuser);
    integer expected_payload_len;
    integer previous_frames;
    integer i;
    begin
        if (apply_tuser)
            $display("[%0t] Sending UDP payload: \"%0s\" (s_axis_tuser=1 on last beat)", $time, app_text);
        else
            $display("[%0t] Sending UDP payload: \"%0s\"", $time, app_text);
        build_frame(app_text);
        expected_payload_len = frame_len - 14;
        received_count = 0;
        saw_payload_tuser = 1'b0;
        expect_tuser = apply_tuser;
        previous_frames = received_frames;

        send_frame(apply_backpressure, apply_tuser);
        wait (received_frames == previous_frames + 1);
        #1;

        if (apply_tuser && !saw_payload_tuser) begin
            $display("[%0t] FAIL: expected payload tuser to be asserted", $time);
            error_count = error_count + 1;
        end
        expect_tuser = 1'b0;

        if (m_eth_dest_mac !== DST_MAC ||
                m_eth_src_mac !== SRC_MAC ||
                m_eth_type !== 16'h0800) begin
            $display("[%0t] FAIL: unexpected Ethernet header dst=%h src=%h type=%h",
                     $time, m_eth_dest_mac, m_eth_src_mac, m_eth_type);
            error_count = error_count + 1;
        end

        if (received_count != expected_payload_len) begin
            $display("[%0t] FAIL: expected %0d output bytes, got %0d",
                     $time, expected_payload_len, received_count);
            error_count = error_count + 1;
        end else begin
            for (i = 0; i < expected_payload_len; i = i + 1) begin
                if (received_payload[i] !== frame_mem[14+i]) begin
                    $display("[%0t] FAIL: payload byte %0d expected %02x got %02x",
                             $time, i, frame_mem[14+i], received_payload[i]);
                    error_count = error_count + 1;
                end
            end
        end

        if (received_payload[12] !== SRC_IP[31:24] ||
                received_payload[13] !== SRC_IP[23:16] ||
                received_payload[14] !== SRC_IP[15:8] ||
                received_payload[15] !== SRC_IP[7:0] ||
                received_payload[16] !== DST_IP[31:24] ||
                received_payload[17] !== DST_IP[23:16] ||
                received_payload[18] !== DST_IP[15:8] ||
                received_payload[19] !== DST_IP[7:0] ||
                received_payload[22] !== DST_PORT[15:8] ||
                received_payload[23] !== DST_PORT[7:0]) begin
            $display("[%0t] FAIL: returned packet has incorrect IP address or UDP destination port",
                     $time);
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("[%0t] PASS: packet and application data received correctly", $time);
    end
endtask

initial begin
    repeat (5) @(posedge clk);
    rst = 1'b0;
    repeat (2) @(posedge clk);

    run_case("hello", 1'b0, 1'b0);
    run_case("world", 1'b0, 1'b0);
    run_case("hello, world", 1'b0, 1'b0);
    run_case("Any chars: !@#$%^&*()_+-=[]{};':,./? 0123456789", 1'b1, 1'b0);
    run_case("bad frame", 1'b0, 1'b1);

    if (error_count == 0) begin
        $display("TEST PASS: all eth_axis_rx receive cases passed");
        $finish;
    end else begin
        $display("TEST FAIL: %0d error(s)", error_count);
        $fatal(1);
    end
end

initial begin
    #100000;
    $fatal(1, "TEST TIMEOUT");
end

endmodule
