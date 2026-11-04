`timescale 1ns / 1ps

module tb_axis_arb_mux;

localparam DATA_WIDTH = 64;
localparam KEEP_WIDTH = 8;
localparam ID_WIDTH = 4;
localparam DEST_WIDTH = 4;
localparam USER_WIDTH = 1;
localparam EXPECTED_BEATS = 11;

reg clk = 1'b0;
reg rst = 1'b1;

reg [2*DATA_WIDTH-1:0] s_axis_tdata = 0;
reg [2*KEEP_WIDTH-1:0] s_axis_tkeep = 0;
reg [1:0] s_axis_tvalid = 0;
wire [1:0] s_axis_tready;
reg [1:0] s_axis_tlast = 0;
reg [2*ID_WIDTH-1:0] s_axis_tid = 0;
reg [2*DEST_WIDTH-1:0] s_axis_tdest = 0;
reg [2*USER_WIDTH-1:0] s_axis_tuser = 0;

wire [DATA_WIDTH-1:0] m_axis_tdata;
wire [KEEP_WIDTH-1:0] m_axis_tkeep;
wire m_axis_tvalid;
reg m_axis_tready = 1'b1;
wire m_axis_tlast;
wire [ID_WIDTH-1:0] m_axis_tid;
wire [DEST_WIDTH-1:0] m_axis_tdest;
wire [USER_WIDTH-1:0] m_axis_tuser;

reg [7:0] expected_data [0:EXPECTED_BEATS-1];
reg expected_last [0:EXPECTED_BEATS-1];
reg [ID_WIDTH-1:0] expected_id [0:EXPECTED_BEATS-1];
reg [DEST_WIDTH-1:0] expected_dest [0:EXPECTED_BEATS-1];
reg expected_user [0:EXPECTED_BEATS-1];
integer received_beats = 0;
integer i;
integer beat;

always #5 clk = ~clk;

axis_arb_mux #(
    .S_COUNT(2),
    .DATA_WIDTH(DATA_WIDTH),
    .KEEP_ENABLE(1),
    .KEEP_WIDTH(KEEP_WIDTH),
    .ID_ENABLE(1),
    .ID_WIDTH(ID_WIDTH),
    .DEST_ENABLE(1),
    .DEST_WIDTH(DEST_WIDTH),
    .USER_ENABLE(1),
    .USER_WIDTH(USER_WIDTH),
    .ARB_TYPE_ROUND_ROBIN(0),
    .ARB_LSB_HIGH_PRIORITY(1)
)
 dut (
    .clk(clk),
    .rst(rst),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tid(s_axis_tid),
    .s_axis_tdest(s_axis_tdest),
    .s_axis_tuser(s_axis_tuser),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tid(m_axis_tid),
    .m_axis_tdest(m_axis_tdest),
    .m_axis_tuser(m_axis_tuser)
);

always @(posedge clk) begin
    if (!rst && m_axis_tvalid && m_axis_tready) begin
        if (received_beats >= EXPECTED_BEATS) begin
            $fatal(1, "Received more than %0d output beats", EXPECTED_BEATS);
        end
        if (m_axis_tdata !== expected_data[received_beats] ||
                m_axis_tkeep !== {KEEP_WIDTH{1'b1}} ||
                m_axis_tlast !== expected_last[received_beats] ||
                m_axis_tid !== expected_id[received_beats] ||
                m_axis_tdest !== expected_dest[received_beats] ||
                m_axis_tuser !== expected_user[received_beats]) begin
            $display("Mismatch at output beat %0d: data=%h keep=%b last=%b id=%h dest=%h user=%b",
                received_beats, m_axis_tdata, m_axis_tkeep, m_axis_tlast,
                m_axis_tid, m_axis_tdest, m_axis_tuser);
            $display("Expected: data=%h keep=%b last=%b id=%h dest=%h user=%b",
                expected_data[received_beats], {KEEP_WIDTH{1'b1}},
                expected_last[received_beats], expected_id[received_beats],
                expected_dest[received_beats], expected_user[received_beats]);
            $fatal(1, "AXI-Stream output mismatch");
        end
        received_beats = received_beats + 1;
    end
end

task automatic send_frame;
    input integer port;
    input [7:0] first_data;
    input integer beat_count;
    integer n;
    begin
        for (n = 0; n < beat_count; n = n + 1) begin
            @(negedge clk);
            s_axis_tdata[port*DATA_WIDTH +: DATA_WIDTH] = first_data + n;
            s_axis_tkeep[port*KEEP_WIDTH +: KEEP_WIDTH] = {KEEP_WIDTH{1'b1}};
            s_axis_tlast[port] = (n == beat_count-1);
            s_axis_tid[port*ID_WIDTH +: ID_WIDTH] = port + 1;
            s_axis_tdest[port*DEST_WIDTH +: DEST_WIDTH] = port + 9;
            s_axis_tuser[port*USER_WIDTH +: USER_WIDTH] = (n == beat_count-1);
            s_axis_tvalid[port] = 1'b1;
            do begin
                @(posedge clk);
            end while (!s_axis_tready[port]);
        end
        @(negedge clk);
        s_axis_tvalid[port] = 1'b0;
        s_axis_tlast[port] = 1'b0;
    end
endtask

initial begin
    // Expected order: A alone, B alone, then A followed by B on a tie.
    for (i = 0; i < 3; i = i + 1) begin
        expected_data[i] = 8'h10 + i;
        expected_last[i] = (i == 2);
        expected_id[i] = 1;
        expected_dest[i] = 9;
        expected_user[i] = (i == 2);
    end
    for (i = 0; i < 2; i = i + 1) begin
        expected_data[3+i] = 8'h20 + i;
        expected_last[3+i] = (i == 1);
        expected_id[3+i] = 2;
        expected_dest[3+i] = 10;
        expected_user[3+i] = (i == 1);
    end
    for (i = 0; i < 3; i = i + 1) begin
        expected_data[5+i] = 8'hA0 + i;
        expected_last[5+i] = (i == 2);
        expected_id[5+i] = 1;
        expected_dest[5+i] = 9;
        expected_user[5+i] = (i == 2);

        expected_data[8+i] = 8'hB0 + i;
        expected_last[8+i] = (i == 2);
        expected_id[8+i] = 2;
        expected_dest[8+i] = 10;
        expected_user[8+i] = (i == 2);
    end

    repeat (3) @(negedge clk);
    rst = 1'b0;

    // 1. A sends a frame while B is idle; stall its first beat.
    m_axis_tready = 1'b0;
    fork
        send_frame(0, 8'h10, 3);
        begin
            repeat (4) @(posedge clk);
            @(negedge clk);
            m_axis_tready = 1'b1;
        end
    join
    repeat (3) @(posedge clk);

    // 2. B sends a frame while A is idle.
    send_frame(1, 8'h20, 2);
    repeat (3) @(posedge clk);

    // 3. Both request together. A has higher fixed priority, and B must
    // remain pending until A's complete frame has transferred.
    fork
        send_frame(0, 8'hA0, 3);
        send_frame(1, 8'hB0, 3);
    join

    wait (received_beats == EXPECTED_BEATS);
    repeat (3) @(posedge clk);
    if (received_beats != EXPECTED_BEATS) begin
        $fatal(1, "Expected %0d output beats, received %0d",
            EXPECTED_BEATS, received_beats);
    end

    $display("PASS: A-only, B-only, and simultaneous-input cases (%0d beats)",
        received_beats);
    $finish;
end

initial begin
    #10000;
    $fatal(1, "Simulation timed out");
end

endmodule
