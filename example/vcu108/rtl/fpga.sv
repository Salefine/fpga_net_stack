/****************************************************************************
 * @file    fpga.v
 * @brief  
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.0
 * @date    2025-01-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.0      |    zzhi          |                        |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2026 zzhi
 * ***************************************************************************/

`resetall
`timescale 1ns / 1ps
`default_nettype none

`define TCP_ECHO_TEST 1
module fpga#(
    parameter COUNT = 1
)(
    input wire clk_300mhz_p,
    input wire clk_300mhz_n,

    output wire qsfp0_lpmode,
    output wire qsfp0_modsell_ls,
    output wire qsfp0_resetl_ls,
    
    input wire gt_refclk_p,
    input wire gt_refclk_n,

    input  wire [COUNT-1:0] gt_rxp_in,
    input  wire [COUNT-1:0] gt_rxn_in,
    output wire [COUNT-1:0] gt_txp_out,
    output wire [COUNT-1:0] gt_txn_out
);
localparam UDP = 0;
localparam TCP = 1;

assign  qsfp0_lpmode = 1'b0	;
assign  qsfp0_resetl_ls = 1'b1;
assign  qsfp0_modsell_ls = 1'b1;
/*
 * Clock and reset generation
 *  - 300 MHz clock input
 */

wire clk_300mhz_ibufg;

// Internal 300 MHz clock
wire clk_125mhz_mmcm_out;
wire clk_125mhz_int;
wire rst_125mhz_int;

// Internal 156.25 MHz clock
wire clk_156mhz_int;
wire rst_156mhz_int;

wire mmcm_rst = 1'b0;
wire mmcm_locked;
wire mmcm_clkfb;
(* MARK_DEBUG="true" *)wire tcp_linkup;
IBUFGDS #(
   .DIFF_TERM("FALSE"),
   .IBUF_LOW_PWR("FALSE")   
)
clk_300mhz_ibufg_inst (
   .O   (clk_300mhz_ibufg),
   .I   (clk_300mhz_p),
   .IB  (clk_300mhz_n) 
);

// MMCM instance
// 300 MHz in, 125 MHz out
// VCO range: 800 MHz to 1600 MHz
// M = 10, D = 3 sets Fpfd = 100 MHz, Fvco = 300 * 10 / 3 = 1000 MHz (in range)
// Divide by 8 to get output frequency of 125 MHz
MMCME4_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKOUT0_DIVIDE_F(8),
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKOUT0_PHASE(0),
    .CLKOUT1_DIVIDE(1),
    .CLKOUT1_DUTY_CYCLE(0.5),
    .CLKOUT1_PHASE(0),
    .CLKOUT2_DIVIDE(1),
    .CLKOUT2_DUTY_CYCLE(0.5),
    .CLKOUT2_PHASE(0),
    .CLKOUT3_DIVIDE(1),
    .CLKOUT3_DUTY_CYCLE(0.5),
    .CLKOUT3_PHASE(0),
    .CLKOUT4_DIVIDE(1),
    .CLKOUT4_DUTY_CYCLE(0.5),
    .CLKOUT4_PHASE(0),
    .CLKOUT5_DIVIDE(1),
    .CLKOUT5_DUTY_CYCLE(0.5),
    .CLKOUT5_PHASE(0),
    .CLKOUT6_DIVIDE(1),
    .CLKOUT6_DUTY_CYCLE(0.5),
    .CLKOUT6_PHASE(0),
    .CLKFBOUT_MULT_F(10),
    .CLKFBOUT_PHASE(0),
    .DIVCLK_DIVIDE(3),
    .REF_JITTER1(0.010),
    .CLKIN1_PERIOD(3.333),
    .STARTUP_WAIT("FALSE"),
    .CLKOUT4_CASCADE("FALSE")
)
clk_mmcm_inst (
    .CLKIN1(clk_300mhz_ibufg),
    .CLKFBIN(mmcm_clkfb),
    .RST(mmcm_rst),
    .PWRDWN(1'b0),
    .CLKOUT0(clk_125mhz_mmcm_out),
    .CLKOUT0B(),
    .CLKOUT1(),
    .CLKOUT1B(),
    .CLKOUT2(),
    .CLKOUT2B(),
    .CLKOUT3(),
    .CLKOUT3B(),
    .CLKOUT4(),
    .CLKOUT5(),
    .CLKOUT6(),
    .CLKFBOUT(mmcm_clkfb),
    .CLKFBOUTB(),
    .LOCKED(mmcm_locked)
);

BUFG
clk_125mhz_bufg_inst (
    .I(clk_125mhz_mmcm_out),
    .O(clk_125mhz_int)
);

sync_reset #(
    .N(4)
)
sync_reset_125mhz_inst (
    .clk(clk_125mhz_int),
    .rst(~mmcm_locked),
    .out(rst_125mhz_int)
);

