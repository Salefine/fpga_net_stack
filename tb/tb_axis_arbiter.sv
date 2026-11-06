`timescale 1ns / 1ps

/*
 * Testbench for axis_arbiter
 *
 * Two input ports (A = port 0, the high priority port, B = port 1) and one
 * output.  Every frame carries a self describing data pattern
 *   tdata = { 8'h10 + port, frame_index[7:0], beat_index[15:0], 32'h0 }
 * so the checker can prove that
 *   - no frames are interleaved (a frame of one port is never mixed with
 *     another port, and the beats of a frame stay in order),
 *   - the frames of each port leave in the order they were submitted,
 *   - tkeep/tlast/tid/tdest/tuser are forwarded untouched,
 *   - no beat is lost or duplicated.
 *
 * Cases
 *   1. A sends one 256 byte frame, B idle.
 *   2. B sends one 1024 byte frame, A idle.
 *   3. A (512 bytes) and B (1024 bytes) start at the same time, so A must
 *      finish first: strict priority.
 *   4. A (1024 bytes) and B (512 bytes) start at the same time: A must
 *      finish first even though B is shorter.
 *   5. A sends 5 back to back 1024 byte frames while B sends 8 back to back
 *      512 byte frames.  A wins STARVE_LIMIT frames in a row, then B is
 *      forced through, so B is never starved.
 *
 * The output side is back pressured with random gaps in cases 3..5 to
 * exercise the output skid buffer.
 */
module tb_axis_arbiter;

localparam S_COUNT        = 2;
localparam DATA_WIDTH     = 64;
localparam KEEP_WIDTH     = 8;
localparam ID_WIDTH       = 4;
localparam DEST_WIDTH     = 4;
localparam USER_WIDTH     = 1;
localparam STARVE_LIMIT   = 4;
localparam BYTES_PER_BEAT = DATA_WIDTH / 8;
localparam MAX_FRAMES     = 32;

localparam PORT_A = 0;
localparam PORT_B = 1;

localparam LEN_256  = 256;
localparam LEN_512  = 512;
localparam LEN_1024 = 1024;

reg clk = 1'b0;
reg rst = 1'b1;

reg  [S_COUNT*DATA_WIDTH-1:0]   s_axis_tdata  = {S_COUNT*DATA_WIDTH{1'b0}};
reg  [S_COUNT*KEEP_WIDTH-1:0]   s_axis_tkeep  = {S_COUNT*KEEP_WIDTH{1'b0}};
reg  [S_COUNT-1:0]              s_axis_tvalid = {S_COUNT{1'b0}};
wire [S_COUNT-1:0]              s_axis_tready;
reg  [S_COUNT-1:0]              s_axis_tlast  = {S_COUNT{1'b0}};
reg  [S_COUNT*ID_WIDTH-1:0]     s_axis_tid    = {S_COUNT*ID_WIDTH{1'b0}};
reg  [S_COUNT*DEST_WIDTH-1:0]   s_axis_tdest  = {S_COUNT*DEST_WIDTH{1'b0}};
reg  [S_COUNT*USER_WIDTH-1:0]   s_axis_tuser  = {S_COUNT*USER_WIDTH{1'b0}};

wire [DATA_WIDTH-1:0]           m_axis_tdata;
wire [KEEP_WIDTH-1:0]           m_axis_tkeep;
wire                            m_axis_tvalid;
reg                             m_axis_tready = 1'b1;
wire                            m_axis_tlast;
wire [ID_WIDTH-1:0]             m_axis_tid;
wire [DEST_WIDTH-1:0]           m_axis_tdest;
wire [USER_WIDTH-1:0]           m_axis_tuser;

integer i;

// bookkeeping
integer n_frames;
integer frame_order [0:MAX_FRAMES-1];
integer exp_order   [0:MAX_FRAMES-1];
integer exp_len;
integer errors;

integer beats_in;
integer exp_beats_total;

integer next_frame  [0:S_COUNT-1];
integer frames_seen [0:S_COUNT-1];
integer exp_beats   [0:S_COUNT-1][0:MAX_FRAMES-1];

integer cur_port;
integer cur_frame;
integer cur_beat;

integer s_base;
integer chk_p;
integer chk_f;
integer chk_b;

always #5 clk = ~clk;

axis_arbiter #(
    .S_COUNT               (S_COUNT      ),
    .DATA_WIDTH            (DATA_WIDTH   ),
    .KEEP_ENABLE           (1            ),
    .KEEP_WIDTH            (KEEP_WIDTH   ),
    .ID_ENABLE             (1            ),
    .ID_WIDTH              (ID_WIDTH     ),
    .DEST_ENABLE           (1            ),
    .DEST_WIDTH            (DEST_WIDTH   ),
    .USER_ENABLE           (1            ),
    .USER_WIDTH            (USER_WIDTH   ),
    .ARB_LSB_HIGH_PRIORITY (1            ),
    .STARVE_LIMIT          (STARVE_LIMIT )
)
dut (
    .clk(clk),
    .rst(rst),

    .s_axis_tdata (s_axis_tdata ),
    .s_axis_tkeep (s_axis_tkeep ),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast (s_axis_tlast ),
    .s_axis_tid   (s_axis_tid   ),
    .s_axis_tdest (s_axis_tdest ),
    .s_axis_tuser (s_axis_tuser ),

    .m_axis_tdata (m_axis_tdata ),
    .m_axis_tkeep (m_axis_tkeep ),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast (m_axis_tlast ),
    .m_axis_tid   (m_axis_tid   ),
    .m_axis_tdest (m_axis_tdest ),
    .m_axis_tuser (m_axis_tuser )
);

/*
 * Output back pressure: random gaps, enabled for the contended cases
 */
reg stall_en = 1'b0;

always @(posedge clk) begin
    if (rst) begin
        m_axis_tready <= 1'b1;
    end else if (stall_en) begin
        m_axis_tready <= (($random % 4) != 0);
    end else begin
        m_axis_tready <= 1'b1;
    end
end

/*
 * Frame source, records the length of every frame it submits.
 * Consecutive frames of a burst are driven without dropping tvalid, i.e.
 * a burst is a continuous stream of frames.
 */
task automatic send_burst(input integer port, input integer count, input integer nbytes);
    integer f;
    integer n;
    integer frame;
    integer beats;
    begin
        beats = nbytes / BYTES_PER_BEAT;
        for (f = 0; f < count; f = f + 1) begin
            frame = next_frame[port];
            exp_beats[port][frame] = beats;
            next_frame[port] = frame + 1;
            for (n = 0; n < beats; n = n + 1) begin
                @(negedge clk);
                s_axis_tdata[port*DATA_WIDTH +: DATA_WIDTH] =
                    {8'h10 + port[7:0], frame[7:0], n[15:0], 32'h0};
                s_axis_tkeep[port*KEEP_WIDTH +: KEEP_WIDTH] = {KEEP_WIDTH{1'b1}};
                s_axis_tlast[port] = (n == (beats-1));
                s_axis_tuser[port*USER_WIDTH +: USER_WIDTH] = (n == (beats-1));
                s_axis_tid[port*ID_WIDTH +: ID_WIDTH] = port[ID_WIDTH-1:0] + 1'b1;
                s_axis_tdest[port*DEST_WIDTH +: DEST_WIDTH] = 9 + port;
                s_axis_tvalid[port] = 1'b1;
                do begin
                    @(posedge clk);
                end while (!s_axis_tready[port]);
            end
        end
        @(negedge clk);
        s_axis_tvalid[port] = 1'b0;
        s_axis_tlast[port]  = 1'b0;
        s_axis_tuser[port*USER_WIDTH +: USER_WIDTH] = 1'b0;
    end
endtask

/*
 * Output checker
 */
always @(posedge clk) begin
    if (!rst && m_axis_tvalid && m_axis_tready) begin
        chk_p = m_axis_tdata[63:56] - 8'h10;
        chk_f = m_axis_tdata[55:48];
        chk_b = m_axis_tdata[47:32];

        beats_in = beats_in + 1;

        if (chk_p < 0 || chk_p >= S_COUNT) begin
            $display("ERROR: bad port tag %0d in output beat %0d", chk_p, beats_in);
            errors = errors + 1;
        end else if (chk_b == 0) begin
            // first beat of an output frame
            if (cur_port >= 0) begin
                $display("ERROR: frame of port %0d truncated after %0d beats",
                    cur_port, cur_beat);
                errors = errors + 1;
            end
            if (chk_f != frames_seen[chk_p]) begin
                $display("ERROR: port %0d frame %0d received out of order (expected %0d)",
                    chk_p, chk_f, frames_seen[chk_p]);
                errors = errors + 1;
            end
            if (n_frames >= MAX_FRAMES) begin
                $display("ERROR: too many output frames");
                errors = errors + 1;
            end else begin
                frame_order[n_frames] = chk_p;
                n_frames = n_frames + 1;
            end
            cur_port  = chk_p;
            cur_frame = chk_f;
            cur_beat  = 0;
            frames_seen[chk_p] = frames_seen[chk_p] + 1;
        end else begin
            // mid frame beat
            if (chk_p != cur_port || chk_f != cur_frame) begin
                $display("ERROR: frame interleaved: port %0d frame %0d followed by port %0d frame %0d",
                    cur_port, cur_frame, chk_p, chk_f);
                errors = errors + 1;
            end
            if (chk_b != cur_beat) begin
                $display("ERROR: port %0d frame %0d beat %0d out of sequence (expected %0d)",
                    chk_p, chk_f, chk_b, cur_beat);
                errors = errors + 1;
            end
        end

        if (m_axis_tkeep !== {KEEP_WIDTH{1'b1}}) begin
            $display("ERROR: tkeep corrupted on port %0d frame %0d beat %0d", chk_p, chk_f, chk_b);
            errors = errors + 1;
        end
        if (m_axis_tid !== ((chk_p + 1) & ((1 << ID_WIDTH) - 1))) begin
            $display("ERROR: tid corrupted on port %0d frame %0d beat %0d", chk_p, chk_f, chk_b);
            errors = errors + 1;
        end
        if (m_axis_tdest !== ((9 + chk_p) & ((1 << DEST_WIDTH) - 1))) begin
            $display("ERROR: tdest corrupted on port %0d frame %0d beat %0d", chk_p, chk_f, chk_b);
            errors = errors + 1;
        end
        if (m_axis_tlast !== (chk_b == (exp_beats[chk_p][chk_f] - 1))) begin
            $display("ERROR: tlast wrong on port %0d frame %0d beat %0d", chk_p, chk_f, chk_b);
            errors = errors + 1;
        end
        if (m_axis_tuser !== m_axis_tlast) begin
            $display("ERROR: tuser wrong on port %0d frame %0d beat %0d", chk_p, chk_f, chk_b);
            errors = errors + 1;
        end

        cur_beat = cur_beat + 1;

        if (m_axis_tlast) begin
            if (cur_beat != exp_beats[chk_p][chk_f]) begin
                $display("ERROR: port %0d frame %0d has %0d beats, expected %0d",
                    chk_p, chk_f, cur_beat, exp_beats[chk_p][chk_f]);
                errors = errors + 1;
            end
            cur_port = -1;
        end
    end
end

/*
 * Helpers
 */
task automatic wait_drain;
    integer guard;
    begin
        guard = 0;
        while ((beats_in < exp_beats_total) && (guard < 40000)) begin
            @(posedge clk);
            guard = guard + 1;
        end
        repeat (10) @(posedge clk);
        if (beats_in != exp_beats_total) begin
            $display("ERROR: expected %0d output beats in total, received %0d",
                exp_beats_total, beats_in);
            errors = errors + 1;
        end
    end
endtask

task automatic expect_frame(input integer port, input integer nbytes);
    begin
        exp_beats_total = exp_beats_total + (nbytes / BYTES_PER_BEAT);
    end
endtask

task automatic print_order(input integer base, input integer len);
    integer j;
    begin
        $write("  output frame order:");
        for (j = 0; j < len; j = j + 1) begin
            if (j < MAX_FRAMES && (base+j) < n_frames) begin
                $write(" %s", (frame_order[base+j] == PORT_A) ? "A" : "B");
            end
        end
        $write("\n");
    end
endtask

task automatic check_order(input integer base);
    integer j;
    begin
        for (j = 0; j < exp_len; j = j + 1) begin
            if ((base+j) >= n_frames) begin
                $display("ERROR: missing output frame %0d (expected port %s)",
                    base+j, (exp_order[j] == PORT_A) ? "A" : "B");
                errors = errors + 1;
            end else if (frame_order[base+j] !== exp_order[j]) begin
                $display("ERROR: output frame %0d came from port %s, expected port %s",
                    base+j, (frame_order[base+j] == PORT_A) ? "A" : "B",
                    (exp_order[j] == PORT_A) ? "A" : "B");
                errors = errors + 1;
            end
        end
        if ((n_frames - base) != exp_len) begin
            $display("ERROR: %0d output frames in this case, expected %0d",
                n_frames - base, exp_len);
            errors = errors + 1;
        end
    end
endtask

task automatic check_counts;
    integer j;
    begin
        for (j = 0; j < S_COUNT; j = j + 1) begin
            if (frames_seen[j] !== next_frame[j]) begin
                $display("ERROR: port %0d delivered %0d frames, expected %0d",
                    j, frames_seen[j], next_frame[j]);
                errors = errors + 1;
            end
        end
    end
endtask

task automatic check_max_run(input integer base, input integer len, input integer max_run);
    integer j;
    integer run;
    integer best;
    begin
        run = 0;
        best = 0;
        for (j = 0; j < len; j = j + 1) begin
            if ((base+j) < n_frames && frame_order[base+j] == PORT_A) begin
                run = run + 1;
                if (run > best) best = run;
            end else begin
                run = 0;
            end
        end
        if (best > max_run) begin
            $display("ERROR: %0d consecutive high priority frames, anti-starvation limit is %0d",
                best, max_run);
            errors = errors + 1;
        end else begin
            $display("  longest high priority run: %0d frame(s), limit %0d", best, max_run);
        end
    end
endtask

initial begin
    for (i = 0; i < S_COUNT; i = i + 1) begin
        next_frame[i]  = 0;
        frames_seen[i] = 0;
    end
    for (i = 0; i < MAX_FRAMES; i = i + 1) begin
        frame_order[i] = -1;
        exp_order[i]   = -1;
    end

    errors          = 0;
    beats_in        = 0;
    exp_beats_total = 0;
    n_frames        = 0;
    exp_len         = 0;
    cur_port        = -1;
    cur_frame       = -1;
    cur_beat        = 0;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    // ------------------------------------------------------------------
    // Case 1: A sends one 256 byte frame, B is idle
    // ------------------------------------------------------------------
    $display("\n=== Case 1: A only, 256 bytes ===");
    s_base = n_frames;
    exp_len = 1;
    exp_order[0] = PORT_A;
    expect_frame(PORT_A, LEN_256);
    send_burst(PORT_A, 1, LEN_256);
    wait_drain();
    print_order(s_base, exp_len);
    check_order(s_base);
    check_counts();

    // ------------------------------------------------------------------
    // Case 2: B sends one 1024 byte frame, A is idle
    // ------------------------------------------------------------------
    $display("\n=== Case 2: B only, 1024 bytes ===");
    s_base = n_frames;
    exp_len = 1;
    exp_order[0] = PORT_B;
    expect_frame(PORT_B, LEN_1024);
    send_burst(PORT_B, 1, LEN_1024);
    wait_drain();
    print_order(s_base, exp_len);
    check_order(s_base);
    check_counts();

    // ------------------------------------------------------------------
    // Case 3: both start together, A 512 bytes, B 1024 bytes
    //         A has priority, so A completes before B even starts
    // ------------------------------------------------------------------
    $display("\n=== Case 3: A 512 bytes and B 1024 bytes together ===");
    stall_en = 1'b1;
    s_base = n_frames;
    exp_len = 2;
    exp_order[0] = PORT_A;
    exp_order[1] = PORT_B;
    expect_frame(PORT_A, LEN_512);
    expect_frame(PORT_B, LEN_1024);
    fork
        send_burst(PORT_A, 1, LEN_512);
        send_burst(PORT_B, 1, LEN_1024);
    join
    wait_drain();
    stall_en = 1'b0;
    print_order(s_base, exp_len);
    check_order(s_base);
    check_counts();

    // ------------------------------------------------------------------
    // Case 4: both start together, A 1024 bytes, B 512 bytes
    //         A still has priority although B is shorter
    // ------------------------------------------------------------------
    $display("\n=== Case 4: A 1024 bytes and B 512 bytes together ===");
    stall_en = 1'b1;
    s_base = n_frames;
    exp_len = 2;
    exp_order[0] = PORT_A;
    exp_order[1] = PORT_B;
    expect_frame(PORT_A, LEN_1024);
    expect_frame(PORT_B, LEN_512);
    fork
        send_burst(PORT_A, 1, LEN_1024);
        send_burst(PORT_B, 1, LEN_512);
    join
    wait_drain();
    stall_en = 1'b0;
    print_order(s_base, exp_len);
    check_order(s_base);
    check_counts();

    // ------------------------------------------------------------------
    // Case 5: A sends 5 back to back 1024 byte frames, B sends 8 back to
    //         back 512 byte frames.  A wins STARVE_LIMIT = 4 frames, then
    //         B is forced through, afterwards A gets its 5th frame and B
    //         finishes the remaining 7 frames.
    // ------------------------------------------------------------------
    $display("\n=== Case 5: A 5x1024 back to back, B 8x512 back to back ===");
    stall_en = 1'b1;
    s_base = n_frames;
    exp_len = 13;
    exp_order[0]  = PORT_A;
    exp_order[1]  = PORT_A;
    exp_order[2]  = PORT_A;
    exp_order[3]  = PORT_A;
    exp_order[4]  = PORT_B;
    exp_order[5]  = PORT_A;
    for (i = 6; i < 13; i = i + 1) begin
        exp_order[i] = PORT_B;
    end
    expect_frame(PORT_A, LEN_1024);     // 5 frames
    expect_frame(PORT_A, LEN_1024);
    expect_frame(PORT_A, LEN_1024);
    expect_frame(PORT_A, LEN_1024);
    expect_frame(PORT_A, LEN_1024);
    expect_frame(PORT_B, LEN_512);      // 8 frames
    expect_frame(PORT_B, LEN_512);
    expect_frame(PORT_B, LEN_512);
    expect_frame(PORT_B, LEN_512);
    expect_frame(PORT_B, LEN_512);
    expect_frame(PORT_B, LEN_512);
    expect_frame(PORT_B, LEN_512);
    expect_frame(PORT_B, LEN_512);
    fork
        send_burst(PORT_A, 5, LEN_1024);
        send_burst(PORT_B, 8, LEN_512);
    join
    wait_drain();
    stall_en = 1'b0;
    print_order(s_base, exp_len);
    check_order(s_base);
    check_max_run(s_base, exp_len, STARVE_LIMIT);
    check_counts();

    // ------------------------------------------------------------------
    repeat (20) @(posedge clk);
    if (beats_in != exp_beats_total) begin
        $display("ERROR: leftover beats: %0d received, %0d expected", beats_in, exp_beats_total);
        errors = errors + 1;
    end

    $display("");
    if (errors == 0) begin
        $display("PASS: all arbitration cases (%0d frames, %0d beats, %0d bytes)",
            n_frames, beats_in, beats_in * BYTES_PER_BEAT);
        $finish;
    end else begin
        $fatal(1, "FAIL: %0d error(s) detected", errors);
    end
end

initial begin
    #400000;
    $fatal(1, "Simulation timed out");
end

endmodule
