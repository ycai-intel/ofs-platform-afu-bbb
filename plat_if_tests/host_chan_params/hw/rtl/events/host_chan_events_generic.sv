// Copyright (C) 2024 Intel Corporation
// SPDX-License-Identifier: MIT

//
// Host channel event tracker for generic read counters
//

`include "ofs_plat_if.vh"

module host_chan_events_generic
  #(
    parameter BURST_CNT_WIDTH = 7
    )
   (
    input  logic clk,
    input  logic reset_n,

    input  logic rd_clk,
    input  logic en_tx_rd,
    input  logic [BURST_CNT_WIDTH-1 : 0] tx_rd_cnt,
    input  logic en_rx_rd,

    // Send counted events to a specific traffic generator engine
    host_chan_events_if.monitor events
    );

    //
    // Track new requests and responses
    //
    typedef logic [BURST_CNT_WIDTH-1 : 0] t_line_count;
    t_line_count rd_n_lines_req;
    logic rd_is_line_rsp;

    always_ff @(posedge rd_clk)
    begin
        rd_n_lines_req <= (en_tx_rd ? tx_rd_cnt : '0);
        rd_is_line_rsp <= en_rx_rd;
    end


    //
    // Manage events
    //
    host_chan_events_common
      #(
        .READ_CNT_WIDTH(BURST_CNT_WIDTH)
        )
      hc_evt
       (
        .clk,
        .reset_n,

        .rdClk(rd_clk),
        .rdReqCnt(rd_n_lines_req),
        .rdRespCnt(BURST_CNT_WIDTH'(rd_is_line_rsp)),

        .events
        );

endmodule // host_chan_events_generic
