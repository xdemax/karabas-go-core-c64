// SRAM controller of the C64 core (Karabas Mini G, IS61WV20488, 2M x 16, 10 ns).
//
// Every access takes a whole clk_sys cycle and both phases of clk_sram (2 * clk_sys):
//   phase 0: drive the address (and data / WE for a write);
//   phase 1: hold address and data, deassert WE for a write, keep OE for a read;
//   next phase 0: sample MD (the address has been stable for a full clk_sys period,
//   pad out + tAA + pad in is about 21 ns, so 32 ns is enough) and drive the next access.
//
// The C64/cartridge bus has priority.  The auxiliary port (D64, video write/read) is served in
// the clk_sys cycles where the C64 bus is idle; its requests are held until acknowledged.
//
//   byte address                word address
//   0x000000-0x00FFFF  C64 RAM   0x000000-0x00FFFF
//   0x010000-0x01FFFF  cart RAM  0x010000-0x01FFFF
//   0x200000-0x2FFFFF  cart ROM  0x020000-0x11FFFF (1 MB, the layout of cartridge.v)
//   d_addr             D64       0x120000 + d_addr[17:0] (256 KB)
//   video frame                 0x160000 / 0x1A0000 (256 KB each)
`timescale 1ns / 1ps
`default_nettype none

module c64_memory (
	input wire clk_sys,
	input wire clk_sram,
	input wire reset,

	// C64 / cartridge bus (clk_sys)
	input wire [24:0] c_addr,
	input wire        c_ce,
	input wire        c_we,
	input wire [7:0]  c_din,
	output reg [7:0]  c_dout,

	// D64 image (clk_sys): d_rd is held until d_ack
	input wire [18:0] d_addr,
	input wire        d_rd,
	input wire        d_wr,
	input wire [7:0]  d_din,
	output reg [7:0]  d_dout,
	output reg        d_ack,

	// host write port (D64 image loader, clk_host; level handshake)
	input wire        h_req,
	input wire [17:0] h_addr,
	input wire [7:0]  h_data,
	output reg        h_ack,

	// PRG injection write port (clk_host; C64 RAM, level handshake)
	input wire        p_req,
	input wire [15:0] p_addr,
	input wire [7:0]  p_data,
	output reg        p_ack,

	// C64 is held in reset by the PRG loader: its bus must not starve
	// the staging/injection ports.
	input wire        c64_hold,

	// PRG staging buffer (free SRAM 0x1E0000, clk_host; level handshakes)
	input wire        stg_req,
	input wire [15:0] stg_addr,
	input wire [7:0]  stg_data,
	output reg        stg_ack,

	input wire        rd_req,
	input wire [15:0] rd_addr,
	output reg [7:0]  rd_data,
	output reg        rd_ack,

	// CRT cartridge ROM write port (clk_host; absolute word address)
	input wire        crt_req,
	input wire [20:0] crt_addr,
	input wire [7:0]  crt_data,
	output reg        crt_ack,

	// TAP image write port (clk_host; 0x160000 + addr, 512 KB)
	input wire        tap_wr_req,
	input wire [18:0] tap_wr_addr,
	input wire [7:0]  tap_wr_data,
	output reg        tap_wr_ack,

	// TAP read port (clk_sys; 0x160000 + addr, 512 KB).
	// This port used to serve the external video frames; the video now lives in
	// BRAM, so the same 512 KB SRAM window is the TAP image.
	input wire        vr_req,
	input wire [18:0] vr_addr,
	output reg [15:0] vr_data,
	output reg        vr_ack,

	// SRAM pins
	output reg [20:0] MA = 21'd0,
	inout wire [15:0] MD,
	output reg [1:0]  MWR_N = 2'b11,
	output reg [1:0]  MRD_N = 2'b11
);

