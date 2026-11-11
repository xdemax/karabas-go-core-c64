// D64 byte follower for the UnoXT 1541 (c1541_sd / c1541_gcr).
//
// Replaces c64_d64_cache.  c1541_gcr only changes byte_addr on a bit_clk_en
// edge and consumes ram_do at the next bit_clk_en, >=112 clk_sys later, so the
// byte does not have to be asynchronous: it is enough that dsk_data_in
// follows dsk_addr within a few tens of clocks.  This module re-reads the D64
// byte from SRAM (via the c64_memory D64 port) whenever dsk_addr changes.
//
// The old sector cache held mem_rd high for the whole 256-byte fill.  The
// c64_memory D64 port treats d_rd as a level (and keeps d_ack high while d_rd
// is high), so the cache captured the same byte on several consecutive clocks
// and stored a shifted sector.  Here mem_rd is raised with a stable mem_addr,
// held until mem_ack, then dropped for at least 2 clocks before the next
// request (works for both level- and edge-triggered ports).
//
// CAP_LATE=1: mem_data is sampled one clock after mem_ack (same as the old
//             cache used with ack_d).  CAP_LATE=0: sampled in the ack cycle.
//
// invalidate is held high while the D64 loader is writing the image; it
// clears the captured byte so that the drive re-reads after the image is
// complete.

`timescale 1ns / 1ps
`default_nettype none

module c64_d64_rd #(
	parameter CAP_LATE = 1
)(
	input wire        clk,              // clk_sys
	input wire        reset,
	input wire        invalidate,       // D64 loader busy

	input wire [18:0] dsk_addr,
	output reg [7:0]  dsk_data_in,

	output reg [18:0] mem_addr,
	output reg        mem_rd,
	input wire [7:0]  mem_data,
	input wire        mem_ack
);

localparam [1:0] S_IDLE = 2'd0,
                 S_REQ  = 2'd1,
                 S_CAP  = 2'd2,
                 S_GAP  = 2'd3;

reg [1:0]  st;
reg        valid;
reg [18:0] cur_addr;
reg [1:0]  gap;

always @(posedge clk) begin
	if (reset) begin
		st          <= S_IDLE;
		valid       <= 1'b0;
		cur_addr    <= 19'd0;
		mem_addr    <= 19'd0;
		mem_rd      <= 1'b0;
		dsk_data_in <= 8'd0;
		gap         <= 2'd0;
	end
	else if (invalidate) begin
		// The loader is writing the image: drop the captured byte and any
		// pending request.  The next cycle after invalidate goes low starts
		// from S_IDLE and re-reads the current dsk_addr.
		st          <= S_IDLE;
		valid       <= 1'b0;
		mem_rd      <= 1'b0;
		gap         <= 2'd0;
	end
	else begin
		case (st)
		S_IDLE: begin
			mem_rd <= 1'b0;
			if (!valid || dsk_addr != cur_addr) begin
				cur_addr <= dsk_addr;
				mem_addr <= dsk_addr;
				mem_rd   <= 1'b1;
				st       <= S_REQ;
			end
		end

		S_REQ: begin
			if (mem_ack) begin
				mem_rd <= 1'b0;
				if (CAP_LATE != 0) begin
					st <= S_CAP;
				end
				else begin
					dsk_data_in <= mem_data;
					valid       <= 1'b1;
					gap         <= 2'd0;
					st          <= S_GAP;
				end
			end
		end

		S_CAP: begin
			dsk_data_in <= mem_data;
			valid       <= 1'b1;
			gap         <= 2'd0;
			st          <= S_GAP;
		end

		S_GAP: begin
			gap <= gap + 2'd1;
			if (gap == 2'd1) begin
				gap <= 2'd0;
				st  <= S_IDLE;
			end
		end
		endcase
	end
end

endmodule
`default_nettype wire
