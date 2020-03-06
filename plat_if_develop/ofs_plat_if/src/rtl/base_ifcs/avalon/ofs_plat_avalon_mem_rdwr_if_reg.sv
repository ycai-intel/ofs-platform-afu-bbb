//
// Copyright (c) 2019, Intel Corporation
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
//
// Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// Neither the name of the Intel Corporation nor the names of its contributors
// may be used to endorse or promote products derived from this software
// without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

//
// Add a configurable number of pipeline stages between a pair of Avalon
// split bus read write memory interface objects.  Pipeline stages are
// complex because of the waitrequest protocol.
//

`include "ofs_plat_if.vh"

module ofs_plat_avalon_mem_rdwr_if_reg
  #(
    // Number of stages to add when registering inputs or outputs
    parameter N_REG_STAGES = 1
    )
   (
    ofs_plat_avalon_mem_rdwr_if.to_slave mem_slave,
    ofs_plat_avalon_mem_rdwr_if.to_master mem_master
    );

    genvar s;
    generate
        if (N_REG_STAGES == 0)
        begin : wires
            ofs_plat_avalon_mem_rdwr_if_connect conn(.mem_slave, .mem_master);
        end
        else
        begin : regs
            // Pipeline stages.
            ofs_plat_avalon_mem_rdwr_if
              #(
                .ADDR_WIDTH(mem_slave.ADDR_WIDTH_),
                .DATA_WIDTH(mem_slave.DATA_WIDTH_),
                .BURST_CNT_WIDTH(mem_slave.BURST_CNT_WIDTH_)
                )
                mem_pipe[N_REG_STAGES+1]();

            // Map mem_slave to stage 0 (wired) to make the for loop below simpler.
            ofs_plat_avalon_mem_rdwr_if_connect_slave_clk
              conn0
               (
                .mem_slave(mem_slave),
                .mem_master(mem_pipe[0])
                );

            // Inject the requested number of stages
            for (s = 1; s <= N_REG_STAGES; s = s + 1)
            begin : p
                assign mem_pipe[s].clk = mem_slave.clk;
                assign mem_pipe[s].reset = mem_slave.reset;

                ofs_plat_utils_avalon_mm_bridge
                  #(
                    .DATA_WIDTH(mem_slave.DATA_WIDTH),
                    .HDL_ADDR_WIDTH(1 + mem_slave.ADDR_WIDTH),
                    .BURSTCOUNT_WIDTH(mem_slave.BURST_CNT_WIDTH)
                    )
                  bridge_rd
                   (
                    .clk(mem_pipe[s].clk),
                    .reset(mem_pipe[s].reset),

                    .s0_waitrequest(mem_pipe[s].rd_waitrequest),
                    .s0_readdata(mem_pipe[s].rd_readdata),
                    .s0_readdatavalid(mem_pipe[s].rd_readdatavalid),
                    .s0_response(mem_pipe[s].rd_response),
                    .s0_burstcount(mem_pipe[s].rd_burstcount),
                    .s0_writedata('0),
                    .s0_address({mem_pipe[s].rd_function, mem_pipe[s].rd_address}),
                    .s0_write(1'b0),
                    .s0_read(mem_pipe[s].rd_read),
                    .s0_byteenable(mem_pipe[s].rd_byteenable),
                    .s0_debugaccess(1'b0),

                    .m0_waitrequest(mem_pipe[s - 1].rd_waitrequest),
                    .m0_readdata(mem_pipe[s - 1].rd_readdata),
                    .m0_readdatavalid(mem_pipe[s - 1].rd_readdatavalid),
                    .m0_response(mem_pipe[s - 1].rd_response),
                    .m0_burstcount(mem_pipe[s - 1].rd_burstcount),
                    .m0_writedata(),
                    .m0_address({mem_pipe[s - 1].rd_function, mem_pipe[s - 1].rd_address}),
                    .m0_write(),
                    .m0_read(mem_pipe[s - 1].rd_read),
                    .m0_byteenable(mem_pipe[s - 1].rd_byteenable),
                    .m0_debugaccess()
                    );

                ofs_plat_utils_avalon_mm_bridge
                  #(
                    .DATA_WIDTH(mem_slave.DATA_WIDTH),
                    .HDL_ADDR_WIDTH(1 + mem_slave.ADDR_WIDTH),
                    .BURSTCOUNT_WIDTH(mem_slave.BURST_CNT_WIDTH)
                    )
                  bridge_wr
                   (
                    .clk(mem_pipe[s].clk),
                    .reset(mem_pipe[s].reset),

                    .s0_waitrequest(mem_pipe[s].wr_waitrequest),
                    .s0_readdata(),
                    // Use readdatavalid/response to pass write response.
                    // The bridge doesn't count reads or writes, so this works.
                    .s0_readdatavalid(mem_pipe[s].wr_writeresponsevalid),
                    .s0_response(mem_pipe[s].wr_response),
                    .s0_burstcount(mem_pipe[s].wr_burstcount),
                    .s0_writedata(mem_pipe[s].wr_writedata),
                    .s0_address({mem_pipe[s].wr_function, mem_pipe[s].wr_address}),
                    .s0_write(mem_pipe[s].wr_write),
                    .s0_read(1'b0),
                    .s0_byteenable(mem_pipe[s].wr_byteenable),
                    .s0_debugaccess(1'b0),

                    .m0_waitrequest(mem_pipe[s - 1].wr_waitrequest),
                    .m0_readdata('0),
                    // See above -- readdatavalid is used for write responses
                    .m0_readdatavalid(mem_pipe[s - 1].wr_writeresponsevalid),
                    .m0_response(mem_pipe[s - 1].wr_response),
                    .m0_burstcount(mem_pipe[s - 1].wr_burstcount),
                    .m0_writedata(mem_pipe[s - 1].wr_writedata),
                    .m0_address({mem_pipe[s - 1].wr_function, mem_pipe[s - 1].wr_address}),
                    .m0_write(mem_pipe[s - 1].wr_write),
                    .m0_read(),
                    .m0_byteenable(mem_pipe[s - 1].wr_byteenable),
                    .m0_debugaccess()
                    );

                // Debugging signal
                assign mem_pipe[s].instance_number = mem_pipe[s-1].instance_number;
            end

            // Map mem_master to the last stage (wired)
            ofs_plat_avalon_mem_rdwr_if_connect conn1(.mem_slave(mem_pipe[N_REG_STAGES]),
                                                      .mem_master(mem_master));
        end
    endgenerate

endmodule // ofs_plat_avalon_mem_rdwr_if_reg


// Same as standard connection, but pass clk and reset from slave to master
module ofs_plat_avalon_mem_rdwr_if_reg_slave_clk
  #(
    // Number of stages to add when registering inputs or outputs
    parameter N_REG_STAGES = 1
    )
   (
    ofs_plat_avalon_mem_rdwr_if.to_slave mem_slave,
    ofs_plat_avalon_mem_rdwr_if.to_master_clk mem_master
    );

    ofs_plat_avalon_mem_rdwr_if
      #(
        .ADDR_WIDTH(mem_slave.ADDR_WIDTH_),
        .DATA_WIDTH(mem_slave.DATA_WIDTH_),
        .BURST_CNT_WIDTH(mem_slave.BURST_CNT_WIDTH_)
        )
      mem_reg();

    assign mem_reg.clk = mem_slave.clk;
    assign mem_reg.reset = mem_slave.reset;
    // Debugging signal
    assign mem_reg.instance_number = mem_slave.instance_number;

    ofs_plat_avalon_mem_rdwr_if_reg
      #(
        .N_REG_STAGES(N_REG_STAGES)
        )
      conn_reg
       (
        .mem_slave(mem_slave),
        .mem_master(mem_reg)
        );

    ofs_plat_avalon_mem_rdwr_if_connect_slave_clk
      conn_direct
       (
        .mem_slave(mem_reg),
        .mem_master(mem_master)
        );

endmodule // ofs_plat_avalon_mem_rdwr_if_reg_slave_clk


// Same as standard connection, but pass clk and reset from master to slave
module ofs_plat_avalon_mem_rdwr_if_reg_master_clk
  #(
    // Number of stages to add when registering inputs or outputs
    parameter N_REG_STAGES = 1
    )
   (
    ofs_plat_avalon_mem_rdwr_if.to_slave_clk mem_slave,
    ofs_plat_avalon_mem_rdwr_if.to_master mem_master
    );

    ofs_plat_avalon_mem_rdwr_if
      #(
        .ADDR_WIDTH(mem_slave.ADDR_WIDTH_),
        .DATA_WIDTH(mem_slave.DATA_WIDTH_),
        .BURST_CNT_WIDTH(mem_slave.BURST_CNT_WIDTH_)
        )
      mem_reg();

    assign mem_reg.clk = mem_master.clk;
    assign mem_reg.reset = mem_master.reset;
    // Debugging signal
    assign mem_reg.instance_number = mem_master.instance_number;

    ofs_plat_avalon_mem_rdwr_if_reg
      #(
        .N_REG_STAGES(N_REG_STAGES)
        )
      conn_reg
       (
        .mem_slave(mem_reg),
        .mem_master(mem_master)
        );

    ofs_plat_avalon_mem_rdwr_if_connect_master_clk
      conn_direct
       (
        .mem_slave(mem_slave),
        .mem_master(mem_reg)
        );

endmodule // ofs_plat_avalon_mem_rdwr_if_reg_master_clk