function [20:0] c_map;
	input [24:0] a;
	begin
		if (a[24:16] == 9'd0)
			c_map = {5'd0, a[15:0]};
		else if (a[24:16] == 9'd1)
			c_map = {5'd0, 1'b1, a[15:0]};
		else if (a[24:20] == 5'b00010)
			c_map = 21'h020000 + a[19:0]; // 0x200000-0x2FFFFF -> 0x020000-0x11FFFF
		else
			c_map = 21'h1FFFFF;
	end
endfunction

reg phase = 1'b0;

// one access at a time; these describe the access in flight
reg        cur_read = 1'b0;
reg        cur_c64 = 1'b0;
reg        cur_vid = 1'b0;
reg        cur_d64 = 1'b0;
reg        cur_stg = 1'b0;
reg        sram_do = 1'b0;
reg [15:0] sram_wdata = 16'd0;

// an auxiliary request held while the C64 bus is busy
reg        aux_pend = 1'b0;
reg        aux_pend_vid = 1'b0;
reg        aux_pend_wr = 1'b0;
reg        aux_pend_d64 = 1'b0;
reg [20:0] aux_pend_addr = 21'd0;
reg [15:0] aux_pend_data = 16'd0;
reg        p_busy = 1'b0;

assign MD = sram_do ? sram_wdata : 16'hzzzz;

wire [20:0] d_word = 21'h120000 + {3'b000, d_addr[17:0]};
wire [20:0] vr_word = 21'h160000 + {2'b00, vr_addr};

// host write port: synchronize the level handshake from clk_host
reg [1:0]  h_req_s = 2'b00;
reg [17:0] h_addr_s = 18'd0;
reg [7:0]  h_data_s = 8'd0;
// PRG staging ports also come from clk_host
reg [1:0]  stg_req_s = 2'b00;
reg [15:0] stg_addr_s = 16'd0;
reg [7:0]  stg_data_s = 8'd0;
reg [1:0]  rd_req_s = 2'b00;
reg [15:0] rd_addr_s = 16'd0;
reg [1:0]  crt_req_s = 2'b00;
reg [20:0] crt_addr_s = 21'd0;
reg [7:0]  crt_data_s = 8'd0;
reg [1:0]  tap_wr_req_s = 2'b00;
reg [18:0] tap_wr_addr_s = 19'd0;
reg [7:0]  tap_wr_data_s = 8'd0;
reg [1:0]  hold_s = 2'b00;
always @(posedge clk_sram) begin
	if (reset) begin
		h_req_s <= 2'b00;
		h_addr_s <= 18'd0;
		h_data_s <= 8'd0;
		stg_req_s <= 2'b00;
		stg_addr_s <= 16'd0;
		stg_data_s <= 8'd0;
		rd_req_s <= 2'b00;
		rd_addr_s <= 16'd0;
		crt_req_s <= 2'b00;
		crt_addr_s <= 21'd0;
		crt_data_s <= 8'd0;
		tap_wr_req_s <= 2'b00;
		tap_wr_addr_s <= 19'd0;
		tap_wr_data_s <= 8'd0;
		hold_s <= 2'b00;
	end
	else begin
		h_req_s <= {h_req_s[0], h_req};
		h_addr_s <= h_addr;
		h_data_s <= h_data;
		stg_req_s <= {stg_req_s[0], stg_req};
		stg_addr_s <= stg_addr;
		stg_data_s <= stg_data;
		rd_req_s <= {rd_req_s[0], rd_req};
		rd_addr_s <= rd_addr;
		crt_req_s <= {crt_req_s[0], crt_req};
		crt_addr_s <= crt_addr;
		crt_data_s <= crt_data;
		tap_wr_req_s <= {tap_wr_req_s[0], tap_wr_req};
		tap_wr_addr_s <= tap_wr_addr;
		tap_wr_data_s <= tap_wr_data;
		hold_s <= {hold_s[0], c64_hold};
	end
end

always @(posedge clk_sram) begin
	phase <= ~phase;

	if (reset) begin
		phase <= 1'b0;
		MA <= 21'd0;
		MWR_N <= 2'b11;
		MRD_N <= 2'b11;
		c_dout <= 8'd0;
		d_dout <= 8'd0;
		vr_data <= 16'd0;
		sram_do <= 1'b0;
		aux_pend <= 1'b0;
		h_ack <= 1'b0;
		p_ack <= 1'b0;
		p_busy <= 1'b0;
		stg_ack <= 1'b0;
		rd_ack <= 1'b0;
		rd_data <= 8'd0;
		crt_ack <= 1'b0;
		tap_wr_ack <= 1'b0;
		cur_stg <= 1'b0;
	end
	else if (phase == 1'b0) begin
		d_ack <= 1'b0;
		vr_ack <= 1'b0;
		if (!p_req) begin
			p_ack <= 1'b0;
			p_busy <= 1'b0;
		end
		if (!h_req_s[1])
			h_ack <= 1'b0;
		if (!stg_req_s[1])
			stg_ack <= 1'b0;
		if (!rd_req_s[1])
			rd_ack <= 1'b0;
		if (!crt_req_s[1])
			crt_ack <= 1'b0;
		if (!tap_wr_req_s[1])
			tap_wr_ack <= 1'b0;
		// ---- the access of the previous clk_sys cycle is complete: sample MD ----
		if (cur_read) begin
			if (cur_c64)
				c_dout <= MD[7:0];
			else if (cur_vid) begin
				vr_data <= MD;
				vr_ack <= 1'b1;
			end
			else if (cur_d64) begin
				d_dout <= MD[7:0];
				d_ack <= 1'b1;
			end
			else if (cur_stg) begin
				rd_data <= MD[7:0];
				rd_ack <= 1'b1;
			end
		end

		// ---- choose the next access ----
		if (c_ce && !hold_s[1]) begin
			// C64 / cartridge has priority; hold an auxiliary request for later
			MA <= c_map(c_addr);
			sram_do <= c_we;
			sram_wdata <= {8'h00, c_din};
			MWR_N <= c_we ? 2'b10 : 2'b11;
			MRD_N <= c_we ? 2'b11 : 2'b00;
			cur_read <= !c_we;
			cur_c64 <= 1'b1;
			cur_vid <= 1'b0;
			cur_d64 <= 1'b0;
			cur_stg <= 1'b0;

			if (!aux_pend) begin
				if (d_rd || d_wr) begin
					aux_pend <= 1'b1;
					aux_pend_vid <= 1'b0;
					aux_pend_wr <= d_wr;
					aux_pend_d64 <= 1'b1;
					aux_pend_addr <= d_word;
					aux_pend_data <= {8'h00, d_din};
				end
				else if (vr_req) begin
					aux_pend <= 1'b1;
					aux_pend_vid <= 1'b1;
					aux_pend_wr <= 1'b0;
					aux_pend_d64 <= 1'b0;
					aux_pend_addr <= vr_word;
					aux_pend_data <= 16'd0;
				end
			end
		end
		else if (p_req && !p_busy) begin
			// PRG injection: write the low byte of C64 RAM word p_addr
			MA <= {5'd0, p_addr};
			sram_do <= 1'b1;
			sram_wdata <= {8'h00, p_data};
			MWR_N <= 2'b10;
			MRD_N <= 2'b11;
			cur_read <= 1'b0;
			cur_c64 <= 1'b0;
			cur_vid <= 1'b0;
			cur_d64 <= 1'b0;
			cur_stg <= 1'b0;
			p_ack <= 1'b1;
			p_busy <= 1'b1;
		end
		else if (aux_pend) begin
			MA <= aux_pend_addr;
			sram_do <= aux_pend_wr;
			sram_wdata <= aux_pend_data;
			MWR_N <= aux_pend_wr ? 2'b00 : 2'b11;
			MRD_N <= aux_pend_wr ? 2'b11 : 2'b00;
			cur_read <= !aux_pend_wr;
			cur_c64 <= 1'b0;
			cur_vid <= aux_pend_vid;
			cur_d64 <= aux_pend_d64;
			cur_stg <= 1'b0;
			aux_pend <= 1'b0;
		end
		else if (stg_req_s[1] && !stg_ack) begin
			// PRG staging: write the low byte to free SRAM 0x1E0000 + addr
			MA <= 21'h1E0000 + {5'd0, stg_addr_s};
			sram_do <= 1'b1;
			sram_wdata <= {8'h00, stg_data_s};
			MWR_N <= 2'b10;
			MRD_N <= 2'b11;
			cur_read <= 1'b0;
			cur_c64 <= 1'b0;
			cur_vid <= 1'b0;
			cur_d64 <= 1'b0;
			cur_stg <= 1'b0;
			stg_ack <= 1'b1;
		end
		else if (rd_req_s[1] && !rd_ack) begin
			// PRG staging read; data is sampled with rd_ack
			MA <= 21'h1E0000 + {5'd0, rd_addr_s};
			sram_do <= 1'b0;
			MWR_N <= 2'b11;
			MRD_N <= 2'b00;
			cur_read <= 1'b1;
			cur_c64 <= 1'b0;
			cur_vid <= 1'b0;
			cur_d64 <= 1'b0;
			cur_stg <= 1'b1;
		end
		else if (crt_req_s[1] && !crt_ack) begin
			// CRT cartridge loader: write one byte at the absolute word address
			MA <= crt_addr_s;
			sram_do <= 1'b1;
			sram_wdata <= {8'h00, crt_data_s};
			MWR_N <= 2'b10;
			MRD_N <= 2'b11;
			cur_read <= 1'b0;
			cur_c64 <= 1'b0;
			cur_vid <= 1'b0;
			cur_d64 <= 1'b0;
			cur_stg <= 1'b0;
			crt_ack <= 1'b1;
		end
		else if (tap_wr_req_s[1] && !tap_wr_ack) begin
			// TAP image loader: write one byte to 0x160000 + addr (512 KB region)
			MA <= 21'h160000 + {2'b00, tap_wr_addr_s};
			sram_do <= 1'b1;
			sram_wdata <= {8'h00, tap_wr_data_s};
			MWR_N <= 2'b10;
			MRD_N <= 2'b11;
			cur_read <= 1'b0;
			cur_c64 <= 1'b0;
			cur_vid <= 1'b0;
			cur_d64 <= 1'b0;
			cur_stg <= 1'b0;
			tap_wr_ack <= 1'b1;
		end
		else if (h_req_s[1] && !h_ack) begin
			// D64 image loader: write one byte to 0x120000 + h_addr
			MA <= 21'h120000 + {3'b000, h_addr_s};
			sram_do <= 1'b1;
			sram_wdata <= {8'h00, h_data_s};
			MWR_N <= 2'b10;
			MRD_N <= 2'b11;
			cur_read <= 1'b0;
			cur_c64 <= 1'b0;
			cur_vid <= 1'b0;
			cur_d64 <= 1'b0;
			cur_stg <= 1'b0;
			h_ack <= 1'b1;
		end
		else if (d_rd || d_wr) begin
			MA <= d_word;
			sram_do <= d_wr;
			sram_wdata <= {8'h00, d_din};
			MWR_N <= d_wr ? 2'b10 : 2'b11;
			MRD_N <= d_wr ? 2'b11 : 2'b00;
			cur_read <= !d_wr;
			cur_c64 <= 1'b0;
			cur_vid <= 1'b0;
			cur_d64 <= 1'b1;
			cur_stg <= 1'b0;
		end
		else if (vr_req) begin
			MA <= vr_word;
			sram_do <= 1'b0;
			MWR_N <= 2'b11;
			MRD_N <= 2'b00;
			cur_read <= 1'b1;
			cur_c64 <= 1'b0;
			cur_vid <= 1'b1;
			cur_d64 <= 1'b0;
			cur_stg <= 1'b0;
		end
		else begin
			sram_do <= 1'b0;
			MWR_N <= 2'b11;
			MRD_N <= 2'b11;
			cur_read <= 1'b0;
			cur_stg <= 1'b0;
		end
	end
	else begin
		// ---- phase 1: hold the address and data; end a write pulse ----
		if (MWR_N != 2'b11)
			MWR_N <= 2'b11;
		// MRD_N stays low: the read data is sampled at the next phase 0
	end
end

endmodule
`default_nettype wire
