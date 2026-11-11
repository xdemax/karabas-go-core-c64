// C1530 tape player for the Karabas C64 core.
//
// The whole TAP image is already in SRAM at 0x160000..0x1DFFFF (loaded by
// c64_tap_loader).  A small FIFO is prefetched from SRAM and the C1530 core
// consumes it.  The C64 controls playback with the cassette motor line; the
// tape is "present" (cass_sense = 0) while an image is loaded.
`timescale 1ns / 1ps
`default_nettype none

module c64_tape (
	input wire        clk,                 // clk_sys
	input wire        reset,

	input wire        tap_loaded,
	input wire [19:0] tap_size,
	input wire [1:0]  tap_version,
	input wire        loader_error,

	// SRAM tape-read port (0x160000 + addr)
	output reg        tap_rd_req,
	output reg [18:0] tap_rd_addr,
	input wire [15:0] tap_rd_data,
	input wire        tap_rd_ack,

	// C64 cassette lines
	input wire        cass_motor,
	input wire        cass_write,
	output wire       cass_read,
	output wire       cass_sense,
	output wire       cass_run,

	output wire [19:0] tap_play_addr,
	output wire        tap_end,
	output wire        tap_error
);

reg  [1:0] tap_loaded_s;
wire       tap_loaded_sync = tap_loaded_s[1];
reg        tap_loaded_d;
wire       load_start = tap_loaded_sync & ~tap_loaded_d;
wire       restart = reset | ~tap_loaded_sync | load_start;

always @(posedge clk)
	tap_loaded_s <= {tap_loaded_s[0], tap_loaded};

always @(posedge clk)
	tap_loaded_d <= tap_loaded_sync;

// FIFO between the SRAM prefetch and c1530.
reg        fifo_wr;
wire       fifo_full;
wire [7:0] fifo_dout;
wire       fifo_empty;
wire       fifo_rd;

kg_fifo #(.DW(8), .AW(6)) fifo
(
	.clk(clk),
	.reset(restart),
	.wr(fifo_wr),
	.din(tap_rd_data[7:0]),
	.full(fifo_full),
	.rd(fifo_rd),
	.dout(fifo_dout),
	.empty(fifo_empty),
	.count()
);

// Prefetch one byte at a time from SRAM while the FIFO has room.
reg [19:0] play_addr;
reg        rd_busy;

always @(posedge clk) begin
	tap_rd_req <= 1'b0;
	fifo_wr <= 1'b0;

	if (restart) begin
		play_addr <= 20'd0;
		rd_busy <= 1'b0;
		tap_rd_addr <= 19'd0;
	end
	else begin
		if (rd_busy) begin
			tap_rd_req <= 1'b1; // held until ack
			if (tap_rd_ack) begin
				tap_rd_req <= 1'b0;
				fifo_wr <= 1'b1;
				play_addr <= play_addr + 20'd1;
				rd_busy <= 1'b0;
			end
		end
		else if (!fifo_full && !tap_rd_ack && (play_addr < tap_size)) begin
			tap_rd_req <= 1'b1;
			tap_rd_addr <= play_addr[18:0];
			rd_busy <= 1'b1;
		end
	end
end

wire core_fifo_rd;
wire core_fifo_error;

c1530_core player
(
	.clk32(clk),
	.restart_tape(restart),
	.tap_version(tap_version),
	.fifo_do(fifo_dout),
	.fifo_empty(fifo_empty),
	.fifo_rdreq(core_fifo_rd),
	.fifo_error(core_fifo_error),
	.cass_sense(cass_sense),
	.cass_read(cass_read),
	.cass_write(cass_write),
	.cass_motor(cass_motor),
	.cass_run(cass_run)
);

assign fifo_rd = core_fifo_rd;
assign cass_sense = ~tap_loaded_sync;
assign tap_play_addr = play_addr;
assign tap_end = tap_loaded_sync && (play_addr >= tap_size) && fifo_empty;
assign tap_error = core_fifo_error | loader_error;

endmodule
`default_nettype wire
