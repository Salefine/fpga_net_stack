/****************************************************************************
 * @file    tcp_rx.v
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
 * |               |   v1.1      |    zzhi          | 控制包: 校验和/握手挥手  |
 * |               |   v1.2      |    zzhi          | 数据包: 负载store-and-  |
 * |               |             |                  | forward, 校验和门控投递 |
 * |               |   v1.3      |    zzhi          | 负载按offset跨拍拼接对齐 |
 * |               |   v1.4      |    zzhi          | 按IP层payload长度裁剪     |
 * |               |             |                  | 以太网padding(不入校验和  |
 * |               |             |                  | 不入payload FIFO)        |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2026 zzhi
 * ***************************************************************************/

`resetall
`timescale 1ns / 1ps
`default_nettype none

module tcp_rx(
    input  wire [31:0] recv_dst_ip_addr,     //destination ip address (local)
    input  wire [31:0] recv_src_ip_addr,     //source ip address (remote)
          
	input  wire clk,
    input  wire rst,

	/* tcp rx axis interface (from ip_rx) */		   
    input  wire [63:0]   tcp_rx_axis_tdata ,
    input  wire [7:0]    tcp_rx_axis_tkeep ,
    input  wire          tcp_rx_axis_tvalid,		 
    input  wire          tcp_rx_axis_tlast ,
    output wire          tcp_rx_axis_tready,
    input  wire          tcp_rx_axis_tuser ,

    //---------------------------ctrl------------------------
    //tcp建立连接信号
    input  wire    tcp_link_up,
    //来自三次握手的建联请求
    output wire    tcp_handshake_syn,
    //server收到来自client的ack
    output wire    tcp_handshake_ack,
    //来此client的四次挥手的请求
    output wire    tcp_close_fin,
    //传递给tcp_ctrl.v模块，告知其client已发送ack，完成关闭
    output wire    tcp_close_ack,

    //client以纯ACK确认了我们发送的数据(供tcp_tx重传逻辑消费)
    output wire    tcp_psh_ack,
    //任意合法段(纯ACK或数据段携带的ACK)均置1一拍, 配合tcp_rx_ack
    //供tcp_ctrl/tcp_tx判定"我们发送的数据是否被确认"(重传停止与序号推进)
    output wire    tcp_recv_ack,
    //client发送RST报文
    output wire    tcp_rst,
    //传给tcp_ctrl.v模块，告知此包已收到，需要发送ack响应
    output wire    tcp_trans_resp,
    //接受来自第一次握手的seq，客户端初始序列号
    output wire[31:0] tcp_rx_seq, 
    //client发出，传给server，ack
    output wire[31:0] tcp_rx_ack, 
    //与tcp_trans_resp同拍有效：本段负载字节数(不含TCP头/padding)，
    //tcp_ctrl据此计算数据ACK号 = tcp_rx_seq + tcp_rx_paylen
    output wire[15:0] tcp_rx_paylen,
    //client的源端口(从收到的TCP头s0拍解析)，供server动态学习后回填
    //SYN+ACK/数据包的目的端口(替代静态配置的tcp_dst_port)
    output wire[15:0] recv_src_port,

    //IP层提供的payload长度(=total_length - IHL*4)，即TCP段总长(含TCP头,
    //不含以太网padding)，用于裁剪MAC层追加的padding字节
    input  wire[15:0] tcp_seg_len,

	/* rx axis interface to application */
	output wire  [63:0]  app_rx_axis_tdata ,
    output wire  [7:0]   app_rx_axis_tkeep ,
    output wire          app_rx_axis_tvalid,		   
    output wire          app_rx_axis_tlast ,
    output wire          app_rx_axis_tuser,
    input  wire          app_rx_axis_tready
);
//---------------------------------------------------------------
function [3:0] count_valid_bytes;
    input [7:0] keep;
    integer i;
    begin
        count_valid_bytes = 4'd0;
        for (i = 0; i < 8; i = i + 1) begin
            count_valid_bytes = count_valid_bytes + keep[i];
        end
    end
endfunction

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

//-----------------------------------------------------------------------------
//拼接循环计数: 用无符号32位, 与无符号的align_cnt/new_cnt运算
//避免'-'/'<'混用signedness告警(integer为有符号)
reg [31:0] j ;
localparam
    s0  = 8'h01,
    s1  = 8'h02,
    s2  = 8'h04,
    s3  = 8'h08,
    s4  = 8'h10,
    s5  = 8'h20,
    s6  = 8'h40,
    s7  = 8'h80;

reg [7:0] trx_state_next, trx_state_reg;

//本段负载字节数(截断padding后)：输入拍在对齐级累加(tcp_pay_cnt_reg)，
//s7锁存到tcp_pay_len_reg，与tcp_trans_resp同拍输出给tcp_ctrl
reg [15:0]  tcp_pay_cnt_next, tcp_pay_cnt_reg = 'b0;
reg [15:0]  tcp_pay_len_next, tcp_pay_len_reg = 'b0;
assign tcp_rx_paylen = tcp_pay_len_reg;

//TCP段总长(含TCP头, 不含以太网padding)在帧首拍(IP层提供tcp_seg_len已稳定)锁存，
//用于TCP校验和的length字段。不再从tkeep累加，避免把padding字节计入。
reg [15:0] tcp_length_reg = 16'd0;

always @(posedge clk) begin
    if (rst) begin
        tcp_length_reg <= 16'd0;
    end
    else if ((trx_state_reg == s0) && tcp_rx_axis_tvalid && tcp_rx_axis_tready) begin
        tcp_length_reg <= tcp_seg_len;
    end
end

reg [63:0] app_rx_axis_tdata_init;
reg [7:0]  app_rx_axis_tkeep_init;
reg        app_rx_axis_tlast_init;
reg        app_rx_axis_tvalid_init;
reg        app_rx_axis_tuser_init;
wire       app_rx_axis_tready_init;

reg [15:0] tcp_src_port_next, tcp_src_port_reg = 'b0;
reg [15:0] tcp_dst_port_next, tcp_dst_port_reg = 'b0;
reg [31:0] tcp_client_ack_next, tcp_client_ack_reg = 'b0;
reg [31:0] tcp_client_seq_next, tcp_client_seq_reg = 'b0;
reg [3:0]  tcp_offset_next, tcp_offset_reg = 'b0;
reg [7:0]  tcp_flag_next, tcp_flag_reg = 'b0;
reg [15:0] tcp_windows_next,tcp_windows_reg = 'b0;
reg tcp_handshake_syn_next,tcp_handshake_syn_reg = 'b0;
reg tcp_handshake_ack_next,tcp_handshake_ack_reg = 'b0;
reg tcp_close_fin_next,tcp_close_fin_reg='b0;
reg tcp_close_ack_next,tcp_close_ack_reg='b0;
reg tcp_psh_ack_next,tcp_psh_ack_reg='b0;
reg tcp_recv_ack_next,tcp_recv_ack_reg='b0;
reg tcp_rst_next,tcp_rst_reg = 'b0;

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
reg [15:0] checksum_header13_next,checksum_header13_reg = 'b0;
reg [15:0] checksum_header14_next,checksum_header14_reg = 'b0;
reg [15:0] checksum_header15_next,checksum_header15_reg = 'b0;

reg [15:0]   tcp_beat_cnt_next, tcp_beat_cnt_reg = 'b0;
reg          tcp_frame_tuser_next, tcp_frame_tuser_reg = 'b0;
reg          tcp_trans_resp_next,  tcp_trans_resp_reg = 'b0;
reg          tcp_has_data_next,    tcp_has_data_reg   = 'b0;

//padding裁剪：tcp_seg_remain = 本帧还需接收的TCP段字节数。
//为0时后续拍全部是padding，只吞不处理。
reg [15:0] tcp_seg_remain_next, tcp_seg_remain_reg = 'b0;
reg [7:0]  tcp_cur_tkeep;    // 当前拍在TCP段内的有效字节mask(截断padding后)
reg        tcp_cur_tlast;    // 当前拍是否为TCP段的最后一拍

reg  [2:0]   tcp_desc_din;
reg          tcp_desc_wr;
reg          tcp_desc_rden;
wire [2:0]   tcp_desc_dout;
wire         tcp_desc_alful, tcp_desc_empty;

wire [63:0]  tcp_payload_data;
wire [7:0]   tcp_payload_keep;
wire         tcp_payload_last;
wire         tcp_payload_alful, tcp_payload_empty;
reg          tcp_payload_rden;

assign tcp_rx_seq = tcp_client_seq_reg;
assign tcp_rx_ack = tcp_client_ack_reg;
assign recv_src_port = tcp_src_port_reg;
assign tcp_handshake_syn = tcp_handshake_syn_reg;
assign tcp_handshake_ack = tcp_handshake_ack_reg;
assign tcp_close_fin = tcp_close_fin_reg;
assign tcp_close_ack = tcp_close_ack_reg;
assign tcp_psh_ack   = tcp_psh_ack_reg;
assign tcp_recv_ack  = tcp_recv_ack_reg;
assign tcp_trans_resp = tcp_trans_resp_reg;
assign tcp_rst = tcp_rst_reg;
//只在s0/s1/s2(包头/负载接收)期间接收新字节，且payload FIFO未接近满
assign tcp_rx_axis_tready = (trx_state_reg == s0 || trx_state_reg == s1 || trx_state_reg == s2)
                            && ~tcp_payload_alful && ~tcp_desc_alful;

//本段是否有负载: 段总长(IP层payload长度) > TCP头长(offset*4)。
//TCP允许不带PSH的数据段(发送端分段时仅末段置PSH), 不能以PSH位判定是否收数据。
wire [15:0] tcp_hdr_bytes       = {10'd0, tcp_offset_reg[3:0], 2'b00};
wire        tcp_seg_has_payload = (tcp_seg_len > tcp_hdr_bytes);

always @ * begin 
    trx_state_next = trx_state_reg;
    tcp_client_ack_next = tcp_client_ack_reg;
    tcp_client_seq_next = tcp_client_seq_reg;
    tcp_dst_port_next = tcp_dst_port_reg;
    tcp_src_port_next = tcp_src_port_reg;

    tcp_offset_next = tcp_offset_reg;
    tcp_flag_next = tcp_flag_reg;
    tcp_windows_next = tcp_windows_reg;
    tcp_handshake_syn_next='b0;
    tcp_handshake_ack_next='b0;
    tcp_close_fin_next='b0;
    tcp_close_ack_next='b0;
    tcp_psh_ack_next='b0;
    tcp_recv_ack_next='b0;
    tcp_trans_resp_next='b0;
    tcp_rst_next='b0;

    tcp_beat_cnt_next    = tcp_beat_cnt_reg;
    tcp_frame_tuser_next = tcp_frame_tuser_reg;
    tcp_seg_remain_next  = tcp_seg_remain_reg;
    tcp_cur_tkeep        = tcp_rx_axis_tkeep;
    tcp_cur_tlast        = tcp_rx_axis_tlast;

    tcp_desc_din = 'b0;
    tcp_desc_wr  = 'b0;
    tcp_pay_len_next = tcp_pay_len_reg;

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

    case(trx_state_reg)
        s0 : begin 

            if(tcp_rx_axis_tvalid & tcp_rx_axis_tready)begin 
                tcp_src_port_next = {tcp_rx_axis_tdata[7:0],tcp_rx_axis_tdata[15:8]};
                tcp_dst_port_next = {tcp_rx_axis_tdata[23:16],tcp_rx_axis_tdata[31:24]};
                tcp_client_seq_next= {tcp_rx_axis_tdata[39:32],tcp_rx_axis_tdata[47:40],
                    tcp_rx_axis_tdata[55:48],tcp_rx_axis_tdata[63:56]};

                //帧起始：锁存本帧tuser
                tcp_frame_tuser_next = tcp_rx_axis_tuser;
                tcp_beat_cnt_next    = 4'd0;
                //本帧TCP段还需接收的字节数 = IP层给的payload长度 - 本拍(s0)的8字节
                tcp_seg_remain_next  = tcp_seg_len - 16'd8;
                
                checksum_header0_next = checksum_gen(recv_dst_ip_addr[15:0],recv_dst_ip_addr[31:16]);
                checksum_header1_next = checksum_gen(recv_src_ip_addr[15:0],recv_src_ip_addr[31:16]);
                checksum_header2_next = checksum_gen('b0 , {tcp_rx_axis_tdata[7:0],tcp_rx_axis_tdata[15:8]});
                checksum_header3_next = checksum_gen('b0 , {tcp_rx_axis_tdata[23:16],tcp_rx_axis_tdata[31:24]});
                checksum_header4_next = checksum_gen('b0 , {tcp_rx_axis_tdata[39:32],tcp_rx_axis_tdata[47:40]});
                checksum_header5_next = checksum_gen('b0 , {tcp_rx_axis_tdata[55:48],tcp_rx_axis_tdata[63:56]});
                trx_state_next = s1;
            end else begin 
                trx_state_next = s0;
            end
        end

        s1 : begin 
            if(tcp_rx_axis_tvalid & tcp_rx_axis_tready)begin 
                tcp_client_ack_next = {{tcp_rx_axis_tdata[7:0],tcp_rx_axis_tdata[15:8]},
                                       {tcp_rx_axis_tdata[23:16],tcp_rx_axis_tdata[31:24]}};
                tcp_offset_next = tcp_rx_axis_tdata[39:36];
                tcp_flag_next = tcp_rx_axis_tdata[47:40];
                tcp_windows_next = {tcp_rx_axis_tdata[55:48],tcp_rx_axis_tdata[63:56]};

                checksum_header2_next = checksum_gen(checksum_header2_reg , {tcp_rx_axis_tdata[7:0],tcp_rx_axis_tdata[15:8]});
                checksum_header3_next = checksum_gen(checksum_header3_reg , {tcp_rx_axis_tdata[23:16],tcp_rx_axis_tdata[31:24]});
                checksum_header4_next = checksum_gen(checksum_header4_reg , {tcp_rx_axis_tdata[39:32],tcp_rx_axis_tdata[47:40]});
                checksum_header5_next = checksum_gen(checksum_header5_reg , {tcp_rx_axis_tdata[55:48],tcp_rx_axis_tdata[63:56]});

                //s2的节拍计数从第3拍(字节16起)开始
                tcp_beat_cnt_next = 4'd2;
                //本拍(s1)又消耗8字节TCP头
                tcp_seg_remain_next = tcp_seg_remain_reg - 16'd8;

                trx_state_next = s2; 
                
            end else begin 
                trx_state_next = s0;
            end            
        end

        //处理控制包信息，负责发出握手信号与关闭信号
        s2 : begin 
            if(tcp_rx_axis_tvalid & tcp_rx_axis_tready)begin 
                //----------- padding裁剪：计算本拍在TCP段内的有效字节 ----------
                //tcp_seg_remain_reg为0时，后续拍全是padding，只吞不处理。
                if (tcp_seg_remain_reg >= 16'd8) begin
                    tcp_cur_tkeep = tcp_rx_axis_tkeep;
                    tcp_cur_tlast = (tcp_seg_remain_reg <= {12'h0, count_valid_bytes(tcp_rx_axis_tkeep)});
                    tcp_seg_remain_next = tcp_seg_remain_reg - {12'h0, count_valid_bytes(tcp_rx_axis_tkeep)};
                end else if (tcp_seg_remain_reg > 16'd0) begin
                    //TCP段在本拍内结束：截断到剩余字节数
                    tcp_cur_tkeep = (8'h01 << tcp_seg_remain_reg[2:0]) - 8'h01;
                    tcp_cur_tlast = 1'b1;
                    tcp_seg_remain_next = 16'd0;
                end else begin
                    //纯padding拍
                    tcp_cur_tkeep = 8'h00;
                    tcp_cur_tlast = 1'b0;
                    tcp_seg_remain_next = 16'd0;
                end

                //负载的提取与对齐在对齐级中完成(见下方alignment部分)
                tcp_beat_cnt_next = tcp_beat_cnt_reg + 4'd1;

                if (tcp_cur_tlast) begin
                    case (tcp_cur_tkeep)
                        8'b00000001: begin 
                            checksum_header2_next = checksum_gen(checksum_header2_reg,{tcp_rx_axis_tdata[7:0],8'h0});
                        end
                        8'b00000011: begin 
                            checksum_header2_next = checksum_gen(checksum_header2_reg,{tcp_rx_axis_tdata[7:0],tcp_rx_axis_tdata[15:8]});
                        end
                        8'b00000111: begin 
                            checksum_header2_next = checksum_gen(checksum_header2_reg,{tcp_rx_axis_tdata[7:0],tcp_rx_axis_tdata[15:8]});
                            checksum_header3_next = checksum_gen(checksum_header3_reg,{tcp_rx_axis_tdata[23:16],8'h00});
                        end
                        8'b00001111: begin 
                            checksum_header2_next = checksum_gen(checksum_header2_reg,{tcp_rx_axis_tdata[7:0],tcp_rx_axis_tdata[15:8]});
                            checksum_header3_next = checksum_gen(checksum_header3_reg,{tcp_rx_axis_tdata[23:16],tcp_rx_axis_tdata[31:24]});
                        end        
                        8'b00011111: begin 
                            checksum_header2_next = checksum_gen(checksum_header2_reg,{tcp_rx_axis_tdata[7:0],tcp_rx_axis_tdata[15:8]});
                            checksum_header3_next = checksum_gen(checksum_header3_reg,{tcp_rx_axis_tdata[23:16],tcp_rx_axis_tdata[31:24]});
                            checksum_header4_next = checksum_gen(checksum_header4_reg,{tcp_rx_axis_tdata[39:32],8'h00});
                        end
                        8'b00111111: begin 
                            checksum_header2_next = checksum_gen(checksum_header2_reg,{tcp_rx_axis_tdata[7:0],tcp_rx_axis_tdata[15:8]});
                            checksum_header3_next = checksum_gen(checksum_header3_reg,{tcp_rx_axis_tdata[23:16],tcp_rx_axis_tdata[31:24]});
                            checksum_header4_next = checksum_gen(checksum_header4_reg,{tcp_rx_axis_tdata[39:32],tcp_rx_axis_tdata[47:40]});
                        end
                        8'b01111111: begin 
                            checksum_header2_next = checksum_gen(checksum_header2_reg,{tcp_rx_axis_tdata[7:0],tcp_rx_axis_tdata[15:8]});
                            checksum_header3_next = checksum_gen(checksum_header3_reg,{tcp_rx_axis_tdata[23:16],tcp_rx_axis_tdata[31:24]});
                            checksum_header4_next = checksum_gen(checksum_header4_reg,{tcp_rx_axis_tdata[39:32],tcp_rx_axis_tdata[47:40]});
                            checksum_header5_next = checksum_gen(checksum_header5_reg,{tcp_rx_axis_tdata[55:48],8'h00});
                        end
                        8'b11111111: begin 
                            checksum_header2_next = checksum_gen(checksum_header2_reg,{tcp_rx_axis_tdata[7:0],tcp_rx_axis_tdata[15:8]});
                            checksum_header3_next = checksum_gen(checksum_header3_reg,{tcp_rx_axis_tdata[23:16],tcp_rx_axis_tdata[31:24]});
                            checksum_header4_next = checksum_gen(checksum_header4_reg,{tcp_rx_axis_tdata[39:32],tcp_rx_axis_tdata[47:40]});
                            checksum_header5_next = checksum_gen(checksum_header5_reg,{tcp_rx_axis_tdata[55:48],tcp_rx_axis_tdata[63:56]});
                        end                                          
                        default: begin end
                    endcase
                    //TCP段结束；若AXIS还有padding则留在s2吞掉，直到tlast
                    if (tcp_rx_axis_tlast) trx_state_next = s3;
                    else                   trx_state_next = s2;
                end else if (tcp_cur_tkeep == 8'hff) begin 
                        checksum_header2_next = checksum_gen(checksum_header2_reg,{tcp_rx_axis_tdata[7:0],tcp_rx_axis_tdata[15:8]});
                        checksum_header3_next = checksum_gen(checksum_header3_reg,{tcp_rx_axis_tdata[23:16],tcp_rx_axis_tdata[31:24]});
                        checksum_header4_next = checksum_gen(checksum_header4_reg,{tcp_rx_axis_tdata[39:32],tcp_rx_axis_tdata[47:40]});
                        checksum_header5_next = checksum_gen(checksum_header5_reg,{tcp_rx_axis_tdata[55:48],tcp_rx_axis_tdata[63:56]});
                        trx_state_next = s2;
                end else begin
                        //纯padding拍：吞掉
                        trx_state_next = tcp_rx_axis_tlast ? s3 : s2;
                end
            end
        end

        s3 : begin 
            checksum_header6_next = checksum_gen(checksum_header0_reg,checksum_header1_reg);
            checksum_header7_next = checksum_gen(checksum_header2_reg , checksum_header3_reg);
            checksum_header8_next = checksum_gen(checksum_header4_reg , checksum_header5_reg);
            checksum_header9_next = checksum_gen({8'h0,8'h6} , tcp_length_reg);
            trx_state_next = s4;  
        end

        s4 : begin 
            checksum_header10_next = checksum_gen(checksum_header7_reg , checksum_header8_reg);
            checksum_header11_next = checksum_gen(checksum_header6_reg , checksum_header9_reg);
            trx_state_next = s5;    
        end

        s5 : begin 
            checksum_header12_next = checksum_gen(checksum_header10_reg , checksum_header11_reg);
            //有负载即按数据包处理: TCP允许发送端把数据拆成多段, 且只有末段
            //(或根本不)带PSH, 因此不能以PSH位判定是否有数据, 应以段长>TCP头长判定
            if(tcp_seg_has_payload)begin
                trx_state_next = s7;
            end else begin 
                trx_state_next = s6; //控制包
            end
        end
        s6 : begin 
            if (checksum_header12_reg == 16'hffff) begin
                tcp_handshake_syn_next = tcp_flag_reg[1];
                tcp_close_fin_next = tcp_flag_reg[0];
                if(~tcp_link_up)begin 
                    tcp_handshake_ack_next = tcp_flag_reg[4];
                end else begin 
                    tcp_close_ack_next = tcp_flag_reg[4]; 
                end
                //纯ACK(无SYN/FIN/PSH)且已建链 => client确认了我们发送的数据
                tcp_psh_ack_next = tcp_link_up & tcp_flag_reg[4] &
                                   ~tcp_flag_reg[3] & ~tcp_flag_reg[0] & ~tcp_flag_reg[1];
                //任意合法ACK段(含FIN+ACK挥手确认)均置位一拍, 供序号推进/重传停止判定
                tcp_recv_ack_next = tcp_flag_reg[4];
            end
            tcp_rst_next = tcp_flag_reg[2]; //RST位=1为RST报文
            trx_state_next = s0; 
        end

        //数据包后处理：校验和正确则通知tcp_ctrl回ack，并把帧描述符
        //(valid/tuser/has_data)写入描述符FIFO，由重放状态机投递或丢弃负载
        s7 : begin 
            if ((checksum_header12_reg == 16'hffff) && !tcp_frame_tuser_reg) begin
                tcp_desc_din[2]     = 1'b1;         //valid：负载可投递
                tcp_trans_resp_next = 1'b1;         //通知tcp_ctrl发送ack
                //数据段(PSH|ACK)携带的ACK同样确认了我们发送的数据
                tcp_recv_ack_next   = tcp_flag_reg[4];
            end else begin
                tcp_desc_din[2]     = 1'b0;         //校验失败/坏帧：负载丢弃
            end
            tcp_desc_din[1] = tcp_frame_tuser_reg;
            tcp_desc_din[0] = tcp_has_data_reg;
            tcp_desc_wr     = 1'b1;
            tcp_pay_len_next = tcp_pay_cnt_reg;     //锁存本段负载长度
            trx_state_next  = s0; 
        end
        
        default : begin 

        end
    endcase
end

//-----------------------------------------------------------------------------


//-----------------------------------------------------------------------------

always @ (posedge clk) begin 
    if(rst)begin 
        trx_state_reg <= s0;
        tcp_client_ack_reg <= 'b0;
        tcp_client_seq_reg <= 'b0;
        tcp_dst_port_reg <= 'b0;
        tcp_src_port_reg <= 'b0;
        tcp_offset_reg <= 'b0;
        tcp_flag_reg <= 'b0;
        tcp_windows_reg <= 'b0;
        tcp_handshake_syn_reg <= 'b0;
        tcp_handshake_ack_reg <= 'b0;
        tcp_close_fin_reg <='b0;
        tcp_close_ack_reg <='b0;
        tcp_psh_ack_reg   <= 'b0;
        tcp_recv_ack_reg  <= 'b0;
        tcp_trans_resp_reg <= 'b0;
        tcp_pay_len_reg   <= 'b0;
        tcp_rst_reg       <= 'b0;

        tcp_beat_cnt_reg <= 'b0;
        tcp_frame_tuser_reg <= 'b0;
        tcp_seg_remain_reg <= 'b0;

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
        trx_state_reg <= trx_state_next;
        tcp_client_ack_reg <= tcp_client_ack_next;
        tcp_client_seq_reg <= tcp_client_seq_next;
        tcp_dst_port_reg <= tcp_dst_port_next;
        tcp_src_port_reg <= tcp_src_port_next;
        tcp_offset_reg <= tcp_offset_next;
        tcp_flag_reg <= tcp_flag_next;
        tcp_windows_reg <= tcp_windows_next;
        tcp_handshake_syn_reg <= tcp_handshake_syn_next;
        tcp_handshake_ack_reg <= tcp_handshake_ack_next;
        tcp_close_fin_reg <= tcp_close_fin_next;
        tcp_close_ack_reg <= tcp_close_ack_next;
        tcp_psh_ack_reg   <= tcp_psh_ack_next;
        tcp_recv_ack_reg  <= tcp_recv_ack_next;
        tcp_trans_resp_reg <= tcp_trans_resp_next;
        tcp_pay_len_reg   <= tcp_pay_len_next;
        tcp_rst_reg       <= tcp_rst_next;

        tcp_beat_cnt_reg <= tcp_beat_cnt_next;
        tcp_frame_tuser_reg <= tcp_frame_tuser_next;
        tcp_seg_remain_reg <= tcp_seg_remain_next;

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

//-----------------------------------------------------------------------------
// 负载对齐级：按offset定位负载起点并跨拍拼接
//   包头长度 = offset*4 字节，负载起始字节 = offset*4，
//   即起始于第(offset>>1)拍(offset偶数时拍边界，奇数时该拍的lane4)。
//   奇数offset的首个负载是半拍(4字节)，与下一拍的低4字节拼接成8字节整字
//   后才写入payload FIFO，仅最后一字允许部分字节(tkeep)。
//-----------------------------------------------------------------------------
reg [63:0]  tcp_payload_wdata;
reg [7:0]   tcp_payload_wkeep;
reg          tcp_payload_wlast;
reg          tcp_payload_wren;

reg [63:0]  tcp_align_hold_next, tcp_align_hold_reg = 'b0;
reg [3:0]   tcp_align_cnt_next,  tcp_align_cnt_reg  = 'b0;
reg         tcp_align_flush_next,tcp_align_flush_reg= 'b0;

//负载字节数累加见FSM前的tcp_pay_cnt_*声明

reg [63:0]  tcp_pay_new_data;
reg [7:0]   tcp_pay_new_keep;
reg [3:0]   tcp_new_cnt;
reg [127:0] tcp_comb_vec;
reg [127:0] tcp_new_ext;
reg [3:0]   tcp_total_cnt;

wire        tcp_pay_hs = (trx_state_reg == s2) && tcp_rx_axis_tvalid && tcp_rx_axis_tready;
wire [3:0]  tcp_pay_start_beat = tcp_offset_reg[3:1];
wire        tcp_pay_first_half = tcp_seg_has_payload && (tcp_beat_cnt_reg == tcp_pay_start_beat)
                                 && tcp_offset_reg[0];
wire        tcp_pay_full_beat  = tcp_seg_has_payload
                                 && ((tcp_beat_cnt_reg >  tcp_pay_start_beat)
                                 ||  ((tcp_beat_cnt_reg == tcp_pay_start_beat) && !tcp_offset_reg[0]));

always @ * begin
    tcp_payload_wdata    = 'b0;
    tcp_payload_wkeep    = 'b0;
    tcp_payload_wlast    = 'b0;
    tcp_payload_wren     = 'b0;
    tcp_align_hold_next  = tcp_align_hold_reg;
    tcp_align_cnt_next   = tcp_align_cnt_reg;
    tcp_align_flush_next = tcp_align_flush_reg;
    tcp_has_data_next    = tcp_has_data_reg;
    tcp_pay_cnt_next     = tcp_pay_cnt_reg;

    //新帧的第一拍：清空对齐缓冲
    if ((trx_state_reg == s0) && tcp_rx_axis_tvalid && tcp_rx_axis_tready) begin
        tcp_align_hold_next  = 'b0;
        tcp_align_cnt_next   = 4'd0;
        tcp_align_flush_next = 1'b0;
        tcp_has_data_next    = 1'b0;
        tcp_pay_cnt_next     = 16'd0;
    end

    //当前拍内的新负载字节：奇数offset的起始拍只取lane4~7
    //注意用截断后的tcp_cur_tkeep(已去除padding)，而非AXIS原始tkeep
    if (tcp_pay_first_half) begin
        tcp_pay_new_data = tcp_rx_axis_tdata >> 32;
        tcp_pay_new_keep = tcp_cur_tkeep >> 4;
    end else begin
        tcp_pay_new_data = tcp_rx_axis_tdata;
        tcp_pay_new_keep = tcp_cur_tkeep;
    end
    tcp_new_cnt = count_valid_bytes(tcp_pay_new_keep);

    //拼接缓冲：低地址为旧字节 hold||new，最多15字节
    //hold最多7字节(align_cnt<=7), 只有j<8才可能读hold;
    //new数据零扩展到128位后按(j-cnt)字节偏移读取,
    //所有part-select均不越界(修复Synth 8-524)
    tcp_new_ext = {64'd0, tcp_pay_new_data};
    for (j = 0; j < 8; j = j + 1) begin
        if (j < tcp_align_cnt_reg)
            tcp_comb_vec[j*8 +: 8] = tcp_align_hold_reg[j*8 +: 8];
        else if ((j - tcp_align_cnt_reg) < tcp_new_cnt)
            tcp_comb_vec[j*8 +: 8] = tcp_new_ext[(j - tcp_align_cnt_reg)*8 +: 8];
        else
            tcp_comb_vec[j*8 +: 8] = 8'h00;
    end
    for (j = 8; j < 16; j = j + 1) begin
        if ((j - tcp_align_cnt_reg) < tcp_new_cnt)
            tcp_comb_vec[j*8 +: 8] = tcp_new_ext[(j - tcp_align_cnt_reg)*8 +: 8];
        else
            tcp_comb_vec[j*8 +: 8] = 8'h00;
    end
    tcp_total_cnt = tcp_align_cnt_reg + tcp_new_cnt;

    if (tcp_align_flush_reg) begin
        //tlast后剩余的尾部部分字，本拍补发
        tcp_payload_wdata    = tcp_align_hold_reg;
        tcp_payload_wkeep    = (8'h01 << tcp_align_cnt_reg) - 8'h01;
        tcp_payload_wlast    = 1'b1;
        tcp_payload_wren     = 1'b1;
        tcp_has_data_next    = 1'b1;
        tcp_align_cnt_next   = 4'd0;
        tcp_align_flush_next = 1'b0;
    end else if (tcp_pay_hs && (tcp_pay_first_half || tcp_pay_full_beat)) begin
        tcp_pay_cnt_next = tcp_pay_cnt_reg + {12'd0, tcp_new_cnt};
        if (tcp_total_cnt >= 4'd8) begin
            //拼接出8字节整字
            tcp_payload_wdata    = tcp_comb_vec[63:0];
            tcp_payload_wkeep    = 8'hff;
            tcp_payload_wlast    = tcp_cur_tlast && (tcp_total_cnt == 4'd8);
            tcp_payload_wren     = 1'b1;
            tcp_has_data_next    = 1'b1;
            tcp_align_hold_next  = tcp_comb_vec[127:64];
            tcp_align_cnt_next   = tcp_total_cnt - 4'd8;
            if (tcp_cur_tlast && (tcp_total_cnt > 4'd8)) begin
                tcp_align_flush_next = 1'b1;
            end
        end else begin
            //不足一字：攒到下一拍
            tcp_align_hold_next = tcp_comb_vec[63:0];
            tcp_align_cnt_next  = tcp_total_cnt;
            if (tcp_cur_tlast && (tcp_total_cnt > 4'd0)) begin
                tcp_align_flush_next = 1'b1;
            end
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        tcp_align_hold_reg  <= 'b0;
        tcp_align_cnt_reg   <= 'b0;
        tcp_align_flush_reg <= 'b0;
        tcp_has_data_reg    <= 'b0;
        tcp_pay_cnt_reg     <= 'b0;
    end else begin
        tcp_align_hold_reg  <= tcp_align_hold_next;
        tcp_align_cnt_reg   <= tcp_align_cnt_next;
        tcp_align_flush_reg <= tcp_align_flush_next;
        tcp_has_data_reg    <= tcp_has_data_next;
        tcp_pay_cnt_reg     <= tcp_pay_cnt_next;
    end
end

//-----------------------------------------------------------------------------
// payload FIFO：数据包负载先入FIFO(store-and-forward)，等s3~s5校验和折叠
// 完成后，由下面的重放状态机按校验结果投递给应用或丢弃
//-----------------------------------------------------------------------------
xpm_fifo_sync #(
      .CASCADE_HEIGHT       (0       ),
      .DOUT_RESET_VALUE     ("0"     ),
      .ECC_MODE             ("no_ecc"),
      .FIFO_MEMORY_TYPE     ("auto"  ),
      .FIFO_READ_LATENCY    (0       ),
      .FIFO_WRITE_DEPTH     (2048    ),
      .FULL_RESET_VALUE     (0       ),
      .PROG_EMPTY_THRESH    (10      ),
      .PROG_FULL_THRESH     (10      ),
      .RD_DATA_COUNT_WIDTH  (12      ),
      .READ_DATA_WIDTH      (73      ),
      .READ_MODE            ("fwft"  ),
      .SIM_ASSERT_CHK       (0       ),
      .USE_ADV_FEATURES     ("1f1f"  ),
      .WAKEUP_TIME          (0       ),
      .WRITE_DATA_WIDTH     (73      ),
      .WR_DATA_COUNT_WIDTH  (12      )
)tcp_payload_fifo (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      .almost_full          (tcp_payload_alful  ),
      .dout                 ({tcp_payload_last,
                              tcp_payload_keep,
                              tcp_payload_data} ),
      .empty                (tcp_payload_empty  ),
      .din                  ({tcp_payload_wlast,
                              tcp_payload_wkeep,
                              tcp_payload_wdata}),
      .rd_en                (tcp_payload_rden   ),
      .rst                  (rst                ),
      .wr_clk               (clk                ),
      .wr_en                (tcp_payload_wren   )
);

//-----------------------------------------------------------------------------
// 描述符FIFO：每个数据包一帧 {valid, tuser, has_data}，在s7(校验完成)时写入
//-----------------------------------------------------------------------------
xpm_fifo_sync #(
      .CASCADE_HEIGHT       (0        ),
      .DOUT_RESET_VALUE     ("0"      ),
      .ECC_MODE             ("no_ecc" ),
      .FIFO_MEMORY_TYPE     ("auto"   ),
      .FIFO_READ_LATENCY    (1        ),
      .FIFO_WRITE_DEPTH     (16       ),
      .FULL_RESET_VALUE     (0        ),
      .PROG_EMPTY_THRESH    (10       ),
      .PROG_FULL_THRESH     (10       ),
      .RD_DATA_COUNT_WIDTH  (5        ),
      .READ_DATA_WIDTH      (3        ),
      .READ_MODE            ("std"    ),
      .SIM_ASSERT_CHK       (0        ),
      .USE_ADV_FEATURES     ("1f1f"   ),
      .WAKEUP_TIME          (0        ),
      .WRITE_DATA_WIDTH     (3        ),
      .WR_DATA_COUNT_WIDTH  (5        )
)tcp_desc_fifo (
      .sleep                (0            ), 
      .injectdbiterr        (1'b0         ),
      .injectsbiterr        (1'b0         ), 
      .almost_full          (tcp_desc_alful     ),
      .dout                 (tcp_desc_dout      ),
      .empty                (tcp_desc_empty     ),
      .din                  (tcp_desc_din       ),
      .rd_en                (tcp_desc_rden      ),
      .rst                  (rst                ),
      .wr_clk               (clk                ),
      .wr_en                (tcp_desc_wr        )
);

//-----------------------------------------------------------------------------
// 负载重放状态机：读描述符，valid则把payload FIFO中的负载搬到应用接口，
// 非valid(校验失败/坏帧)则丢弃，两者都按last标志界定帧边界
//-----------------------------------------------------------------------------
localparam [3:0] RPLY_IDLE = 4'b0001,
                 RPLY_WAIT = 4'b0010,
                 RPLY_OUT  = 4'b0100,
                 RPLY_DRP  = 4'b1000;

reg [3:0] rply_next, rply_reg;
reg       rply_tuser_next, rply_tuser_reg;

always @ * begin
    rply_next = rply_reg;
    tcp_desc_rden    = 1'b0;
    tcp_payload_rden = 1'b0;
    rply_tuser_next  = rply_tuser_reg;

    app_rx_axis_tdata_init  = 64'd0;
    app_rx_axis_tkeep_init  = 8'h00;
    app_rx_axis_tvalid_init = 1'b0;
    app_rx_axis_tlast_init  = 1'b0;
    app_rx_axis_tuser_init  = 1'b0;

    case (rply_reg)
        RPLY_IDLE : begin
            if (~tcp_desc_empty) begin
                tcp_desc_rden = 1'b1;
                rply_next = RPLY_WAIT;
            end
        end

        RPLY_WAIT : begin
            //std FIFO：rd_en后一拍dout有效 dout = {valid, tuser, has_data}
            rply_tuser_next = tcp_desc_dout[1];
            if (tcp_desc_dout[2] && tcp_desc_dout[0]) begin
                rply_next = RPLY_OUT;   //好帧且有负载 -> 投递
            end else if (!tcp_desc_dout[2] && tcp_desc_dout[0]) begin
                rply_next = RPLY_DRP;   //坏帧有负载 -> 丢弃
            end else begin
                rply_next = RPLY_IDLE;  //无负载 -> 无事可做
            end
        end

        RPLY_OUT : begin
            if (~tcp_payload_empty && app_rx_axis_tready_init) begin
                tcp_payload_rden      = 1'b1;
                app_rx_axis_tdata_init  = tcp_payload_data;
                app_rx_axis_tkeep_init  = tcp_payload_keep;
                app_rx_axis_tvalid_init = 1'b1;
                app_rx_axis_tlast_init  = tcp_payload_last;
                app_rx_axis_tuser_init  = rply_tuser_reg;
                if (tcp_payload_last) begin
                    rply_next = RPLY_IDLE;
                end
            end
        end

        RPLY_DRP : begin
            if (~tcp_payload_empty) begin
                tcp_payload_rden = 1'b1;
                if (tcp_payload_last) begin
                    rply_next = RPLY_IDLE;
                end
            end
        end

        default : begin
        end
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        rply_reg      <= RPLY_IDLE;
        rply_tuser_reg <= 1'b0;
    end else begin
        rply_reg      <= rply_next;
        rply_tuser_reg <= rply_tuser_next;
    end
end


//-----------------------------------------------------------------------------
localparam  OUTPUT_FIFO_ADDR_WIDTH = 9;

reg [63:0] app_rx_axis_tdata_reg;
reg [7:0]  app_rx_axis_tkeep_reg;
reg        app_rx_axis_tlast_reg;
reg        app_rx_axis_tvalid_reg;
reg        app_rx_axis_tuser_reg;

(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [63:0] out_fifo_wdata[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg [7:0]  out_fifo_wstrb[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg                      out_fifo_eop[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
(* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
reg                      out_fifo_tuser[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];

reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_wr_ptr_reg = 0;
reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_rd_ptr_reg = 0;

wire out_fifo_full = out_fifo_wr_ptr_reg == (out_fifo_rd_ptr_reg ^ {1'b1, {OUTPUT_FIFO_ADDR_WIDTH{1'b0}}});
wire out_fifo_empty = out_fifo_wr_ptr_reg == out_fifo_rd_ptr_reg;

assign app_rx_axis_tready_init = !out_fifo_full;

always @(posedge clk) begin
    app_rx_axis_tvalid_reg <= app_rx_axis_tvalid_reg && !app_rx_axis_tready;

    if (!out_fifo_full && app_rx_axis_tvalid_init) begin
        out_fifo_wdata[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= app_rx_axis_tdata_init;
        out_fifo_wstrb[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= app_rx_axis_tkeep_init;
        out_fifo_eop[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]]   <= app_rx_axis_tlast_init;     
        out_fifo_tuser[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= app_rx_axis_tuser_init;

        out_fifo_wr_ptr_reg <= out_fifo_wr_ptr_reg + 1;
    end

    if (!out_fifo_empty && (!app_rx_axis_tvalid_reg || app_rx_axis_tready)) begin
        app_rx_axis_tdata_reg <= out_fifo_wdata[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        app_rx_axis_tkeep_reg <= out_fifo_wstrb[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        app_rx_axis_tlast_reg <= out_fifo_eop[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        app_rx_axis_tuser_reg <= out_fifo_tuser[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
        app_rx_axis_tvalid_reg <= 1'b1;
        out_fifo_rd_ptr_reg <= out_fifo_rd_ptr_reg + 1;
    end

    if (rst) begin
        out_fifo_wr_ptr_reg <= 0;
        out_fifo_rd_ptr_reg <= 0;
        app_rx_axis_tvalid_reg <= 1'b0;
    end
end

assign app_rx_axis_tdata  = app_rx_axis_tdata_reg;
assign app_rx_axis_tkeep  = app_rx_axis_tkeep_reg;
assign app_rx_axis_tvalid = app_rx_axis_tvalid_reg;
assign app_rx_axis_tlast  = app_rx_axis_tlast_reg;
assign app_rx_axis_tuser  = app_rx_axis_tuser_reg;

endmodule

`resetall
