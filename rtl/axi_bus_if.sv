
/****************************************************************************
 * @file    axi_bus_if.sv
 * @brief   AXI Bus Interface Definitions
 * @author  zzhi (zzhi4832@gmail.com)
 * @version 1.0
 * @date    2026-10-22
 *
 * @copyright Copyright (c) 2026 zzhi
 ****************************************************************************/

`resetall
`timescale 1ns / 1ps
`default_nettype none

`ifndef AXI_BUS_IF_SV
`define AXI_BUS_IF_SV


//============================================================================
// AXI4-Stream Interface
//============================================================================

interface axis_if #(
    parameter int unsigned DATA_WIDTH = 512,
    parameter int unsigned KEEP_WIDTH = DATA_WIDTH / 8
);

    logic [DATA_WIDTH-1:0] tdata;
    logic [KEEP_WIDTH-1:0] tkeep;
    logic                  tvalid;
    logic                  tlast;
    logic                  tready;

    // Master: Data transmitter
    modport master (
        output tdata,
        output tkeep,
        output tvalid,
        output tlast,
        input  tready
    );

    // Slave: Data receiver
    modport slave (
        input  tdata,
        input  tkeep,
        input  tvalid,
        input  tlast,
        output tready
    );

endinterface


//============================================================================
// AXI4 Full Interface
//============================================================================

interface axi_full_if #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 512,
    parameter int unsigned ID_WIDTH   = 4
);

    //--------------------------------------------------------------------------
    // Write Address Channel
    //--------------------------------------------------------------------------

    logic [ID_WIDTH-1:0]   awid;
    logic [ADDR_WIDTH-1:0] awaddr;
    logic [7:0]            awlen;
    logic [2:0]            awsize;
    logic [1:0]            awburst;
    logic                  awlock;
    logic [3:0]            awcache;
    logic [2:0]            awprot;
    logic [3:0]            awqos;
    logic [3:0]            awregion;
    logic                  awvalid;
    logic                  awready;

    //--------------------------------------------------------------------------
    // Write Data Channel
    //--------------------------------------------------------------------------

    logic [DATA_WIDTH-1:0]   wdata;
    logic [DATA_WIDTH/8-1:0] wstrb;
    logic                    wlast;
    logic                    wvalid;
    logic                    wready;

    //--------------------------------------------------------------------------
    // Write Response Channel
    //--------------------------------------------------------------------------

    logic [ID_WIDTH-1:0] bid;
    logic [1:0]          bresp;
    logic                bvalid;
    logic                bready;

    //--------------------------------------------------------------------------
    // Read Address Channel
    //--------------------------------------------------------------------------

    logic [ID_WIDTH-1:0]   arid;
    logic [ADDR_WIDTH-1:0] araddr;
    logic [7:0]            arlen;
    logic [2:0]            arsize;
    logic [1:0]            arburst;
    logic                  arlock;
    logic [3:0]            arcache;
    logic [2:0]            arprot;
    logic [3:0]            arqos;
    logic [3:0]            arregion;
    logic                  arvalid;
    logic                  arready;

    //--------------------------------------------------------------------------
    // Read Data Channel
    //--------------------------------------------------------------------------

    logic [ID_WIDTH-1:0]   rid;
    logic [DATA_WIDTH-1:0] rdata;
    logic [1:0]            rresp;
    logic                  rlast;
    logic                  rvalid;
    logic                  rready;


    //--------------------------------------------------------------------------
    // Master Modport
    //--------------------------------------------------------------------------

    modport master (

        // Write Address
        output awid,
        output awaddr,
        output awlen,
        output awsize,
        output awburst,
        output awlock,
        output awcache,
        output awprot,
        output awqos,
        output awregion,
        output awvalid,
        input  awready,

        // Write Data
        output wdata,
        output wstrb,
        output wlast,
        output wvalid,
        input  wready,

        // Write Response
        input  bid,
        input  bresp,
        input  bvalid,
        output bready,

        // Read Address
        output arid,
        output araddr,
        output arlen,
        output arsize,
        output arburst,
        output arlock,
        output arcache,
        output arprot,
        output arqos,
        output arregion,
        output arvalid,
        input  arready,

        // Read Data
        input  rid,
        input  rdata,
        input  rresp,
        input  rlast,
        input  rvalid,
        output rready
    );


    //--------------------------------------------------------------------------
    // Slave Modport
    //--------------------------------------------------------------------------

    modport slave (

        // Write Address
        input  awid,
        input  awaddr,
        input  awlen,
        input  awsize,
        input  awburst,
        input  awlock,
        input  awcache,
        input  awprot,
        input  awqos,
        input  awregion,
        input  awvalid,
        output awready,

        // Write Data
        input  wdata,
        input  wstrb,
        input  wlast,
        input  wvalid,
        output wready,

        // Write Response
        output bid,
        output bresp,
        output bvalid,
        input  bready,

        // Read Address
        input  arid,
        input  araddr,
        input  arlen,
        input  arsize,
        input  arburst,
        input  arlock,
        input  arcache,
        input  arprot,
        input  arqos,
        input  arregion,
        input  arvalid,
        output arready,

        // Read Data
        output rid,
        output rdata,
        output rresp,
        output rlast,
        output rvalid,
        input  rready
    );

endinterface


//============================================================================
// AXI4-Lite Interface
//============================================================================

interface axi_lite_if #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned DATA_WIDTH = 32
);

    //--------------------------------------------------------------------------
    // Write Address Channel
    //--------------------------------------------------------------------------

    logic [ADDR_WIDTH-1:0] awaddr;
    logic [2:0]            awprot;
    logic                  awvalid;
    logic                  awready;

    //--------------------------------------------------------------------------
    // Write Data Channel
    //--------------------------------------------------------------------------

    logic [DATA_WIDTH-1:0]   wdata;
    logic [DATA_WIDTH/8-1:0] wstrb;
    logic                    wvalid;
    logic                    wready;

    //--------------------------------------------------------------------------
    // Write Response Channel
    //--------------------------------------------------------------------------

    logic [1:0] bresp;
    logic       bvalid;
    logic       bready;

    //--------------------------------------------------------------------------
    // Read Address Channel
    //--------------------------------------------------------------------------

    logic [ADDR_WIDTH-1:0] araddr;
    logic [2:0]            arprot;
    logic                  arvalid;
    logic                  arready;

    //--------------------------------------------------------------------------
    // Read Data Channel
    //--------------------------------------------------------------------------

    logic [DATA_WIDTH-1:0] rdata;
    logic [1:0]            rresp;
    logic                  rvalid;
    logic                  rready;


    //--------------------------------------------------------------------------
    // Master Modport
    //--------------------------------------------------------------------------

    modport master (

        // Write Address
        output awaddr,
        output awprot,
        output awvalid,
        input  awready,

        // Write Data
        output wdata,
        output wstrb,
        output wvalid,
        input  wready,

        // Write Response
        input  bresp,
        input  bvalid,
        output bready,

        // Read Address
        output araddr,
        output arprot,
        output arvalid,
        input  arready,

        // Read Data
        input  rdata,
        input  rresp,
        input  rvalid,
        output rready
    );


    //--------------------------------------------------------------------------
    // Slave Modport
    //--------------------------------------------------------------------------

    modport slave (

        // Write Address
        input  awaddr,
        input  awprot,
        input  awvalid,
        output awready,

        // Write Data
        input  wdata,
        input  wstrb,
        input  wvalid,
        output wready,

        // Write Response
        output bresp,
        output bvalid,
        input  bready,

        // Read Address
        input  araddr,
        input  arprot,
        input  arvalid,
        output arready,

        // Read Data
        output rdata,
        output rresp,
        output rvalid,
        input  rready
    );

endinterface


`endif

`default_nettype wire
