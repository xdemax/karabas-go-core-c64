// D64 image loader for the C64 core.
//
// The Karabas firmware exposes the mounted disk image as 512-byte sectors
// through img_sdc (IMG_* of kg_mcu).  The old UnoXT 1541 (c1541_sd) wants a
// linear raw D64 image at SRAM word 0x120000, one byte per 16-bit word.
//
// This module reads the image sector by sector, buffers one 512-byte sector,
// then writes it to the SRAM through the host port of c64_memory.  It runs in
// the clk_host domain (same as img_sdc), the host port has a level handshake
// and is synchronized inside c64_memory.
//
// Slot 0 is the disk.  c64_img_mount gives the persistent mount bit and the
// size captured for this slot, so a ROM mount in another slot (which changes
// the global IMG_SIZE) can never restart the disk load.

`timescale 1ns / 1ps
`default_nettype none

module c64_d64_loader (
	input wire clk,                       // clk_host
	input wire reset,                     // power-on only

	// mount tracker (slot 0)
	input wire [7:0]  img_mounted,
	input wire [63:0] img_size,
	input wire        mount_pulse,
	input wire        eject_pulse,

	// img_sdc sector read interface (slot 0)
	output reg [7:0]  sdc_rd,
	output reg [31:0] sdc_sector,
	input wire        sdc_busy,
	input wire        sdc_done,
	input wire        sdc_error,
	input wire [2:0]  sdc_slot,
	input wire        sdc_byte_strobe,
	input wire [8:0]  sdc_byte_addr,
	input wire [7:0]  sdc_byte_data,

	// SRAM host write port (level handshake)
	output reg        h_req,
	output reg [17:0] h_addr,
	output reg [7:0]  h_data,
	input wire        h_ack,

	// status
	output reg        busy,
	output reg        ready
);

localparam S_IDLE  = 3'd0;
localparam S_REQ   = 3'd1;
localparam S_WAIT  = 3'd2;
localparam S_WR    = 3'd3;
localparam S_ACKW  = 3'd4;
localparam S_DRAIN = 3'd5;

reg [2:0] state = S_IDLE;

// one sector of the image (512 bytes)
reg [7:0] sbuf [0:511];

reg [8:0]  wi = 9'd0;        // byte within the current sector
reg [31:0] sector = 32'd0;
reg [31:0] nsec = 32'd0;
reg [9:0]  nbytes = 10'd0;
reg        start_pending = 1'b0;
reg [1:0]  ack_s = 2'b00;

wire mounted = img_mounted[0];
wire [31:0] nsec_calc = (img_size + 64'd511) >> 9;

// bytes left in this sector (the last one can be shorter than 512)
wire [63:0] base64 = {32'd0, sector} << 9;
wire [63:0] rem = (img_size > base64) ? (img_size - base64) : 64'd0;
wire [9:0] nbytes_calc = (rem >= 64'd512) ? 10'd512 : rem[9:0];

always @(posedge clk)
	ack_s <= {ack_s[0], h_ack};

// capture the sector bytes from img_sdc
always @(posedge clk)
	if (sdc_byte_strobe && sdc_slot == 3'd0)
		sbuf[sdc_byte_addr] <= sdc_byte_data;

always @(posedge clk) begin
	if (reset) begin
		state <= S_IDLE;
		sdc_rd <= 8'd0;
		sdc_sector <= 32'd0;
		h_req <= 1'b0;
		h_addr <= 18'd0;
		h_data <= 8'd0;
		busy <= 1'b0;
		ready <= 1'b0;
		wi <= 9'd0;
		sector <= 32'd0;
		nsec <= 32'd0;
		nbytes <= 10'd0;
		start_pending <= 1'b0;
	end
	else begin
		if (mount_pulse) begin
			// a new disk: discard any in-flight request first
			ready <= 1'b0;
			busy  <= 1'b1;
			h_req <= 1'b0;
			start_pending <= 1'b1;
			if (sdc_busy && (sdc_slot == 3'd0)) begin
				sdc_rd <= 8'd0;
				state <= S_DRAIN;
			end
			else begin
				sector <= 32'd0;
				nsec   <= nsec_calc;
				sdc_rd <= 8'd0;
				start_pending <= 1'b0;
				state  <= S_REQ;
			end
		end
		else if (eject_pulse) begin
			start_pending <= 1'b0;
			ready <= 1'b0;
			busy  <= 1'b0;
			h_req <= 1'b0;
			sdc_rd <= 8'd0;
			if (sdc_busy && (sdc_slot == 3'd0))
				state <= S_DRAIN;
			else
				state <= S_IDLE;
		end
		else if (!mounted) begin
			sdc_rd <= 8'd0;
			h_req  <= 1'b0;
			busy   <= 1'b0;
			ready  <= 1'b0;
			start_pending <= 1'b0;
			state  <= S_IDLE;
		end
		else begin
			case (state)
			S_IDLE: begin
				busy <= 1'b0;
			end

			S_REQ: begin
				sdc_sector <= sector;
				sdc_rd <= 8'h01;
				if (sdc_busy && (sdc_slot == 3'd0)) begin
					sdc_rd <= 8'd0;
					wi <= 9'd0;
					nbytes <= nbytes_calc;
					state <= S_WAIT;
				end
			end

			S_WAIT: begin
				if (sdc_done && (sdc_slot == 3'd0)) begin
					if (sdc_error) begin
						ready <= 1'b0;
						busy  <= 1'b0;
						state <= S_IDLE;
					end
					else begin
						wi <= 9'd0;
						nbytes <= nbytes_calc;
						state <= S_WR;
					end
				end
			end

			S_WR: begin
				if (!h_req && !ack_s[1]) begin
					h_addr <= {sector[8:0], 9'd0} + {9'd0, wi};
					h_data <= sbuf[wi];
					h_req  <= 1'b1;
					state  <= S_ACKW;
				end
			end

			S_ACKW: begin
				if (ack_s[1]) begin
					h_req <= 1'b0;
					if (({1'b0, wi} + 10'd1) >= nbytes) begin
						if (sector + 32'd1 >= nsec) begin
							ready <= 1'b1;
							busy  <= 1'b0;
							state <= S_IDLE;
						end
						else begin
							sector <= sector + 32'd1;
							state  <= S_REQ;
						end
					end
					else begin
						wi <= wi + 9'd1;
						state <= S_WR;
					end
				end
			end

			S_DRAIN: begin
				sdc_rd <= 8'd0;
				if (!sdc_busy) begin
					if (start_pending) begin
						sector <= 32'd0;
						nsec   <= nsec_calc;
						start_pending <= 1'b0;
						state  <= S_REQ;
					end
					else
						state <= S_IDLE;
				end
			end

			default: state <= S_IDLE;
			endcase
		end
	end
end


endmodule
`default_nettype wire