wire sfp0_rx_block_lock;
wire sfp_mgt_refclk_0;

IBUFDS_GTE4 ibufds_gte4_sfp_mgt_refclk_0_inst (
    .I     (gt_refclk_p),
    .IB    (gt_refclk_n),
    .CEB   (1'b0),
    .O     (sfp_mgt_refclk_0),
    .ODIV2 ()
);



//------------------------- SFP0 interface -----------------------//
wire        sfp0_tx_clk_int;
wire        sfp0_tx_rst_int;
wire [63:0] sfp0_txd_int;
wire [7:0]  sfp0_txc_int;
wire        sfp0_rx_clk_int;
wire        sfp0_rx_rst_int;
wire [63:0] sfp0_rxd_int;
wire [7:0]  sfp0_rxc_int;

//----------------------MAC to FIFO interface---------------------//
(* MARK_DEBUG="true" *)wire [63:0] mac_fifo_tx_axis_tdata ;
(* MARK_DEBUG="true" *)wire [7:0]  mac_fifo_tx_axis_tkeep ;
(* MARK_DEBUG="true" *)wire        mac_fifo_tx_axis_tvalid;
(* MARK_DEBUG="true" *)wire        mac_fifo_tx_axis_tready;
(* MARK_DEBUG="true" *)wire        mac_fifo_tx_axis_tlast ;
(* MARK_DEBUG="true" *)wire        mac_fifo_tx_axis_tuser ;

(* MARK_DEBUG="true" *)wire [63:0] mac_fifo_rx_axis_tdata ;
(* MARK_DEBUG="true" *)wire [7:0]  mac_fifo_rx_axis_tkeep ;
(* MARK_DEBUG="true" *)wire        mac_fifo_rx_axis_tvalid;
(* MARK_DEBUG="true" *)wire        mac_fifo_rx_axis_tready;
(* MARK_DEBUG="true" *)wire        mac_fifo_rx_axis_tlast ;
(* MARK_DEBUG="true" *)wire        mac_fifo_rx_axis_tuser ;


//-----------------MAC to AXI Stream interface-------------------//

(* MARK_DEBUG="true" *)wire  [63:0] app_tx_axis_tdata ;
(* MARK_DEBUG="true" *)wire  [7:0]  app_tx_axis_tkeep ;
(* MARK_DEBUG="true" *)wire         app_tx_axis_tvalid;
(* MARK_DEBUG="true" *)wire         app_tx_axis_tready;
(* MARK_DEBUG="true" *)wire         app_tx_axis_tlast ;

(* MARK_DEBUG="true" *)wire  [63:0] app_rx_axis_tdata ;
(* MARK_DEBUG="true" *)wire  [7:0]  app_rx_axis_tkeep ;
(* MARK_DEBUG="true" *)wire         app_rx_axis_tvalid;
(* MARK_DEBUG="true" *)wire         app_rx_axis_tready;
(* MARK_DEBUG="true" *)wire         app_rx_axis_tlast ;


assign clk_156mhz_int = sfp0_tx_clk_int;
assign rst_156mhz_int = sfp0_tx_rst_int;


eth_xcvr_phy_quad_wrapper #(
    .COUNT(COUNT)
)
sfp_phy_inst (
    .xcvr_ctrl_clk(clk_125mhz_int),
    .xcvr_ctrl_rst(rst_125mhz_int),
    //------------------- Common Ports -------------------//
    .xcvr_gtpowergood_out(),
    //---------------- Reference clock -------------------//
    .xcvr_gtrefclk00_in(sfp_mgt_refclk_0),
    //--------------------- Serial data-------------------//
    .xcvr_txp   (gt_txp_out),
    .xcvr_txn   (gt_txn_out),
    .xcvr_rxp   (gt_rxp_in),
    .xcvr_rxn   (gt_rxn_in),
    //------------------- PHY connections-----------------//
    .phy_1_tx_clk    (sfp0_tx_clk_int),
    .phy_1_tx_rst    (sfp0_tx_rst_int),
    .phy_1_xgmii_txd (sfp0_txd_int),
    .phy_1_xgmii_txc (sfp0_txc_int),
    .phy_1_rx_clk    (sfp0_rx_clk_int),
    .phy_1_rx_rst    (sfp0_rx_rst_int),
    .phy_1_xgmii_rxd (sfp0_rxd_int),
    .phy_1_xgmii_rxc (sfp0_rxc_int),
    //------------------- Status signals-----------------//
    .phy_1_tx_bad_block     (),
    .phy_1_rx_error_count   (),
    .phy_1_rx_bad_block     (),
    .phy_1_rx_sequence_error(),
    .phy_1_rx_block_lock    (sfp0_rx_block_lock),
    .phy_1_rx_status        (),
    .phy_1_cfg_tx_prbs31_enable(1'b0),
    .phy_1_cfg_rx_prbs31_enable(1'b0)
);

/*
 * eth_mac_10g_fifo: 10G MAC FIFO module
 *  - Interface: AXI4-Stream
 */

eth_mac_10g_fifo #(
    .ENABLE_PADDING(1),
    .ENABLE_DIC(1),
    .MIN_FRAME_LENGTH(64),
    .TX_FIFO_DEPTH(4096),
    .TX_FRAME_FIFO(1),
    .RX_FIFO_DEPTH(4096),
    .RX_FRAME_FIFO(1)
)
eth_mac_10g_fifo_inst (
    //-------------------Clocks-------------------------------//
    .rx_clk     (sfp0_rx_clk_int),
    .rx_rst     (sfp0_rx_rst_int),
    .tx_clk     (sfp0_tx_clk_int),
    .tx_rst     (sfp0_tx_rst_int),
    .logic_clk  (clk_156mhz_int),
    .logic_rst  (rst_156mhz_int),
    //-------------------user interface----------------------//
    .tx_axis_tdata  (mac_fifo_tx_axis_tdata ),
    .tx_axis_tkeep  (mac_fifo_tx_axis_tkeep ),
    .tx_axis_tvalid (mac_fifo_tx_axis_tvalid),
    .tx_axis_tready (mac_fifo_tx_axis_tready),
    .tx_axis_tlast  (mac_fifo_tx_axis_tlast ),
    .tx_axis_tuser  (mac_fifo_tx_axis_tuser ),
    .rx_axis_tdata  (mac_fifo_rx_axis_tdata ),
    .rx_axis_tkeep  (mac_fifo_rx_axis_tkeep ),
    .rx_axis_tvalid (mac_fifo_rx_axis_tvalid),
    .rx_axis_tready (mac_fifo_rx_axis_tready),
    .rx_axis_tlast  (mac_fifo_rx_axis_tlast ),
    .rx_axis_tuser  (mac_fifo_rx_axis_tuser ),
    //-------------------xgmii interface----------------------//
    .xgmii_rxd(sfp0_rxd_int),
    .xgmii_rxc(sfp0_rxc_int),
    .xgmii_txd(sfp0_txd_int),
    .xgmii_txc(sfp0_txc_int),
    //-------------------status signals-----------------------//
    .tx_fifo_overflow   (),
    .tx_fifo_bad_frame  (),
    .tx_fifo_good_frame (),
    .rx_error_bad_frame (),
    .rx_error_bad_fcs   (),
    .rx_fifo_overflow   (),
    .rx_fifo_bad_frame  (),
    .rx_fifo_good_frame (),
    .cfg_ifg        (8'd12),
    .cfg_tx_enable  (1'b1),
    .cfg_rx_enable  (1'b1)
);

/*
 * udp stack_top: UDP stack top module
 *  - MAC interface: AXI4-Stream
 */
wire configuration_done;
wire configure;
reg  desc_axis_tvalid = 'b0;
reg  configure_reg = 'b0;
wire desc_axis_tready;
wire [31:0] local_ip_addr;
wire [31:0] dst_ip_addr;
wire [15:0] local_tcp_port;
wire [15:0] dst_tcp_port;
wire [47:0] local_mac_addr;
wire [31:0] subnet_mask;
wire [31:0] gateway_ip_addr;
wire [31:0] st_length;
wire st_start;
wire st_end;
vio_ip_cfg ip_cfg (
  .clk          (clk_156mhz_int    ),                
  .probe_in0    (configuration_done),   
  .probe_in1    (st_end),  
  .probe_out0   (local_ip_addr  ),  
  .probe_out1   (dst_ip_addr    ),  
  .probe_out2   (local_tcp_port ),  
  .probe_out3   (dst_tcp_port   ),  
  .probe_out4   (local_mac_addr ),  
  .probe_out5   (configure      ), 
  .probe_out6   (gateway_ip_addr),  
  .probe_out7   (subnet_mask    ),
    .probe_out8(st_length),  // output wire [31 : 0] probe_out8
  .probe_out9(st_start)  // output wire [0 : 0] probe_out9  
);

always @(posedge clk_156mhz_int) begin
    if (rst_156mhz_int) begin
        configure_reg <= 'b0;
    end else begin
        configure_reg <= configure;
    end
end

always @(posedge clk_156mhz_int) begin
    if (rst_156mhz_int) begin
        desc_axis_tvalid <= 'b0;
    end else begin
        if (desc_axis_tvalid && desc_axis_tready) begin
            desc_axis_tvalid <= 'b0;
        end else if (~configure_reg && configure) begin
            desc_axis_tvalid <= 'b1;
        end
    end
end

generate 
    if(TCP == 1) begin:tcp_stack
        tcp_stack_top tcp_stack_inst (
            //------------------- Clocks and resets ---------------//
            .clk(clk_156mhz_int),
            .rst(rst_156mhz_int),
            //------------------- MAC interface -------------------//
            .mac_rx_axis_tdata   (mac_fifo_rx_axis_tdata ),
            .mac_rx_axis_tkeep   (mac_fifo_rx_axis_tkeep ),
            .mac_rx_axis_tvalid  (mac_fifo_rx_axis_tvalid),
            .mac_rx_axis_tready  (mac_fifo_rx_axis_tready),
            .mac_rx_axis_tlast   (mac_fifo_rx_axis_tlast ),
            .mac_rx_axis_tuser   (mac_fifo_rx_axis_tuser ),
            
            .mac_tx_axis_tdata   (mac_fifo_tx_axis_tdata ),
            .mac_tx_axis_tkeep   (mac_fifo_tx_axis_tkeep ),
            .mac_tx_axis_tvalid  (mac_fifo_tx_axis_tvalid),
            .mac_tx_axis_tready  (mac_fifo_tx_axis_tready),
            .mac_tx_axis_tlast   (mac_fifo_tx_axis_tlast ),
            .mac_tx_axis_tuser   (mac_fifo_tx_axis_tuser ),
            //------------------- TCP interface -------------------//
            .app_tx_axis_tdata  (app_tx_axis_tdata ),
            .app_tx_axis_tkeep  (app_tx_axis_tkeep ),
            .app_tx_axis_tvalid (app_tx_axis_tvalid),
            .app_tx_axis_tlast  (app_tx_axis_tlast ),
            .app_tx_axis_tready (app_tx_axis_tready),
            
        	.app_rx_axis_tdata  (app_rx_axis_tdata ),
            .app_rx_axis_tkeep  (app_rx_axis_tkeep ),
            .app_rx_axis_tvalid (app_rx_axis_tvalid),
            .app_rx_axis_tlast  (app_rx_axis_tlast ),
            .app_rx_axis_tuser  (),
            .app_rx_axis_tready (app_rx_axis_tready),
            //------------------- Configuration -------------------//
            .desc_axis_tvalid   (desc_axis_tvalid),
            .desc_axis_tready   (desc_axis_tready),
            .configuration_done (configuration_done),
            .src_ip_addr        (local_ip_addr),
            .gateway_ip_addr    (gateway_ip_addr),
            .subnet_mask        (subnet_mask),
            .tcp_linkup          (tcp_linkup),
            .dst_ip_addr        (dst_ip_addr),
            .src_mac_addr       (local_mac_addr),
            .tcp_src_port       (local_tcp_port),
            .tcp_dst_port       (dst_tcp_port)
        );
    end 
    else if(UDP == 1)begin:udp_stack
        udp_stack_top udp_stack_inst (
            //------------------- Clocks and resets ---------------//
            .clk(clk_156mhz_int),
            .rst(rst_156mhz_int),

            //------------------- MAC interface -------------------//
            .mac_rx_axis_tdata   (mac_fifo_rx_axis_tdata ),
            .mac_rx_axis_tkeep   (mac_fifo_rx_axis_tkeep ),
            .mac_rx_axis_tvalid  (mac_fifo_rx_axis_tvalid),
            .mac_rx_axis_tready  (mac_fifo_rx_axis_tready),
            .mac_rx_axis_tlast   (mac_fifo_rx_axis_tlast ),
            .mac_rx_axis_tuser   (mac_fifo_rx_axis_tuser ),

            .mac_tx_axis_tdata   (mac_fifo_tx_axis_tdata ),
            .mac_tx_axis_tkeep   (mac_fifo_tx_axis_tkeep ),
            .mac_tx_axis_tvalid  (mac_fifo_tx_axis_tvalid),
            .mac_tx_axis_tready  (mac_fifo_tx_axis_tready),
            .mac_tx_axis_tlast   (mac_fifo_tx_axis_tlast ),
            .mac_tx_axis_tuser   (mac_fifo_tx_axis_tuser ),

            //------------------- UDP interface -------------------//
            .app_tx_axis_tdata  (app_tx_axis_tdata ),
            .app_tx_axis_tkeep  (app_tx_axis_tkeep ),
            .app_tx_axis_tvalid (app_tx_axis_tvalid),
            .app_tx_axis_tlast  (app_tx_axis_tlast ),
            .app_tx_axis_tready (app_tx_axis_tready),

        	.app_rx_axis_tdata  (app_rx_axis_tdata ),
            .app_rx_axis_tkeep  (app_rx_axis_tkeep ),
            .app_rx_axis_tvalid (app_rx_axis_tvalid),
            .app_rx_axis_tlast  (app_rx_axis_tlast ),
            .app_rx_axis_tuser  (),
            .app_rx_axis_tready (app_rx_axis_tready),

            //------------------- Configuration -------------------//
            .desc_axis_tvalid   (desc_axis_tvalid),
            .desc_axis_tready   (desc_axis_tready),
            .configuration_done (configuration_done),
            .src_ip_addr        (local_ip_addr),
            .gateway_ip_addr    (gateway_ip_addr),
            .subnet_mask        (subnet_mask),
            .dst_ip_addr        (dst_ip_addr),
            .src_mac_addr       (local_mac_addr),
            .udp_src_port       (16'h5000),
            .udp_dst_port       (16'h5001)
        ); 
    end
endgenerate


/*
 * send_axis: AXI4-Stream data generator module
 *  - Interface: AXI4-Stream
 */


//-----------------------------for tcp speed testing-----------------------//
send_axis #(
   .STREAM_TDATA_WIDTH 	(64   ),
   .MODE(1),
   .S_AXIS_FIFO_SYNC(1)   // 回环两侧同为clk_156mhz_int, 用同步FIFO避免复位网负载恶化
)echo_tcp_test(
   .m_axis_aclk    	(clk_156mhz_int),
   .m_axis_aresetn 	(~rst_156mhz_int),
   .st_length      	(st_length),
   .st_start       	(st_start),
   .st_end         	(st_end),
   .m_axis_tdata   	(app_tx_axis_tdata),
   .m_axis_tkeep   	(app_tx_axis_tkeep),
   .m_axis_tlast   	(app_tx_axis_tlast),
   .m_axis_tvalid  	(app_tx_axis_tvalid),
   .m_axis_tready  	(app_tx_axis_tready),

   .s_axis_aclk    	(clk_156mhz_int),
   .s_axis_aresetn 	(~rst_156mhz_int),
   .s_axis_tdata   	(app_rx_axis_tdata),
   .s_axis_tkeep   	(app_rx_axis_tkeep),
   .s_axis_tlast   	(app_rx_axis_tlast),
   .s_axis_tvalid  	(app_rx_axis_tvalid),
   .s_axis_tready  	(app_rx_axis_tready)
);


endmodule

`resetall