// Optional ROM overlay: the stock ROMs stay in the core as constants; this
// RAM is written from the FILELOAD stream and selected only when the matching
// "loaded" flag is set.  A missing/invalid file leaves the flag clear and the
// stock ROM is used.
`timescale 1ns / 1ps
`default_nettype none

module c64_rom_ov #(
	parameter AW = 13
) (
	input wire            clk,
	input wire [AW-1:0]   addr,
	output reg [7:0]      do,

	input wire            wr_clk,
	input wire [AW-1:0]   wr_addr,
	input wire [7:0]      wr_data,
	input wire            wr_en
);

reg [7:0] mem [0:(1<<AW)-1];

always @(posedge clk)
	do <= mem[addr];

always @(posedge wr_clk)
	if (wr_en)
		mem[wr_addr] <= wr_data;

endmodule
`default_nettype wire
