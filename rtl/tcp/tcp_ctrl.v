/****************************************************************************
 * @file    tcp_ctrl.v
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

module tcp_ctrl(
    input   wire    clk,
    input   wire    rst,

    input   wire[15:0] tcp_src_port,
    input   wire[15:0] tcp_dst_port,
    input   wire[31:0] tcp_src_ipaddr,
    input   wire[31:0] tcp_dst_ipaddr,
    //-----------------------------ctrl-------------------------------//
    //client发出，请求建立连接
    input   wire    tcp_handshake_syn,
    //server收到来自client的ack
    input   wire    tcp_handshake_ack,
    //挥手信号请求
    input   wire    tcp_close_fin,
    //响应
    input   wire    tcp_close_ack,
    input   wire    tcp_psh_ack,
    //任意合法ACK段(纯ACK/数据段携带)一拍, 配合tcp_rx_ack判定在途段是否被确认
    input   wire    tcp_recv_ack,

    //client发出，复位报文
    input   wire    tcp_client_rst,
    //传给tcp_tx.v模块，使其发送syn+ack信号
    input   wire[31:0] tcp_rx_seq, //接受来自第一次握手的seq，客户端初始序列号
    input   wire[31:0] tcp_rx_ack, //client发出，用于四次挥手

    output wire[31:0] tcp_tx_seq,
    output wire[31:0] tcp_tx_ack,
    
    //tcp接收数据后，需要发送一个ack响应包
    input   wire      tcp_recv_resp,
    //与tcp_recv_resp同拍有效：本段负载字节数，数据ACK号 = tcp_rx_seq + tcp_rx_paylen
    input   wire[15:0] tcp_rx_paylen,
    //在途/最近发送段的负载字节数(tcp_tx提供), ACK确认后据此推进发送序号
    input   wire[15:0] tcp_tx_len,
    //一拍脉冲: 在途发送段已被client确认(tcp_tx据此停止重传)
    output  wire       tcp_ack_ok,
    
    //----------------------packet-------------------//
    output wire [63:0]   tcp_ctrl_axis_tdata ,
    output wire [7:0]    tcp_ctrl_axis_tkeep ,
    output wire          tcp_ctrl_axis_tvalid,		 
    output wire          tcp_ctrl_axis_tlast ,
    input  wire          tcp_ctrl_axis_tready,

    output  wire    tcp_link
);
//------------------------------tcp三次握手处理流程----------------------//

function    [15:0]  checksum_gen
  (
    input       [15:0]  dataina,
    input       [15:0]  datainb
  );
  
    reg [16:0]  sum ;

  begin
    sum = dataina[15:0] + datainb[15:0];
    checksum_gen = sum[16] ? sum[15:0] + 1 : sum[15:0];
  end
  
endfunction

localparam
    s0  = 16'h0001,
    s1  = 16'h0002,
    s2  = 16'h0004,
    s3  = 16'h0008,
    s4  = 16'h0010,
    s5  = 16'h0020,
    s6  = 16'h0040,
    s7  = 16'h0080,
    s8  = 16'h0100,
    s9  = 16'h0200,
    s10 = 16'h0400,
    s11 = 16'h0800,
    s12 = 16'h1000,
    s13 = 16'h2000,
    s14 = 16'h4000,
    s15 = 16'h8000;

(* MARK_DEBUG="true" *)reg [15:0] tcp_state_next, tcp_state_reg;

reg [31:0] tcp_client_seq_next, tcp_client_seq_reg = 'b0;
reg [31:0] tcp_client_ack_next, tcp_client_ack_reg = 'b0;
reg [31:0] tcp_server_seq_next, tcp_server_seq_reg = 'b0;
reg [31:0] tcp_server_ack_next, tcp_server_ack_reg = 'b0;

reg [15:0] checksum_header0_next,checksum_header0_reg = 'b0;
reg [15:0] checksum_header1_next,checksum_header1_reg = 'b0;
reg [15:0] checksum_header2_next,checksum_header2_reg = 'b0;
reg [15:0] checksum_header3_next,checksum_header3_reg = 'b0;
reg [15:0] checksum_header4_next,checksum_header4_reg = 'b0;
reg [15:0] checksum_header5_next,checksum_header5_reg = 'b0;
reg [15:0] checksum_header6_next,checksum_header6_reg = 'b0;
reg [15:0] checksum_header7_next,checksum_header7_reg = 'b0;
reg [15:0] checksum_header8_next,checksum_header8_reg = 'b0;
reg [15:0] checksum_header9_next,checksum_header9_reg = 'b0;
reg [15:0] checksum_header10_next,checksum_header10_reg = 'b0;
reg [15:0] checksum_header11_next,checksum_header11_reg = 'b0;
reg [15:0] checksum_header12_next,checksum_header12_reg = 'b0;

reg [63:0] tcp_ctrl_axis_tdata_init;
reg [7:0]  tcp_ctrl_axis_tkeep_init;
reg        tcp_ctrl_axis_tlast_init;
wire       tcp_ctrl_axis_tready_init;
reg        tcp_ctrl_axis_tvalid_init;

reg [7:0]  tcp_flag = 'b0;
reg [15:0] tcp_windows = 16'hffff;
reg tcp_link_next,tcp_link_reg = 'b0;
reg tcp_data_next,tcp_data_reg = 'b0;

assign tcp_link = tcp_link_reg;
assign tcp_tx_seq = tcp_server_seq_reg;
assign tcp_tx_ack = tcp_server_ack_reg;

//在途发送段是否被确认: client的ACK号 == 发送序号 + 在途负载长度。
//仅在确有数据在途(tcp_tx_len!=0)时判定, 避免建链初期/零长ACK误判。
wire seg_acked = tcp_recv_ack & (tcp_tx_len != 16'd0)
               & (tcp_rx_ack == (tcp_server_seq_reg + tcp_tx_len));
assign tcp_ack_ok = seg_acked;

always @ * begin 
    tcp_state_next = tcp_state_reg;
    tcp_server_ack_next = tcp_server_ack_reg;
    tcp_client_seq_next = tcp_client_seq_reg;
    tcp_server_seq_next = tcp_server_seq_reg;
    tcp_link_next = tcp_link_reg;
    tcp_data_next = tcp_data_reg;

    tcp_ctrl_axis_tdata_init = 'b0;
    tcp_ctrl_axis_tkeep_init = 'b0;
    tcp_ctrl_axis_tlast_init = 'b0;
    tcp_ctrl_axis_tvalid_init= 'b0;

    checksum_header0_next = checksum_header0_reg;
    checksum_header1_next = checksum_header1_reg;
    checksum_header2_next = checksum_header2_reg;
    checksum_header3_next = checksum_header3_reg;
    checksum_header4_next = checksum_header4_reg;
    checksum_header5_next = checksum_header5_reg;
    checksum_header6_next = checksum_header6_reg;
    checksum_header7_next = checksum_header7_reg;
    checksum_header8_next = checksum_header8_reg;
    checksum_header9_next = checksum_header9_reg;
    checksum_header10_next = checksum_header10_reg;
    checksum_header11_next = checksum_header11_reg;
    checksum_header12_next = checksum_header12_reg;

    case (tcp_state_reg)
        s0 : begin 
            tcp_data_next = 'b0;
            if(tcp_client_rst)begin  //处理RST报文
                tcp_state_next = s0;
                tcp_link_next = 'b0;
            end else if(tcp_handshake_syn || tcp_recv_resp)begin 
                tcp_state_next = s1;
                tcp_data_next = tcp_recv_resp; 
                tcp_server_ack_next = tcp_recv_resp ? tcp_rx_seq + tcp_rx_paylen : tcp_rx_seq + 1'b1;
                tcp_server_seq_next = tcp_handshake_syn ? 32'h5000 : tcp_server_seq_reg;
                //数据段携带的ACK若确认了在途段, 同时推进发送序号
                //(不能因优先走ACK发送分支而丢失序号推进)
                if (seg_acked)
                    tcp_server_seq_next = tcp_server_seq_reg + tcp_tx_len;
            end else if(tcp_close_fin)begin 
                tcp_server_seq_next = tcp_rx_ack;
                tcp_server_ack_next = tcp_rx_seq + 1'b1;
                tcp_state_next = s7;
            end else if(seg_acked)begin 
                //纯ACK确认了在途发送段: 推进发送序号(负载长度, 非+1)
                tcp_server_seq_next = tcp_server_seq_reg + tcp_tx_len;
            end else begin
                tcp_state_next = s0;
            end
        end 

        s1 : begin 
            if (tcp_ctrl_axis_tready_init) begin
                tcp_ctrl_axis_tdata_init = {
                    tcp_server_seq_reg[7:0]  ,tcp_server_seq_reg[15:8],
                    tcp_server_seq_reg[23:16],tcp_server_seq_reg[31:24],
                    tcp_dst_port[7:0],tcp_dst_port[15:8],
                    tcp_src_port[7:0],tcp_src_port[15:8]
                };
                tcp_ctrl_axis_tkeep_init = 8'hff;
                tcp_ctrl_axis_tvalid_init= 1'b1;
                tcp_ctrl_axis_tlast_init = 1'b0;

                checksum_header0_next = checksum_gen(tcp_src_ipaddr[15:0],tcp_src_ipaddr[31:16]);
                checksum_header1_next = checksum_gen(tcp_dst_ipaddr[15:0],tcp_dst_ipaddr[31:16]);
                checksum_header2_next = checksum_gen({8'h0,8'h6},16'h14);

                checksum_header3_next = checksum_gen({tcp_ctrl_axis_tdata_init[7:0],tcp_ctrl_axis_tdata_init[15:8]},
                {tcp_ctrl_axis_tdata_init[23:16],tcp_ctrl_axis_tdata_init[31:24]});
                checksum_header4_next = checksum_gen({tcp_ctrl_axis_tdata_init[39:32],tcp_ctrl_axis_tdata_init[47:40]},
                {tcp_ctrl_axis_tdata_init[55:48],tcp_ctrl_axis_tdata_init[63:56]});
                tcp_state_next = s2;
            end
        end

        s2 : begin 
            if (tcp_ctrl_axis_tready_init) begin
                tcp_flag = tcp_data_reg ? 8'h10 : 8'h12;
                tcp_ctrl_axis_tdata_init = {
                    tcp_windows[7:0],tcp_windows[15:8],
                    tcp_flag, 4'h5, 4'h0,
                    tcp_server_ack_reg[7:0],tcp_server_ack_reg[15:8],
                    tcp_server_ack_reg[23:16],tcp_server_ack_reg[31:24]
                };
                tcp_ctrl_axis_tkeep_init = 8'hff;
                tcp_ctrl_axis_tvalid_init= 1'b1;
                tcp_ctrl_axis_tlast_init = 1'b0;

                checksum_header5_next = checksum_gen({tcp_ctrl_axis_tdata_init[7:0],tcp_ctrl_axis_tdata_init[15:8]},
                {tcp_ctrl_axis_tdata_init[23:16],tcp_ctrl_axis_tdata_init[31:24]});
                checksum_header6_next = checksum_gen({tcp_ctrl_axis_tdata_init[39:32],tcp_ctrl_axis_tdata_init[47:40]},
                {tcp_ctrl_axis_tdata_init[55:48],tcp_ctrl_axis_tdata_init[63:56]});
                tcp_state_next = s3;
            end            
        end

        s3 : begin 
            checksum_header7_next = checksum_gen(checksum_header0_reg, checksum_header1_reg);
            checksum_header8_next = checksum_gen(checksum_header2_reg, checksum_header3_reg);
            checksum_header9_next = checksum_gen(checksum_header5_reg, checksum_header4_reg);
            tcp_state_next = s4;
        end

        s4 : begin 
            checksum_header10_next = checksum_gen(checksum_header6_reg, checksum_header7_reg);
            checksum_header11_next = checksum_gen(checksum_header8_reg, checksum_header9_reg);
            tcp_state_next = s5;
        end

        s5 : begin 
            checksum_header12_next = checksum_gen(checksum_header10_reg, checksum_header11_reg);
            tcp_state_next = s6;
        end

        s6 : begin 
            if (tcp_ctrl_axis_tready_init) begin
                tcp_ctrl_axis_tdata_init = {
                    32'h0, //options
                    16'h0, //urgent
                    ~checksum_header12_reg[7:0], ~checksum_header12_reg[15:8]
                };
                tcp_ctrl_axis_tkeep_init = 8'h0f;
                tcp_ctrl_axis_tvalid_init= 1'b1;
                tcp_ctrl_axis_tlast_init = 1'b1;
                
                if(tcp_link)begin 
                    if(tcp_data_reg)begin 
                        tcp_state_next = s0;
                    end else begin 
                        tcp_state_next = s10;
                    end
                end else begin 
                    tcp_state_next = s9;
                end
            end                 
        end

        s7 : begin 
            if (tcp_ctrl_axis_tready_init) begin
                tcp_ctrl_axis_tdata_init = {
                    tcp_server_seq_reg[7:0]  ,tcp_server_seq_reg[15:8],
                    tcp_server_seq_reg[23:16],tcp_server_seq_reg[31:24],
                    tcp_dst_port[7:0],tcp_dst_port[15:8],
                    tcp_src_port[7:0],tcp_src_port[15:8]
                };
                tcp_ctrl_axis_tkeep_init = 8'hff;
                tcp_ctrl_axis_tvalid_init= 1'b1;
                tcp_ctrl_axis_tlast_init = 1'b0;

                checksum_header0_next = checksum_gen(tcp_src_ipaddr[15:0],tcp_src_ipaddr[31:16]);
                checksum_header1_next = checksum_gen(tcp_dst_ipaddr[15:0],tcp_dst_ipaddr[31:16]);
                checksum_header2_next = checksum_gen({8'h0,8'h6},16'h14);

                checksum_header3_next = checksum_gen({tcp_ctrl_axis_tdata_init[7:0],tcp_ctrl_axis_tdata_init[15:8]},
                {tcp_ctrl_axis_tdata_init[23:16],tcp_ctrl_axis_tdata_init[31:24]});
                checksum_header4_next = checksum_gen({tcp_ctrl_axis_tdata_init[39:32],tcp_ctrl_axis_tdata_init[47:40]},
                {tcp_ctrl_axis_tdata_init[55:48],tcp_ctrl_axis_tdata_init[63:56]});
                tcp_state_next = s8;
            end            
        end

        s8 : begin 
            if (tcp_ctrl_axis_tready_init) begin
                tcp_flag = 8'h10;
                tcp_ctrl_axis_tdata_init = {
                    tcp_windows[7:0],tcp_windows[15:8],
                    tcp_flag, 4'h5, 4'h0,
                    tcp_server_ack_reg[7:0],tcp_server_ack_reg[15:8],
                    tcp_server_ack_reg[23:16],tcp_server_ack_reg[31:24]
                };
                tcp_ctrl_axis_tkeep_init = 8'hff;
                tcp_ctrl_axis_tvalid_init= 1'b1;
                tcp_ctrl_axis_tlast_init = 1'b0;
                checksum_header5_next = checksum_gen({tcp_ctrl_axis_tdata_init[7:0],tcp_ctrl_axis_tdata_init[15:8]},
                {tcp_ctrl_axis_tdata_init[23:16],tcp_ctrl_axis_tdata_init[31:24]});
                checksum_header6_next = checksum_gen({tcp_ctrl_axis_tdata_init[39:32],tcp_ctrl_axis_tdata_init[47:40]},
                {tcp_ctrl_axis_tdata_init[55:48],tcp_ctrl_axis_tdata_init[63:56]});
                tcp_state_next = s3;
            end               
        end

        s9 : begin 
            if(tcp_client_rst)begin  //处理RST报文
                tcp_state_next = s0;
                tcp_link_next = 'b0;
            end else if(tcp_handshake_ack)begin 
                if((tcp_rx_seq == tcp_server_ack_reg) && (tcp_rx_ack == tcp_server_seq_reg+1'b1))begin 
                    tcp_link_next = 1;
                    //SYN+ACK消耗一个序号：建链后server发送序号推进到ISN+1
                    tcp_server_seq_next = tcp_server_seq_reg + 1'b1;
                    tcp_state_next = s0;
                end
            end else if(tcp_close_ack)begin 
                if((tcp_rx_seq == tcp_server_ack_reg) && (tcp_rx_ack == tcp_server_seq_reg + 1'b1))begin 
                    tcp_link_next = 0;
                    tcp_state_next = s0;                    
                end
            end 
        end

        s10 : begin 
            if(tcp_client_rst)begin  //处理RST报文
                tcp_state_next = s0;
                tcp_link_next = 'b0;
            end else if (tcp_ctrl_axis_tready_init) begin
                tcp_ctrl_axis_tdata_init = {
                    tcp_server_seq_reg[7:0]  ,tcp_server_seq_reg[15:8],
                    tcp_server_seq_reg[23:16],tcp_server_seq_reg[31:24],
                    tcp_dst_port[7:0],tcp_dst_port[15:8],
                    tcp_src_port[7:0],tcp_src_port[15:8]
                };
                tcp_ctrl_axis_tkeep_init = 8'hff;
                tcp_ctrl_axis_tvalid_init= 1'b1;
                tcp_ctrl_axis_tlast_init = 1'b0;

                checksum_header0_next = checksum_gen(tcp_src_ipaddr[15:0],tcp_src_ipaddr[31:16]);
                checksum_header1_next = checksum_gen(tcp_dst_ipaddr[15:0],tcp_dst_ipaddr[31:16]);
                checksum_header2_next = checksum_gen({8'h0,8'h6},16'h14);

                checksum_header3_next = checksum_gen({tcp_ctrl_axis_tdata_init[7:0],tcp_ctrl_axis_tdata_init[15:8]},
                {tcp_ctrl_axis_tdata_init[23:16],tcp_ctrl_axis_tdata_init[31:24]});
                checksum_header4_next = checksum_gen({tcp_ctrl_axis_tdata_init[39:32],tcp_ctrl_axis_tdata_init[47:40]},
                {tcp_ctrl_axis_tdata_init[55:48],tcp_ctrl_axis_tdata_init[63:56]});
                tcp_state_next = s11;
            end    
        end

        s11 : begin 
            if (tcp_ctrl_axis_tready_init) begin
                tcp_flag = 8'h11;
                tcp_ctrl_axis_tdata_init = {
                    tcp_windows[7:0],tcp_windows[15:8],
                    tcp_flag, 4'h5, 4'h0,
                    tcp_server_ack_reg[7:0],tcp_server_ack_reg[15:8],
                    tcp_server_ack_reg[23:16],tcp_server_ack_reg[31:24]
                };
                tcp_ctrl_axis_tkeep_init = 8'hff;
                tcp_ctrl_axis_tvalid_init= 1'b1;
                tcp_ctrl_axis_tlast_init = 1'b0;
                checksum_header5_next = checksum_gen({tcp_ctrl_axis_tdata_init[7:0],tcp_ctrl_axis_tdata_init[15:8]},
                {tcp_ctrl_axis_tdata_init[23:16],tcp_ctrl_axis_tdata_init[31:24]});
                checksum_header6_next = checksum_gen({tcp_ctrl_axis_tdata_init[39:32],tcp_ctrl_axis_tdata_init[47:40]},
                {tcp_ctrl_axis_tdata_init[55:48],tcp_ctrl_axis_tdata_init[63:56]});
                tcp_state_next = s12;
            end              
        end

        s12 : begin 
            checksum_header7_next = checksum_gen(checksum_header0_reg, checksum_header1_reg);
            checksum_header8_next = checksum_gen(checksum_header2_reg, checksum_header3_reg);
            checksum_header9_next = checksum_gen(checksum_header5_reg, checksum_header4_reg);
            tcp_state_next = s13;            
        end

        s13 : begin 
            checksum_header10_next = checksum_gen(checksum_header6_reg, checksum_header7_reg);
            checksum_header11_next = checksum_gen(checksum_header8_reg, checksum_header9_reg);
            tcp_state_next = s14;            
        end
        
        s14 : begin 
            checksum_header12_next = checksum_gen(checksum_header10_reg, checksum_header11_reg);
            tcp_state_next = s15;            
        end

        s15 : begin 
            if (tcp_ctrl_axis_tready_init) begin
                tcp_ctrl_axis_tdata_init = {
                    32'h0, //options
                    16'h0, //urgent
                    ~checksum_header12_reg[7:0],~checksum_header12_reg[15:8]
                };
                tcp_ctrl_axis_tkeep_init = 8'h0f;
                tcp_ctrl_axis_tvalid_init= 1'b1;
                tcp_ctrl_axis_tlast_init = 1'b1;
                tcp_state_next = s9;  
            end             
        end

        default: begin 
        end
    endcase
end

always @(posedge clk)begin 
    if(rst)begin 
        tcp_state_reg <= s0;
        tcp_server_ack_reg <= 'b0;
        tcp_server_seq_reg <= 'h5000;
        tcp_client_seq_reg <= 'b0;
        tcp_client_ack_reg <= 'b0;
        tcp_link_reg <= 'b0;
        tcp_data_reg <= 'b0;

        checksum_header0_reg <= 'b0;
        checksum_header1_reg <= 'b0;
        checksum_header2_reg <= 'b0;
        checksum_header3_reg <= 'b0;
        checksum_header4_reg <= 'b0;
        checksum_header5_reg <= 'b0;
        checksum_header6_reg <= 'b0;
        checksum_header7_reg <= 'b0;
        checksum_header8_reg <= 'b0;
        checksum_header9_reg <= 'b0;
        checksum_header10_reg <= 'b0;
        checksum_header11_reg <= 'b0;
        checksum_header12_reg <= 'b0;
    end else begin 
        tcp_state_reg <= tcp_state_next;
        tcp_server_ack_reg <= tcp_server_ack_next;
        tcp_server_seq_reg <= tcp_server_seq_next;
        tcp_client_seq_reg <= tcp_client_seq_next;
        tcp_client_ack_reg <= tcp_client_ack_next;
        tcp_link_reg <= tcp_link_next;
        tcp_data_reg <= tcp_data_next;

        checksum_header0_reg <= checksum_header0_next;
        checksum_header1_reg <= checksum_header1_next;
        checksum_header2_reg <= checksum_header2_next;
        checksum_header3_reg <= checksum_header3_next;
        checksum_header4_reg <= checksum_header4_next;
        checksum_header5_reg <= checksum_header5_next;
        checksum_header6_reg <= checksum_header6_next;
        checksum_header7_reg <= checksum_header7_next;
        checksum_header8_reg <= checksum_header8_next;
        checksum_header9_reg <= checksum_header9_next;
        checksum_header10_reg <= checksum_header10_next;
        checksum_header11_reg <= checksum_header11_next;
        checksum_header12_reg <= checksum_header12_next;
    end
end

//------------------------------tcp packet------------------------//
localparam  OUTPUT_FIFO_ADDR_WIDTH = 4;

reg [63:0] tcp_ctrl_axis_tdata_reg;
reg [7:0]  tcp_ctrl_axis_tkeep_reg;
reg        tcp_ctrl_axis_tlast_reg;
reg        tcp_ctrl_axis_tvalid_reg;

(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [63:0] out_fifo_wdata[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [7:0]  out_fifo_wstrb[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg                      out_fifo_eop[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];

reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_wr_ptr_reg = 0;
reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_rd_ptr_reg = 0;

wire out_fifo_full = out_fifo_wr_ptr_reg == (out_fifo_rd_ptr_reg ^ {1'b1, {OUTPUT_FIFO_ADDR_WIDTH{1'b0}}});
wire out_fifo_empty = out_fifo_wr_ptr_reg == out_fifo_rd_ptr_reg;

assign tcp_ctrl_axis_tready_init = !out_fifo_full;


always @(posedge clk) begin
    tcp_ctrl_axis_tvalid_reg <= tcp_ctrl_axis_tvalid_reg && !tcp_ctrl_axis_tready;

    if (!out_fifo_full && tcp_ctrl_axis_tvalid_init) begin
        out_fifo_wdata[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= tcp_ctrl_axis_tdata_init;
        out_fifo_wstrb[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= tcp_ctrl_axis_tkeep_init;
        out_fifo_eop[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= tcp_ctrl_axis_tlast_init;     

        out_fifo_wr_ptr_reg <= out_fifo_wr_ptr_reg + 1;
    end

    if (!out_fifo_empty && (!tcp_ctrl_axis_tvalid_reg || tcp_ctrl_axis_tready)) begin
        tcp_ctrl_axis_tdata_reg <= out_fifo_wdata[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        tcp_ctrl_axis_tkeep_reg <= out_fifo_wstrb[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        tcp_ctrl_axis_tlast_reg <= out_fifo_eop[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        tcp_ctrl_axis_tvalid_reg <= 1'b1;
        out_fifo_rd_ptr_reg <= out_fifo_rd_ptr_reg + 1;
    end

    if (rst) begin
        out_fifo_wr_ptr_reg <= 0;
        out_fifo_rd_ptr_reg <= 0;
        tcp_ctrl_axis_tvalid_reg <= 1'b0;
    end
end

assign tcp_ctrl_axis_tdata  = tcp_ctrl_axis_tdata_reg;
assign tcp_ctrl_axis_tkeep  = tcp_ctrl_axis_tkeep_reg;
assign tcp_ctrl_axis_tvalid = tcp_ctrl_axis_tvalid_reg;
assign tcp_ctrl_axis_tlast  = tcp_ctrl_axis_tlast_reg;

endmodule