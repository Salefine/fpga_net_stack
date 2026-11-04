/****************************************************************************
 * @file    send_axis.v
 * @brief   AXI4-Stream payload source: internal incrementing test-pattern
 *          generator (MODE=1) or async s_axis input crossed into the
 *          m_axis_aclk domain by an xpm_fifo_async (MODE=0)
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.1
 * @date    2026-10-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.0      |    zzhi          |                        |
 * |   2026-11-04  |   v1.1      |    zzhi          | add MODE source select |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2026 zzhi
 * ***************************************************************************/
 `resetall
 `timescale 1ns/1ps
 `default_nettype none

module send_axis#(
    parameter STREAM_TDATA_WIDTH = 512,
    parameter STREAM_TKEEP_WIDTH = STREAM_TDATA_WIDTH / 8,
    parameter STREAM_TOTAL_WIDTH = STREAM_TDATA_WIDTH + STREAM_TKEEP_WIDTH + 2,
    parameter MODE = 1,                    // 1: internal test-pattern generator
                                            // 0: async s_axis input (xpm_fifo_async CDC)
    parameter S_AXIS_FIFO_ADDR_WIDTH = 10  // MODE=0: async FIFO depth = 2**S_AXIS_FIFO_ADDR_WIDTH
)(
    input  wire                                 m_axis_aclk,
    input  wire                                 m_axis_aresetn,

    input  wire [31:0]                          st_length,
    input  wire                                 st_start,
    output wire                                 st_end,

    /* async s_axis input (MODE = 0), crossed into the m_axis_aclk domain.
     * s_axis_aresetn must be synchronous to s_axis_aclk. */
    input  wire                                 s_axis_aclk,
    input  wire                                 s_axis_aresetn,
    input  wire [STREAM_TDATA_WIDTH-1:0]        s_axis_tdata,
    input  wire [STREAM_TKEEP_WIDTH-1:0]        s_axis_tkeep,
    input  wire                                 s_axis_tvalid,
    input  wire                                 s_axis_tlast,
    output wire                                 s_axis_tready,

    output wire [STREAM_TDATA_WIDTH-1:0]        m_axis_tdata,
    output wire [STREAM_TKEEP_WIDTH-1:0]        m_axis_tkeep,
    output wire                                 m_axis_tlast,
    output wire                                 m_axis_tvalid,
    input  wire                                 m_axis_tready
);

initial begin
    if (STREAM_TDATA_WIDTH != 32 && STREAM_TDATA_WIDTH != 64 && 
        STREAM_TDATA_WIDTH != 128 && STREAM_TDATA_WIDTH != 256 && STREAM_TDATA_WIDTH != 512) begin
        $error("Error: AXI4-Stream data width must be  32, 64, 128, 256, or 512 (instance %m)");
        $finish;
    end

    if (STREAM_TKEEP_WIDTH*8 != STREAM_TDATA_WIDTH) begin
        $error("Error: AXI4-Stream keep width is incorrect (instance %m)");
        $finish;
    end

    if (MODE != 0 && MODE != 1) begin
        $error("Error: MODE must be 0 (async s_axis input) or 1 (internal generator) (instance %m)");
        $finish;
    end
end

localparam AXIS_DATA_WIDTH = STREAM_TDATA_WIDTH;
localparam AXIS_STRB_WIDTH = STREAM_TKEEP_WIDTH;
localparam OUTPUT_FIFO_ADDR_WIDTH = 5;
localparam IDLE = 1'b0;
localparam SEND = 1'b1;
localparam AXIS_TDATA_BYTES_WIDTH = $clog2(STREAM_TDATA_WIDTH/8);
localparam AXIS_TDATA_INT_WIDTH = STREAM_TKEEP_WIDTH / 4;

integer i;

reg [0 : 0]state_reg = IDLE, state_next;
reg        st_start_reg = 1'b0, st_start_next;
reg [31:0] st_length_reg = 32'b0, st_length_next;
reg [31:0] op_cycle_reg = 32'b0, op_cycle_next;
reg [31:0] cycle_cnt_reg = 32'b0, cycle_cnt_next;
reg  [STREAM_TDATA_WIDTH-1:0]  m_axis_tdata_reg  = 0, m_axis_tdata_next;
reg  [STREAM_TKEEP_WIDTH-1:0]  m_axis_tkeep_reg  = 0, m_axis_tkeep_next;
reg                            m_axis_tlast_reg  = 0, m_axis_tlast_next;
reg                            m_axis_tvalid_reg = 0, m_axis_tvalid_next;
reg                            st_end_reg = 0, st_end_next = 0;


wire m_axi_wready_int;


assign st_end = st_end_reg;

always @(*) begin
    state_next = state_reg;
    st_start_next = st_start_reg;
    st_length_next = st_length_reg;
    op_cycle_next = op_cycle_reg;
    cycle_cnt_next = cycle_cnt_reg;
    m_axis_tdata_next = m_axis_tdata_reg;
    m_axis_tkeep_next = m_axis_tkeep_reg;
    m_axis_tlast_next = m_axis_tlast_reg;
    m_axis_tvalid_next = m_axis_tvalid_reg;
    st_end_next = st_end_reg;
    if (op_cycle_reg == cycle_cnt_reg ) begin
        op_cycle_next = 0;
    end

    case (state_reg)
        IDLE: begin
            op_cycle_next = 0;
            m_axis_tdata_next = 0;
            m_axis_tkeep_next = 0;
            st_end_next = 0;
            m_axis_tlast_next = 0;
            m_axis_tvalid_next = 0;
            if (st_start && (~st_start_reg)) begin
                state_next = SEND;
                st_length_next = st_length;
                cycle_cnt_next = st_length_next[31:AXIS_TDATA_BYTES_WIDTH] + (|st_length_next[AXIS_TDATA_BYTES_WIDTH-1:0]);
            end
        end
        SEND: begin
            if (m_axi_wready_int) begin
                for ( i = 0; i < AXIS_TDATA_INT_WIDTH; i = i + 1) begin
                    m_axis_tdata_next[i*32 +: 32]= op_cycle_reg*AXIS_TDATA_INT_WIDTH + $unsigned(i);
                end
                m_axis_tlast_next = (op_cycle_reg == cycle_cnt_reg - 1) ? 1'b1 : 1'b0;
                m_axis_tkeep_next = (op_cycle_reg != cycle_cnt_reg - 1) ? {STREAM_TKEEP_WIDTH{1'b1}} : 
                                    |st_length_next[AXIS_TDATA_BYTES_WIDTH-1:0] ? (64'h1 << (st_length_next[AXIS_TDATA_BYTES_WIDTH-1:0])) - 1 : {(STREAM_TKEEP_WIDTH){1'b1}};
                m_axis_tvalid_next = 1'b1;
                op_cycle_next = op_cycle_reg + 1;
                
                if (op_cycle_reg == cycle_cnt_reg - 1) begin
                    state_next = IDLE;
                    st_start_next = 1'b0;
                    st_end_next = 1'b1;
                end 
            end
        end
    endcase
end

always @(posedge m_axis_aclk) begin
    if (!m_axis_aresetn) begin
        state_reg <= IDLE;
        st_start_reg <= 1'b0;
        st_length_reg <= 32'b0;
        op_cycle_reg <= 32'b0;
        cycle_cnt_reg <= 32'b0;
        st_end_reg <= 0;
    end else begin
        state_reg <= state_next;
        st_start_reg <= st_start_next;
        st_length_reg <= st_length_next;
        op_cycle_reg <= op_cycle_next;
        cycle_cnt_reg <= cycle_cnt_next;
        st_end_reg <= st_end_next;
    end
end

reg [AXIS_DATA_WIDTH-1:0] m_axis_wdata_reg  = {AXIS_DATA_WIDTH{1'b0}};
reg [AXIS_STRB_WIDTH-1:0] m_axis_wstrb_reg  = {AXIS_STRB_WIDTH{1'b0}};
reg                       m_axis_wlast_reg  = 1'b0;
reg                       m_axis_wvalid_reg = 1'b0;

reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_wr_ptr_reg = 0;
reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_rd_ptr_reg = 0;
reg out_fifo_half_full_reg = 1'b0;

wire out_fifo_full = out_fifo_wr_ptr_reg == (out_fifo_rd_ptr_reg ^ {1'b1, {OUTPUT_FIFO_ADDR_WIDTH{1'b0}}});
wire out_fifo_empty = out_fifo_wr_ptr_reg == out_fifo_rd_ptr_reg;

(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [AXIS_DATA_WIDTH-1:0] out_fifo_wdata[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [AXIS_STRB_WIDTH-1:0] out_fifo_wstrb[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg                      out_fifo_wlast[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];

assign m_axi_wready_int = !out_fifo_half_full_reg;

generate
    /*---------------------------------------------------------------
     * MODE = 0 : m_axis comes from the async s_axis input, crossed
     * into the m_axis_aclk domain by an xpm_fifo_async (FWFT read).
     * tkeep/tlast travel through the FIFO, so the external source
     * defines the frame boundaries; st_length/st_start are unused.
     *--------------------------------------------------------------*/
    if (MODE == 0) begin : gen_src_s_axis

        wire [STREAM_TDATA_WIDTH + STREAM_TKEEP_WIDTH :0] s_axis_fifo_dout;
        wire                                              s_axis_fifo_empty;
        wire                                              s_axis_fifo_alful;
        wire                                              s_axis_fifo_rden;

        xpm_fifo_async #(
              .CASCADE_HEIGHT       (0                                            ),
              .DOUT_RESET_VALUE     ("0"                                          ),
              .ECC_MODE             ("no_ecc"                                     ),
              .FIFO_MEMORY_TYPE     ("auto"                                       ),
              .FIFO_READ_LATENCY    (0                                            ),
              .FIFO_WRITE_DEPTH     (2**S_AXIS_FIFO_ADDR_WIDTH                    ),
              .FULL_RESET_VALUE     (0                                            ),
              .PROG_EMPTY_THRESH    (10                                           ),
              .PROG_FULL_THRESH     (2**S_AXIS_FIFO_ADDR_WIDTH - 10               ),
              .RD_DATA_COUNT_WIDTH  (S_AXIS_FIFO_ADDR_WIDTH + 1                   ),
              .READ_DATA_WIDTH      (STREAM_TDATA_WIDTH + STREAM_TKEEP_WIDTH + 1  ),
              .READ_MODE            ("fwft"                                       ),
              .RELATED_CLOCKS       (0                                            ),
              .SIM_ASSERT_CHK       (0                                            ),
              .USE_ADV_FEATURES     ("1f1f"                                       ),
              .WAKEUP_TIME          (0                                            ),
              .WRITE_DATA_WIDTH     (STREAM_TDATA_WIDTH + STREAM_TKEEP_WIDTH + 1  ),
              .WR_DATA_COUNT_WIDTH  (S_AXIS_FIFO_ADDR_WIDTH + 1                   )
        ) s_axis_async_fifo (
              .sleep                (1'b0                                         ),
              .injectdbiterr        (1'b0                                         ),
              .injectsbiterr        (1'b0                                         ),
              .almost_full          (s_axis_fifo_alful                            ),
              .dout                 (s_axis_fifo_dout                             ),
              .empty                (s_axis_fifo_empty                            ),
              .din                  ({s_axis_tlast, s_axis_tkeep, s_axis_tdata}   ),
              .rd_clk               (m_axis_aclk                                  ),
              .rd_en                (s_axis_fifo_rden                             ),
              .rst                  (~s_axis_aresetn                              ),
              .wr_clk               (s_axis_aclk                                  ),
              .wr_en                (s_axis_tvalid & s_axis_tready                )
        );

        // accept while the FIFO has room; the almost_full margin keeps
        // the accepted write from overflowing the FIFO
        assign s_axis_tready = ~s_axis_fifo_alful;

        assign s_axis_fifo_rden = ~s_axis_fifo_empty & m_axis_tready;

        assign m_axis_tdata  = s_axis_fifo_dout[STREAM_TDATA_WIDTH-1:0];
        assign m_axis_tkeep  = s_axis_fifo_dout[STREAM_TDATA_WIDTH + STREAM_TKEEP_WIDTH - 1 : STREAM_TDATA_WIDTH];
        assign m_axis_tlast  = s_axis_fifo_dout[STREAM_TDATA_WIDTH + STREAM_TKEEP_WIDTH];
        assign m_axis_tvalid = ~s_axis_fifo_empty;

    end
    /*---------------------------------------------------------------
     * MODE = 1 : m_axis comes from the internal incrementing test
     * pattern generator (frame length from st_length/st_start).
     *--------------------------------------------------------------*/
    else begin : gen_src_test

        assign m_axis_tdata  = m_axis_wdata_reg;
        assign m_axis_tkeep  = m_axis_wstrb_reg;
        assign m_axis_tvalid = m_axis_wvalid_reg;
        assign m_axis_tlast  = m_axis_wlast_reg;

        assign s_axis_tready = 1'b0;

    end
endgenerate

always @(posedge m_axis_aclk) begin
    m_axis_wvalid_reg <= m_axis_wvalid_reg && !m_axis_tready;

    out_fifo_half_full_reg <= $unsigned(out_fifo_wr_ptr_reg - out_fifo_rd_ptr_reg) >= 2**(OUTPUT_FIFO_ADDR_WIDTH-1);

    if (!out_fifo_full && m_axis_tvalid_next) begin
        out_fifo_wdata[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= m_axis_tdata_next;
        out_fifo_wstrb[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= m_axis_tkeep_next;
        out_fifo_wlast[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= m_axis_tlast_next;
        out_fifo_wr_ptr_reg <= out_fifo_wr_ptr_reg + 1;
    end

    if (!out_fifo_empty && (!m_axis_wvalid_reg || m_axis_tready)) begin
        m_axis_wdata_reg <= out_fifo_wdata[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        m_axis_wstrb_reg <= out_fifo_wstrb[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        m_axis_wlast_reg <= out_fifo_wlast[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        m_axis_wvalid_reg <= 1'b1;
        out_fifo_rd_ptr_reg <= out_fifo_rd_ptr_reg + 1;
    end

    if (~m_axis_aresetn) begin
        out_fifo_wr_ptr_reg <= 0;
        out_fifo_rd_ptr_reg <= 0;
        m_axis_wvalid_reg <= 1'b0;
    end
end

endmodule
`resetall