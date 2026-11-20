/****************************************************************************
 * @file    define.svh
 * @brief  
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.0
 * @date    2026-10-22
 * 
 * @par :
 * ___________________________________________________________________________
 * |    Date       |  Version    |       Author     |       Description      |
 * |---------------|-------------|------------------|------------------------|
 * |               |   v1.0      |    zzhi          | udp tx                 |
 * |---------------|-------------|------------------|------------------------|
 * 
 * @copyright Copyright (c) 2026 zzhi
 * ***************************************************************************/
`ifndef DEFINE_SVH
`define DEFINE_SVH


// function definition
function automatic logic [15:0] calc_checksum(
    input logic[15:0] a,
    input logic[15:0] b
);
    logic [16:0]sum = a+b;

    return sum[16] ? sum[15:0]+1 : sum[15:0];
endfunction


function automatic logic [6:0] count_valid_bytes(
    input logic [63:0] tkeep
);
    integer counter;
    counter = $countones(tkeep);
    return counter[6:0];
endfunction

`endif