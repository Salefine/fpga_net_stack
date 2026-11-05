/****************************************************************************
 * @file    tcp_layer.v
 * @brief  
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.0
 * @date    2025-01-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.0      |    zzhi          | tcp server             |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2026 zzhi
 * ***************************************************************************/

`resetall
`timescale 1ns / 1ps
`default_nettype none

module tcp_layer #(
    //超时重传次数(0=不重传,超时即放弃)与重传超时周期数,
    //提升为参数便于仿真缩短等待(硬件默认: 4次/125M周期@125MHz约1s)
    parameter integer RETRANSMIT_RETRY_COUNT = 4,
    parameter integer RETRANSMIT_TIMEOUT     = 125000000
)(
    input  wire [31:0]src_ip_addr,     //source ip address
    input  wire [31:0]dst_ip_addr,     //destination ip address
    input  wire [31:0]recv_src_ip_addr,
    input  wire [31:0]recv_dst_ip_addr,  

    input  wire [15:0]tcp_src_port,    //tcp source port
    input  wire [15:0]tcp_dst_port,    //tcp destination port

    output wire tcp_linkup,
    input  wire [15:0] tcp_paylen,

	input  wire clk,
    input  wire rst,

	/* tcp tx axis interface */		  
    input  wire [63:0]   app_tx_axis_tdata ,
    input  wire [7:0]    app_tx_axis_tkeep ,
    input  wire          app_tx_axis_tvalid,		 
    input  wire          app_tx_axis_tlast ,
    output wire          app_tx_axis_tready,
	/* tx axis interface to ip */
	output wire [63:0]   tcp_tx_axis_tdata ,
    output wire [7:0]    tcp_tx_axis_tkeep ,
    output wire          tcp_tx_axis_tvalid,		 
    output wire          tcp_tx_axis_tlast ,
    input  wire          tcp_tx_axis_tready,

	/* tcp rx axis interface (from ip_rx) */		   
    input  wire [63:0]   tcp_rx_axis_tdata ,
    input  wire [7:0]    tcp_rx_axis_tkeep ,
    input  wire          tcp_rx_axis_tvalid,		 
    input  wire          tcp_rx_axis_tlast ,
    output wire          tcp_rx_axis_tready,
    input  wire          tcp_rx_axis_tuser ,
	/* rx axis interface to application */
	output wire  [63:0]  app_rx_axis_tdata ,
    output wire  [7:0]   app_rx_axis_tkeep ,
    output wire          app_rx_axis_tvalid,		   
    output wire          app_rx_axis_tlast ,
    output wire          app_rx_axis_tuser,
    input  wire          app_rx_axis_tready
);


wire [31:0] tcp_tx_seq;
wire [31:0] tcp_tx_ack;
wire [31:0] tcp_rx_seq;
wire [31:0] tcp_rx_ack;

wire [15:0] recv_client_port;   // client源端口, 由tcp_rx动态解析
reg  [15:0] client_port_reg = 'b0;   // 在SYN时锁存的学习结果, 回填TX目的端口

wire [15:0] tcp_tx_window;

wire tcp_handshake_syn;
wire tcp_handshake_ack;
wire tcp_close_ack;
wire tcp_close_fin;
wire tcp_trans_resp;
wire tcp_psh_ack;
wire tcp_recv_ack;
wire tcp_ack_ok;
wire tcp_rst;

wire [15:0] tcp_rx_paylen;
wire [15:0] tcp_tx_len;

wire [63:0] tcp_data_axis_tdata;
wire [7:0]  tcp_data_axis_tkeep;
wire        tcp_data_axis_tlast;
wire        tcp_data_axis_tvalid;
wire        tcp_data_axis_tready;

wire [63:0] tcp_ctrl_axis_tdata;
wire [7:0]  tcp_ctrl_axis_tkeep;
wire        tcp_ctrl_axis_tlast;
wire        tcp_ctrl_axis_tvalid;
wire        tcp_ctrl_axis_tready;

// 动态学习client源端口: 收到合法SYN(handshake_syn脉冲)时锁存recv_client_port。
// tcp_src_port_reg在s0拍解析、handshake_syn在s6校验通过后才拉高, 故此时端口值已稳定。
always @(posedge clk) begin
    if (rst) begin
        client_port_reg <= 'b0;
    end else if (tcp_handshake_syn) begin
        client_port_reg <= recv_client_port;
    end
end

//发送窗口固定全开(与tcp_ctrl内部默认一致)
assign tcp_tx_window = 16'hffff;

tcp_tx#(
    .RETRANSMIT_RETRY_COUNT(RETRANSMIT_RETRY_COUNT),
    .RETRANSMIT_TIMEOUT    (RETRANSMIT_TIMEOUT)
) tcp_tx_inst(
    .src_ip_addr    (src_ip_addr),     
    .dst_ip_addr    (dst_ip_addr),                                        
    .tcp_src_port   (tcp_src_port),   
    .tcp_dst_port   (client_port_reg),    

    .tcp_linkup     (tcp_linkup),

    .tcp_ack_ok     (tcp_ack_ok),
    .tcp_tx_seq     (tcp_tx_seq),
    .tcp_tx_ack     (tcp_tx_ack),
    .tcp_tx_window  (tcp_tx_window),
    .tcp_tx_len     (tcp_tx_len),

	.clk (clk),
    .rst (rst),  

    .app_tx_axis_tdata (app_tx_axis_tdata),
    .app_tx_axis_tkeep (app_tx_axis_tkeep),
    .app_tx_axis_tvalid(app_tx_axis_tvalid),		 
    .app_tx_axis_tlast (app_tx_axis_tlast),
    .app_tx_axis_tready(app_tx_axis_tready),

	.tcp_tx_axis_tdata (tcp_data_axis_tdata),
    .tcp_tx_axis_tkeep (tcp_data_axis_tkeep),
    .tcp_tx_axis_tvalid(tcp_data_axis_tvalid),		 
    .tcp_tx_axis_tlast (tcp_data_axis_tlast),
    .tcp_tx_axis_tready(tcp_data_axis_tready)
);

tcp_ctrl tcp_ctrl_inst(
    .clk(clk),
    .rst(rst),
    .tcp_src_port  (tcp_src_port),
    .tcp_dst_port  (client_port_reg),
    .tcp_src_ipaddr(src_ip_addr),
    .tcp_dst_ipaddr(dst_ip_addr),

    .tcp_handshake_syn(tcp_handshake_syn),
    .tcp_handshake_ack(tcp_handshake_ack),
    .tcp_close_fin    (tcp_close_fin),
    .tcp_close_ack    (tcp_close_ack),
    .tcp_psh_ack      (tcp_psh_ack),
    .tcp_recv_ack     (tcp_recv_ack),
    .tcp_client_rst   (tcp_rst),

    .tcp_rx_seq (tcp_rx_seq),
    .tcp_rx_ack (tcp_rx_ack), 
    .tcp_tx_seq (tcp_tx_seq),
    .tcp_tx_ack (tcp_tx_ack),

    .tcp_recv_resp (tcp_trans_resp),
    .tcp_rx_paylen (tcp_rx_paylen),
    .tcp_tx_len    (tcp_tx_len),
    .tcp_ack_ok    (tcp_ack_ok),

    .tcp_ctrl_axis_tdata (tcp_ctrl_axis_tdata),
    .tcp_ctrl_axis_tkeep (tcp_ctrl_axis_tkeep),
    .tcp_ctrl_axis_tvalid(tcp_ctrl_axis_tvalid),		 
    .tcp_ctrl_axis_tlast (tcp_ctrl_axis_tlast),
    .tcp_ctrl_axis_tready(tcp_ctrl_axis_tready),
    .tcp_link(tcp_linkup)
);


tcp_rx tcp_rx_inst(
    .recv_dst_ip_addr(recv_dst_ip_addr),     //destination ip address (local)
    .recv_src_ip_addr(recv_src_ip_addr),     //source ip address (remote)
          
	.clk(clk),
    .rst(rst),

	/* tcp rx axis interface (from ip_rx) */		   
    .tcp_rx_axis_tdata  (tcp_rx_axis_tdata),
    .tcp_rx_axis_tkeep  (tcp_rx_axis_tkeep),
    .tcp_rx_axis_tvalid (tcp_rx_axis_tvalid),		 
    .tcp_rx_axis_tlast  (tcp_rx_axis_tlast),
    .tcp_rx_axis_tready (tcp_rx_axis_tready),
    .tcp_rx_axis_tuser  (tcp_rx_axis_tuser),

    .tcp_link_up      (tcp_linkup),
    .tcp_handshake_syn(tcp_handshake_syn),
    .tcp_handshake_ack(tcp_handshake_ack),
    .tcp_close_fin    (tcp_close_fin),
    .tcp_close_ack    (tcp_close_ack),
    .tcp_psh_ack      (tcp_psh_ack),
    .tcp_recv_ack     (tcp_recv_ack),
    .tcp_trans_resp   (tcp_trans_resp),
    .tcp_rst          (tcp_rst),

    .tcp_rx_seq    (tcp_rx_seq), 
    .tcp_rx_ack    (tcp_rx_ack), 
    .tcp_rx_paylen (tcp_rx_paylen),
    .recv_src_port (recv_client_port),
    .tcp_seg_len   (tcp_paylen   ),

	.app_rx_axis_tdata (app_rx_axis_tdata ),
    .app_rx_axis_tkeep (app_rx_axis_tkeep ),
    .app_rx_axis_tvalid(app_rx_axis_tvalid),		   
    .app_rx_axis_tlast (app_rx_axis_tlast ),
    .app_rx_axis_tuser (app_rx_axis_tuser ),
    .app_rx_axis_tready(app_rx_axis_tready)
);

//-----------------------------TX仲裁(帧级, ctrl优先)------------------------
// 规则:
//  - 未建立连接(linkup=0): 只发ctrl包(握手SYN+ACK)
//  - 已建立连接: 收到FIN(挥手)时发ctrl包, 否则发data包
//  ctrl始终优先于data(数据ACK/挥手ACK都要及时发出), 且一旦选中某一路,
//  保持到该路tlast握手, 防止ctrl与data字节在IP层被拼接成一帧。
//reg sel_ctrl_reg     = 1'b0;
//reg frame_active_reg = 1'b0;

//空闲时: ctrl有包选ctrl, 否则选data; 帧内保持sel_ctrl_reg
//wire sel_ctrl = frame_active_reg ? sel_ctrl_reg : tcp_ctrl_axis_tvalid;

//always @(posedge clk) begin
//    if (rst) begin
//        sel_ctrl_reg     <= 1'b0;
//        frame_active_reg <= 1'b0;
//    end
//    else if (!frame_active_reg) begin
//        if (tcp_ctrl_axis_tvalid | tcp_data_axis_tvalid) begin
//            sel_ctrl_reg     <= tcp_ctrl_axis_tvalid;   //ctrl优先
//            frame_active_reg <= 1'b1;
//        end
//    end
//    else begin
//        if (sel_ctrl_reg ? (tcp_ctrl_axis_tvalid & tcp_ctrl_axis_tready & tcp_ctrl_axis_tlast)
//                         : (tcp_data_axis_tvalid & tcp_data_axis_tready & tcp_data_axis_tlast)) begin
//            frame_active_reg <= 1'b0;
//        end
//    end
//end

// assign tcp_ctrl_axis_tready =  sel_ctrl & tcp_tx_axis_tready;
// assign tcp_data_axis_tready = ~sel_ctrl & tcp_tx_axis_tready;

// assign tcp_tx_axis_tdata  = sel_ctrl ? tcp_ctrl_axis_tdata  : tcp_data_axis_tdata;
// assign tcp_tx_axis_tkeep  = sel_ctrl ? tcp_ctrl_axis_tkeep  : tcp_data_axis_tkeep;
// assign tcp_tx_axis_tlast  = sel_ctrl ? tcp_ctrl_axis_tlast  : tcp_data_axis_tlast;
// assign tcp_tx_axis_tvalid = sel_ctrl ? tcp_ctrl_axis_tvalid : tcp_data_axis_tvalid;

eth_arb_mux_v1 #(
    .S_COUNT     (2  ),
    .DATA_WIDTH  (64 ),
    .KEEP_ENABLE (1  ),
    .ID_ENABLE   (0  ),
    .DEST_ENABLE (0  ),
    .USER_ENABLE (0  ),
    .USER_WIDTH  (1  ),
    .ARB_TYPE_ROUND_ROBIN   (0),
    .ARB_LSB_HIGH_PRIORITY  (1)
)
eth_arb_tcp_tx_inst (
    .clk(clk),
    .rst(rst),
    // no Ethernet header descriptor at this level (IP encapsulation
    // happens downstream in ip_tx)
    .s_eth_dest_mac             ({48'b0, 48'b0}),
    .s_eth_src_mac              ({48'b0, 48'b0}),
    .s_eth_type                 ({8'b0, 8'b0}),
    //---------------------- Ethernet frame inputs---------------------//
    .s_eth_payload_axis_tdata   ({tcp_data_axis_tdata , tcp_ctrl_axis_tdata }),
    .s_eth_payload_axis_tkeep   ({tcp_data_axis_tkeep , tcp_ctrl_axis_tkeep }),
    .s_eth_payload_axis_tvalid  ({tcp_data_axis_tvalid, tcp_ctrl_axis_tvalid}),
    .s_eth_payload_axis_tready  ({tcp_data_axis_tready, tcp_ctrl_axis_tready}),
    .s_eth_payload_axis_tlast   ({tcp_data_axis_tlast , tcp_ctrl_axis_tlast }),
    .s_eth_payload_axis_tuser   ('b0),
    .s_eth_payload_axis_tid     ('b0),
    .s_eth_payload_axis_tdest   ('b0),
    
    //--------------------- Ethernet frame output ---------------------//
    .m_eth_dest_mac             (),
    .m_eth_src_mac              (),
    .m_eth_type                 (),
    .m_eth_payload_axis_tdata   (tcp_tx_axis_tdata   ),
    .m_eth_payload_axis_tkeep   (tcp_tx_axis_tkeep   ),
    .m_eth_payload_axis_tvalid  (tcp_tx_axis_tvalid  ),
    .m_eth_payload_axis_tready  (tcp_tx_axis_tready  ),
    .m_eth_payload_axis_tlast   (tcp_tx_axis_tlast   ),
    .m_eth_payload_axis_tuser   (),
    .m_eth_payload_axis_tid     (),
    .m_eth_payload_axis_tdest   ()
);

endmodule

`resetall