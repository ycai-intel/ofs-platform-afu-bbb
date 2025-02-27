// Copyright (C) 2022 Intel Corporation
// SPDX-License-Identifier: MIT


//
// Generate TLP writes for AFU write requests.
//

`include "ofs_plat_if.vh"

module ofs_plat_host_chan_@group@_gen_wr_tlps
   (
    input  logic clk,
    input  logic reset_n,

    // Write requests from AFU (t_gen_tx_afu_wr_req)
    ofs_plat_axi_stream_if.to_source afu_wr_req,

    // Output write request TLP stream
    ofs_plat_axi_stream_if.to_sink tx_wr_tlps,

    // Write responses to AFU once the packet is completely sent (t_gen_tx_afu_wr_rsp)
    ofs_plat_axi_stream_if.to_sink afu_wr_rsp,

    // Write completions from the FIM gasket, indicating the commit point
    // of a write has been reached. Write completions are generated either
    // by the FIM gasket or by the FIM (t_gen_tx_wr_cpl).
    ofs_plat_axi_stream_if.to_source wr_cpl,

    // Atomic completion tags are allocated by sending a dummy read through the
    // read pipeline. Response tags are attached to the atomic write request
    // through this stream. (t_dma_rd_tag)
    ofs_plat_axi_stream_if.to_source atomic_cpl_tag,

    // Fence completions, processed first by the read response pipeline.
    // (t_gen_tx_wr_cpl)
    ofs_plat_axi_stream_if.to_source wr_fence_cpl,

    // Interrupt completions from the FIU (t_ofs_plat_pcie_hdr_irq)
    ofs_plat_axi_stream_if.to_source irq_cpl,

    output logic error
    );

    import ofs_plat_host_chan_@group@_pcie_tlp_pkg::*;
    import ofs_plat_host_chan_@group@_gen_tlps_pkg::*;
    import ofs_plat_pcie_tlp_@group@_hdr_pkg::*;

    assign error = 1'b0;

    // Byte index in a line to dword index
    function automatic logic [$bits(t_tlp_payload_line_byte_idx)-3:0] dw_idx(
        t_tlp_payload_line_byte_idx b_idx
        );
        return b_idx[$bits(t_tlp_payload_line_byte_idx)-1 : 2];
    endfunction


    // ====================================================================
    //
    //  Store requests in a FIFO for timing.
    //
    // ====================================================================

    t_gen_tx_afu_wr_req wr_req;
    logic wr_req_deq;
    logic wr_req_notEmpty;
    logic wr_req_ready;

    // Pre-compute OR of high address bits, needed for choosing either
    // MWr32 or MWr64. PCIe doesn't allow MWr64 when the address fits
    // in 32 bits.
    logic wr_req_is_addr64;
    logic afu_wr_req_is_addr64;
    assign afu_wr_req_is_addr64 = |(afu_wr_req.t.data.addr[63:32]);

    // Canonicalize afu_wr_req
    t_gen_tx_afu_wr_req afu_wr_req_c;
    always_comb
    begin
        afu_wr_req_c = afu_wr_req.t.data;

        if (!afu_wr_req.t.data.enable_byte_range)
        begin
            afu_wr_req_c.byte_start_idx = 0;
        end
    end

    // Pre-compute some byte range handling details on the way in to the
    // skid buffer.
    typedef struct packed {
        t_tlp_payload_line_byte_idx dword_len;
        t_tlp_payload_line_byte_idx byte_end_idx;
    } t_byte_range_req;

    t_byte_range_req br_req_in, br_req;
    assign br_req_in.dword_len =
        (afu_wr_req.t.data.byte_start_idx[1:0] + afu_wr_req.t.data.byte_len + 3) >> 2;
    assign br_req_in.byte_end_idx =
        afu_wr_req.t.data.byte_len + afu_wr_req.t.data.byte_start_idx - 1;

    ofs_plat_prim_ready_enable_reg
      #(
        .N_DATA_BITS(1 + $bits(t_byte_range_req) + $bits(t_gen_tx_afu_wr_req))
        )
      afu_req_fifo
       (
        .clk,
        .reset_n,

        .data_from_src({ afu_wr_req_is_addr64, br_req_in, afu_wr_req_c }),
        .enable_from_src(afu_wr_req.tvalid),
        .ready_to_src(afu_wr_req.tready),

        .data_to_dst({ wr_req_is_addr64, br_req, wr_req }),
        .ready_from_dst(wr_req_deq),
        .enable_to_dst(wr_req_notEmpty)
        );


    // ====================================================================
    //
    //  Maintain a UID space for tagging PCIe write fences.
    //
    // ====================================================================

    typedef logic [$clog2(MAX_OUTSTANDING_DMA_WR_FENCES)-1 : 0] t_wr_fence_tag;

    logic wr_rsp_notFull;
    logic req_fence_tlp_tag_ready;
    t_wr_fence_tag req_fence_tlp_tag;

    logic free_wr_fence_tlp_tag;
    t_gen_tx_wr_cpl wr_fence_cpl_reg;

    //
    // Track write addresses so a fence can use the most recent address.
    //
    logic last_wr_addr_valid;
    logic last_wr_is_addr64;
    logic [63:0] last_wr_addr;

    always_ff @(posedge clk)
    begin
        // Track last write address (used in next fence)
        if (wr_req_deq && wr_req.sop && !wr_req.is_fence && !wr_req.is_interrupt)
        begin
            last_wr_addr <= wr_req.addr;
            last_wr_is_addr64 <= wr_req_is_addr64;
            last_wr_addr_valid <= 1'b1;
        end

        if (!reset_n)
        begin
            last_wr_addr_valid <= 1'b0;
        end
    end

    logic alloc_fence_tlp_tag;
    assign alloc_fence_tlp_tag = wr_req_deq && wr_req.sop &&
                                 wr_req.is_fence && last_wr_addr_valid;

    // AFU asked for a fence but there hasn't been a write. No address to
    // use and no point in a fence!
    logic wr_req_is_invalid_fence;
    assign wr_req_is_invalid_fence = wr_req.is_fence && !last_wr_addr_valid;

    ofs_plat_prim_uid
      #(
        .N_ENTRIES(MAX_OUTSTANDING_DMA_WR_FENCES)
        )
      fence_tags
       (
        .clk,
        .reset_n,

        // New tag needed when either the write fence tag stream is ready
        // (the stream holds a couple of entries) or a read request was
        // processed.
        .alloc(alloc_fence_tlp_tag),
        .alloc_ready(req_fence_tlp_tag_ready),
        .alloc_uid(req_fence_tlp_tag),

        .free(free_wr_fence_tlp_tag),
        .free_uid(t_wr_fence_tag'(wr_fence_cpl_reg.tag))
        );


    //
    // Register fence completion tags until forwarded to the AFU.
    //
    logic wr_fence_cpl_reg_valid;
    assign free_wr_fence_tlp_tag = wr_rsp_notFull && wr_fence_cpl_reg_valid;
    assign wr_fence_cpl.tready = !wr_fence_cpl_reg_valid;

    always_ff @(posedge clk)
    begin
        if (!wr_fence_cpl_reg_valid)
        begin
            wr_fence_cpl_reg_valid <= wr_fence_cpl.tvalid;
            wr_fence_cpl_reg <= wr_fence_cpl.t.data;
        end
        else
        begin
            // Fence completions get priority. As long as the outbound FIFO
            // has space the fence completion will be handled.
            wr_fence_cpl_reg_valid <= !wr_rsp_notFull;
        end

        if (!reset_n)
        begin
            wr_fence_cpl_reg_valid <= 1'b0;
        end
    end

    // Save the AFU tag associated with a write fence
    t_dma_afu_tag wr_fence_afu_tag;

    ofs_plat_prim_lutram
      #(
        .N_ENTRIES(MAX_OUTSTANDING_DMA_WR_FENCES),
        .N_DATA_BITS(AFU_TAG_WIDTH)
        )
      fence_meta
       (
        .clk,
        .reset_n,

        .wen(alloc_fence_tlp_tag),
        .waddr(req_fence_tlp_tag),
        .wdata(wr_req.tag),

        .raddr(t_wr_fence_tag'(wr_fence_cpl_reg.tag)),
        .rdata(wr_fence_afu_tag)
        );


    // ====================================================================
    //
    //  Handle byte range requests (writing less than a full line).
    //  Shift counts, payload sizes and masks must be computed.
    //
    //  Logic here with the prefix "br_req" is valid only when
    //  wr_req.enable_byte_range is true. Logic with the prefix "wr_req"
    //  is always valid.
    //
    // ====================================================================

    //
    // Byte enable for the first DWORD. (PCIe address granularity is 32
    // bit words, with 4-bit enable masks on the first and last DWORDs.)
    //
    logic [3:0] br_req_hdr_first_be;
    logic [3:0] first_dword_mask;
    always_comb
    begin
        first_dword_mask = 4'hf;
        if (wr_req.byte_len < 4)
        begin
            // Only one DWORD in the payload. The mask may describe both
            // the start and the end positions.
            case (wr_req.byte_len[1:0])
              2'b01 : first_dword_mask = 4'h1;
              2'b10 : first_dword_mask = 4'h3;
              2'b11 : first_dword_mask = 4'h7;
              default : first_dword_mask = 4'h0;
            endcase
        end
        br_req_hdr_first_be = first_dword_mask << wr_req.byte_start_idx[1:0];
    end

    //
    // Byte enable for the last DWORD.
    //
    logic [3:0] br_req_hdr_last_be;

    always_comb
    begin
        br_req_hdr_last_be = 4'h0;

        // Check if first DW and last DW are the same DW in the CL. PCIe
        // requires that the last byte enable be 0 when the payload length
        // is 1 DWORD.
        if (dw_idx(wr_req.byte_start_idx) != dw_idx(br_req.byte_end_idx))
        begin
            case (br_req.byte_end_idx[1:0])
              2'b00 : br_req_hdr_last_be = 4'h1;
              2'b01 : br_req_hdr_last_be = 4'h3;
              2'b10 : br_req_hdr_last_be  = 4'h7;
              default : br_req_hdr_last_be = 4'hf;
            endcase
        end
    end

    logic [63:0] wr_req_addr;
    always_comb
    begin
        wr_req_addr = wr_req.addr;
        wr_req_addr[$bits(t_tlp_payload_line_byte_idx)-1 : 2] = dw_idx(wr_req.byte_start_idx);

        // Special case for atomic compare and swap to point to the address
        // to update after rearranging the relative order of compare and swap
        // operands.
        if (wr_req.atomic_op == TLP_ATOMIC_CAS)
        begin
            wr_req_addr[3:2] = wr_req.addr[3:2];
        end
    end


    // ====================================================================
    //
    //  Map AFU write requests to TLPs
    //
    // ====================================================================

    logic fake_fence_rsp_notFull;

    assign wr_req_ready = wr_req_notEmpty && req_fence_tlp_tag_ready &&
                          (!wr_req.is_atomic || atomic_cpl_tag.tvalid);
    assign wr_req_deq = wr_req_ready && fake_fence_rsp_notFull &&
                        (tx_wr_tlps.tready || !tx_wr_tlps.tvalid);

    assign atomic_cpl_tag.tready = wr_req_deq && wr_req.is_atomic;

    t_ofs_plat_pcie_hdr tlp_mem_hdr;

    always_comb
    begin
        tlp_mem_hdr = '0;

        tlp_mem_hdr.vchan = wr_req.vchan;

        if (wr_req.is_fence)
        begin
            // Fence
            tlp_mem_hdr.fmttype = last_wr_is_addr64 ? OFS_PLAT_PCIE_FMTTYPE_MEM_READ64 :
                                                      OFS_PLAT_PCIE_FMTTYPE_MEM_READ32;
            tlp_mem_hdr.length = 1;
            tlp_mem_hdr.u.mem_req.addr = last_wr_addr;
            tlp_mem_hdr.u.mem_req.tag = req_fence_tlp_tag;
        end
        else if (wr_req.is_interrupt)
        begin
            // Interrupt ID is passed in from the AFU using the tag
            tlp_mem_hdr.u.irq.irq_id = wr_req.tag[$bits(t_ofs_plat_pcie_hdr_irq_id)-1 : 0];
            tlp_mem_hdr.is_irq = 1'b1;
            tlp_mem_hdr.length = 1;
        end
        else
        begin
            // Normal write or atomic - start with 32 bit addresses and compute that next
            unique case (wr_req.atomic_op)
                TLP_ATOMIC_FADD: tlp_mem_hdr.fmttype = OFS_PLAT_PCIE_FMTTYPE_FETCH_ADD32;
                TLP_ATOMIC_SWAP: tlp_mem_hdr.fmttype = OFS_PLAT_PCIE_FMTTYPE_SWAP32;
                TLP_ATOMIC_CAS:  tlp_mem_hdr.fmttype = OFS_PLAT_PCIE_FMTTYPE_CAS32;
                default:         tlp_mem_hdr.fmttype = OFS_PLAT_PCIE_FMTTYPE_MEM_WRITE32;
            endcase

            // 32 vs. 64 bit address encoding differs by 1 bit in all cases above
            if (wr_req_is_addr64)
            begin
                tlp_mem_hdr.fmttype[5] = 1'b1;
            end

            tlp_mem_hdr.length =
                (wr_req.enable_byte_range ? br_req.dword_len :
                                            lineCountToDwordLen(wr_req.line_count));
            tlp_mem_hdr.u.mem_req.addr = wr_req_addr;
            // For atomic requests, get the tag from the read pipeline so read data
            // flows properly back to the AFU. The write response tag is passed
            // along in user.afu_tag below.
            tlp_mem_hdr.u.mem_req.tag = (wr_req.is_atomic ? atomic_cpl_tag.t.data : wr_req.tag);

            if (!wr_req.is_atomic)
            begin
                tlp_mem_hdr.u.mem_req.last_be = (wr_req.enable_byte_range ? br_req_hdr_last_be : 4'b1111);
                tlp_mem_hdr.u.mem_req.first_be = (wr_req.enable_byte_range ? br_req_hdr_first_be : 4'b1111);
            end
        end
    end

    // Shift the payload to the first DWORD used. The shift only happens when
    // a partial line is being written, using a byte range.
    logic [PAYLOAD_LINE_SIZE-1 : 0] wr_req_shifted_payload;
    ofs_plat_prim_rshift_words_comb
      #(
        .DATA_WIDTH(PAYLOAD_LINE_SIZE),
        .WORD_WIDTH(32)
        )
      pshift_data
       (
        .d_in(wr_req.payload),
        .rshift_cnt(dw_idx(wr_req.byte_start_idx)),
        .d_out(wr_req_shifted_payload)
        );

    // Generate a keep mask for the payload. Shifting above guarantees that data
    // always begins at bit 0, so this mask always begins from the low bits.
    logic [(PAYLOAD_LINE_SIZE/8)-1 : 0] wr_req_shifted_keep;
    // Start by shifting a vector where 1 bit masks each dword.
    logic [(PAYLOAD_LINE_SIZE/32)-1 : 0] wr_req_shifted_keep_dword;
    assign wr_req_shifted_keep_dword = {(PAYLOAD_LINE_SIZE/32){1'b1}} << tlp_mem_hdr.length;
    // Map dword to byte mask
    always_comb
    begin
        for (int w = 0; w < PAYLOAD_LINE_SIZE/32; w = w + 1)
        begin
            // The shifted vector held all ones to simplify the code. Invert it
            // to generate the mask.
            wr_req_shifted_keep[w*4 +: 4] = {4{~wr_req_shifted_keep_dword[w]}};
        end
    end

    logic tx_wr_is_eop;
    assign tx_wr_is_eop = wr_req_notEmpty &&
                          (wr_req.is_fence || wr_req.is_interrupt || wr_req.eop);

    logic [PAYLOAD_LINE_SIZE-1 : 0] tx_wr_tlps_data;
    logic tx_wr_tlps_need_swap32, tx_wr_tlps_need_swap64;

    always_ff @(posedge clk)
    begin
        if (tx_wr_tlps.tready || !tx_wr_tlps.tvalid)
        begin
            tx_wr_tlps.tvalid <= wr_req_ready && fake_fence_rsp_notFull;

            tx_wr_tlps.t.last <= |(tx_wr_is_eop);

            tx_wr_tlps.t.user <= '0;
            tx_wr_tlps.t.user[0].sop <= wr_req_notEmpty && wr_req.sop;
            tx_wr_tlps.t.user[0].eop <= tx_wr_is_eop;
            tx_wr_tlps.t.user[0].poison <= wr_req_is_invalid_fence;

            tx_wr_tlps.t.user[0].hdr <= (wr_req.sop ? tlp_mem_hdr : '0);

            // It is always safe to use the shifted payload since byte_start_idx
            // is guaranteed by the canonicalization step above to be 0 when in
            // full-line mode. Using the value from the shifter avoids an extra MUX.
            // The payload is registered separately because there may be one more
            // swap required to put atomic compare and exchange data in the right
            // place. Since wr_reg_shifted_payload already has a complex shifter,
            // the swap is moved to the next cycle for timing.
            tx_wr_tlps_data <= wr_req_shifted_payload;
            tx_wr_tlps_need_swap32 <=
                (wr_req.atomic_op == TLP_ATOMIC_CAS) && (wr_req.byte_len == 8) && wr_req.addr[2];
            tx_wr_tlps_need_swap64 <=
                (wr_req.atomic_op == TLP_ATOMIC_CAS) && (wr_req.byte_len == 16) && wr_req.addr[3];

            // If the cycle isn't SOP, then keep covers the whole line because
            // of PIM rules. Partial line writes are permitted only for
            // short, single-line requests .
            tx_wr_tlps.t.keep <= wr_req.sop ? { '0, wr_req_shifted_keep } : ~'0;

            // The AFU tag expected as a write commit completion.
            tx_wr_tlps.t.user[0].afu_tag <= wr_req.tag;
        end

        if (!reset_n)
        begin
            tx_wr_tlps.tvalid <= 1'b0;
        end
    end

    always_comb
    begin
        tx_wr_tlps.t.data[0] = { '0, tx_wr_tlps_data };

        // Swap the low 32 or 64 bit values for atomic CAS?
        if (tx_wr_tlps_need_swap32)
            tx_wr_tlps.t.data[0][63:0] = { tx_wr_tlps_data[31:0], tx_wr_tlps_data[63:32] };
        else if (tx_wr_tlps_need_swap64)
            tx_wr_tlps.t.data[0][127:0] = { tx_wr_tlps_data[63:0], tx_wr_tlps_data[127:64] };
    end


    // Failed fence response queue. When there has been no write, fences are pointless
    // and there is no address available. The write response is returned, but no
    // fence is actually generated.
    logic fake_fence_rsp_valid;
    logic fake_fence_rsp_deq;
    t_dma_afu_tag fake_fence_afu_tag;
    t_ofs_plat_pcie_hdr_vchan fake_fence_vchan;

    ofs_plat_prim_fifo2
      #(
        .N_DATA_BITS(AFU_TAG_WIDTH + $bits(t_ofs_plat_pcie_hdr_vchan))
        )
      fake_fence_rsp_fifo
       (
        .clk,
        .reset_n,

        .enq_data({ wr_req.tag, wr_req.vchan }),
        .enq_en(wr_req_deq && wr_req.eop && wr_req.is_fence && !last_wr_addr_valid),
        .notFull(fake_fence_rsp_notFull),

        .first({ fake_fence_afu_tag, fake_fence_vchan }),
        .deq_en(fake_fence_rsp_deq),
        .notEmpty(fake_fence_rsp_valid)
        );


    // ====================================================================
    //
    //  Register incoming interrupt completion. Don't bother pipelining
    //  interrupt completions. They are very infrequent.
    //
    // ====================================================================

    logic irq_cpl_reg_valid;
    assign irq_cpl.tready = !irq_cpl_reg_valid;

    t_ofs_plat_pcie_hdr_irq irq_cpl_reg;

    always_ff @(posedge clk)
    begin
        if (!irq_cpl_reg_valid)
        begin
            // IRQ completion register not occupied. Take any new completion.
            irq_cpl_reg_valid <= irq_cpl.tvalid;
            irq_cpl_reg <= irq_cpl.t.data;
        end
        else if (wr_rsp_notFull && !wr_fence_cpl_reg_valid)
        begin
            // Can forward a registered completion this cycle. (Fences get
            // priority.)
            irq_cpl_reg_valid <= 1'b0;
        end

        if (!reset_n)
        begin
            irq_cpl_reg_valid <= 1'b0;
        end
    end


    // ====================================================================
    //
    //  Generate write response for:
    //   - Final packet of a normal write
    //   - Write fence completion
    //   - Interrupt completion
    //
    // ====================================================================

    // Standard write responses come from the FIM gasket. The AFU expects
    // write responses to know when each write has been committed to the
    // PCIe stream.
    logic std_wr_rsp_valid;
    logic std_wr_rsp_deq;
    t_tlp_payload_line_idx std_wr_rsp_line_idx;
    t_gen_tx_wr_cpl std_wr_rsp;

    ofs_plat_prim_fifo2
      #(
        .N_DATA_BITS($bits(t_gen_tx_wr_cpl))
        )
      std_wr_rsp_fifo
       (
        .clk,
        .reset_n,

        .enq_data(wr_cpl.t.data),
        .enq_en(wr_cpl.tready && wr_cpl.tvalid),
        .notFull(wr_cpl.tready),

        .first(std_wr_rsp),
        .deq_en(std_wr_rsp_deq),
        .notEmpty(std_wr_rsp_valid)
        );


    t_gen_tx_afu_wr_rsp wr_rsp;
    always_comb
    begin
        fake_fence_rsp_deq = 1'b0;
        std_wr_rsp_deq = 1'b0;

        if (wr_fence_cpl_reg_valid)
        begin
            wr_rsp.is_fence = 1'b1;
            wr_rsp.is_interrupt = 1'b0;
            wr_rsp.tag = wr_fence_afu_tag;
            wr_rsp.vchan = wr_fence_cpl_reg.vchan;
            wr_rsp.line_idx = 0;
        end
        else if (irq_cpl_reg_valid)
        begin
            wr_rsp.is_fence = 1'b0;
            wr_rsp.is_interrupt = 1'b1;
            wr_rsp.tag = { '0, irq_cpl_reg.irq_id };
            wr_rsp.vchan = t_ofs_plat_pcie_hdr_vchan'(irq_cpl_reg.requester_id);
            wr_rsp.line_idx = 0;
        end
        else if (fake_fence_rsp_valid)
        begin
            wr_rsp.is_fence = 1'b1;
            wr_rsp.is_interrupt = 1'b0;
            wr_rsp.tag = fake_fence_afu_tag;
            wr_rsp.vchan = fake_fence_vchan;
            wr_rsp.line_idx = 0;
            fake_fence_rsp_deq = wr_rsp_notFull;
        end
        else
        begin
            wr_rsp.is_fence = 1'b0;
            wr_rsp.is_interrupt = 1'b0;
            wr_rsp.tag = std_wr_rsp.tag;
            wr_rsp.vchan = std_wr_rsp.vchan;
            wr_rsp.line_idx = std_wr_rsp.line_count - 1;
            std_wr_rsp_deq = std_wr_rsp_valid && wr_rsp_notFull;
        end
    end

    ofs_plat_prim_fifo2
      #(
        .N_DATA_BITS($bits(t_gen_tx_afu_wr_rsp))
        )
      afu_rsp_fifo
       (
        .clk,
        .reset_n,

        .enq_data(wr_rsp),
        // Send a write response for the end of a normal write, when a
        // write fence completion arrives, or when an interrupt completes.
        .enq_en(wr_rsp_notFull && (std_wr_rsp_valid || wr_fence_cpl_reg_valid || irq_cpl_reg_valid ||
                                   fake_fence_rsp_valid)),
        .notFull(wr_rsp_notFull),

        .first(afu_wr_rsp.t.data),
        .deq_en(afu_wr_rsp.tvalid && afu_wr_rsp.tready),
        .notEmpty(afu_wr_rsp.tvalid)
        );

    assign afu_wr_rsp.t.last = 1'b1;
    assign afu_wr_rsp.t.user = '0;

endmodule // ofs_plat_host_chan_@group@_gen_wr_tlps
