// Copyright (C) 2022 Intel Corporation
// SPDX-License-Identifier: MIT

//
// Host channel event tracker common code
//

`include "ofs_plat_if.vh"

module host_chan_events_common
  #(
    // Width of the read event counter updates
    parameter READ_CNT_WIDTH = 3,
    parameter UNIT_IS_DWORDS = 0
    )
   (
    input  logic clk,
    input  logic reset_n,

    input  logic rdClk,
    input  logic [READ_CNT_WIDTH-1 : 0] rdReqCnt,
    input  logic [READ_CNT_WIDTH-1 : 0] rdRespCnt,

    // Send counted events to a specific traffic generator engine
    host_chan_events_if.monitor events
    );

    localparam COUNTER_WIDTH = events.COUNTER_WIDTH;
    typedef logic [COUNTER_WIDTH-1 : 0] t_counter;

    assign events.unit_is_dwords = 1'(UNIT_IS_DWORDS);

    //
    // Move control signals from the engine to rdClk.
    //
    logic eng_reset_n;
    ofs_plat_prim_clock_crossing_reg cc_eng_reset
       (
        .clk_src(events.eng_clk),
        .clk_dst(rdClk),
        .r_in(events.eng_reset_n),
        .r_out(eng_reset_n)
        );

    logic rd_reset_n;
    ofs_plat_prim_clock_crossing_reg cc_clk_reset
       (
        .clk_src(clk),
        .clk_dst(rdClk),
        .r_in(reset_n),
        .r_out(rd_reset_n)
        );

    // Number of lines currently in flight
    logic [READ_CNT_WIDTH-1 : 0] rd_cur_active_lines;

    always_ff @(posedge rdClk)
    begin
        rd_cur_active_lines <= rd_cur_active_lines + rdReqCnt - rdRespCnt;

        if (!rd_reset_n)
        begin
            rd_cur_active_lines <= '0;
        end
    end

    logic [READ_CNT_WIDTH-1 : 0] rd_max_active_lines;
    always_ff @(posedge rdClk)
    begin
        if (rd_cur_active_lines > rd_max_active_lines)
        begin
            rd_max_active_lines <= rd_cur_active_lines;
        end

        if (!rd_reset_n || !eng_reset_n)
        begin
            rd_max_active_lines <= '0;
        end
    end

    // Count total requested lines
    t_counter rd_total_n_lines;

    counter_multicycle#(.NUM_BITS(COUNTER_WIDTH)) rd_total_lines
       (
        .clk(rdClk),
        .reset_n(rd_reset_n && eng_reset_n),
        .incr_by(COUNTER_WIDTH'(rdReqCnt)),
        .value(rd_total_n_lines)
        );

    // Count active lines over time
    t_counter rd_total_active_lines;

    counter_multicycle#(.NUM_BITS(COUNTER_WIDTH)) rd_active_lines
       (
        .clk(rdClk),
        .reset_n(rd_reset_n && eng_reset_n),
        .incr_by(COUNTER_WIDTH'(rd_cur_active_lines)),
        .value(rd_total_active_lines)
        );


    //
    // Forward event info to the engine, crossing to its clock domain.
    //

    ofs_plat_prim_clock_crossing_reg cc_notEmpty
       (
        .clk_src(rdClk),
        .clk_dst(events.eng_clk),
        .r_in(|(rd_cur_active_lines)),
        .r_out(events.notEmpty)
        );

    ofs_plat_prim_clock_crossing_reg#(.WIDTH(COUNTER_WIDTH)) cc_reqs
       (
        .clk_src(rdClk),
        .clk_dst(events.eng_clk),
        .r_in(rd_total_n_lines),
        .r_out(events.num_rd_reqs)
        );

    ofs_plat_prim_clock_crossing_reg#(.WIDTH(COUNTER_WIDTH)) cc_active_req
       (
        .clk_src(rdClk),
        .clk_dst(events.eng_clk),
        .r_in(rd_total_active_lines),
        .r_out(events.active_rd_req_sum)
        );

    ofs_plat_prim_clock_crossing_reg#(.WIDTH(COUNTER_WIDTH)) cc_max_active_reqs
       (
        .clk_src(rdClk),
        .clk_dst(events.eng_clk),
        .r_in(COUNTER_WIDTH'(rd_max_active_lines)),
        .r_out(events.max_active_rd_reqs)
        );


    //
    // Cycle counters, used for determining the FIM interface frequency.
    //
    clock_counter#(.COUNTER_WIDTH(COUNTER_WIDTH))
      count_eng_clk_cycles
       (
        .clk(events.eng_clk),
        .count_clk(events.eng_clk),
        .sync_reset_n(events.eng_reset_n),
        .enable(events.enable_cycle_counter),
        .count(events.eng_clk_cycle_count)
        );

    clock_counter#(.COUNTER_WIDTH(COUNTER_WIDTH))
      count_fim_clk_cycles
       (
        .clk(events.eng_clk),
        .count_clk(clk),
        .sync_reset_n(events.eng_reset_n),
        .enable(events.enable_cycle_counter),
        .count(events.fim_clk_cycle_count)
        );

endmodule // host_chan_events_common
