// File loader for PRG/CRT images mounted through the Karabas "F" items.
//
// Disk images already use img_sdc, which gives a persistent mount and a real
// eject (Del).  FL items are a one-shot byte stream: the firmware can clear
// the ini entry, but the FPGA never learns that the cartridge was removed.
//
// This module reads a mounted F image sector by sector and converts it into
// the same file_* byte stream the PRG/CRT parsers already use:
//
//   slot 4 (F item PRG) -> virtual file_slot 1
//   slot 5 (F item CRT) -> virtual file_slot 5
//   slot 6 (F item TAP) -> virtual file_slot 6
//
// It also re-reads a mounted PRG after a C64 reset (after the KERNAL reaches
// $FFCF), and pulses prg_eject/crt_eject when the image is ejected.

`timescale 1ns / 1ps
`default_nettype none

module c64_img_file_loader (
	input wire clk,                         // clk_host
	input wire reset,                       // power-on only

	input wire [7:0]  mounted,
	input wire [63:0] size4,
	input wire [63:0] size5,
	input wire [63:0] size6,
	input wire [7:0]  mount_pulse,
	input wire [7:0]  eject_pulse,

	input wire        c64_reset,            // C64/OSD reset (clk_sys)
	input wire        boot_ready,           // C64 reached $FFCF

	// img_sdc sector read
	output reg [7:0]  sdc_rd,
	output reg [31:0] sdc_sector,
	input wire        sdc_busy,
	input wire        sdc_done,
	input wire        sdc_error,
	input wire [2:0]  sdc_slot,
	input wire        sdc_byte_strobe,
	input wire [8:0]  sdc_byte_addr,
	input wire [7:0]  sdc_byte_data,

	// virtual file stream to the PRG/CRT parsers
	output reg        file_reset,
	output reg        file_active,
	output reg [31:0] file_size,
	output reg [31:0] file_addr,
	output reg [7:0]  file_data,
	output reg        file_wr,
	output reg [7:0]  file_slot,

	output reg        prg_eject,
	output reg        crt_eject,
	output reg        busy,
	output reg        error
);

localparam [2:0] S_IDLE   = 3'd0;
localparam [2:0] S_START  = 3'd1;
localparam [2:0] S_WAIT   = 3'd2;
localparam [2:0] S_REQ    = 3'd3;
localparam [2:0] S_READ   = 3'd4;
localparam [2:0] S_DRAIN  = 3'd5;
localparam [2:0] S_FEED   = 3'd6;

reg [2:0]  state = S_IDLE;
reg [2:0]  cur = 3'd4;
reg        pending4 = 1'b0;
reg        pending5 = 1'b0;
reg        pending6 = 1'b0;
reg        wait_ready = 1'b0;

reg [31:0] sector = 32'd0;
reg [31:0] nsec = 32'd0;
reg [31:0] size_cur = 32'd0;
reg [7:0]  slot_cur = 8'd1;

// one 512-byte sector buffer: img_sdc delivers a sector as a burst, while
// the CRT parser writes one byte at a time into SRAM through a 16-byte queue
reg [7:0]  sbuf [0:511];
reg [9:0]  feed_idx = 10'd0;
reg [9:0]  feed_total = 10'd512;
reg [3:0]  feed_gap = 4'd0;
reg [31:0] feed_sector = 32'd0;

// c64_img_mount turns the firmware's "size 0 first" mount sequence into a
// real eject only when no non-zero size follows within its grace window.
// So an eject pulse here is a real Del and is honoured in any state.

reg [1:0]  reset_s = 2'b00;
reg        reset_d = 1'b0;
reg [1:0]  boot_s = 2'b00;

wire reset_rise = reset_s[1] & ~reset_d;
wire boot_ready_s = boot_s[1];

always @(posedge clk) begin
	reset_s <= {reset_s[0], c64_reset};
	reset_d <= reset_s[1];
	boot_s  <= {boot_s[0], boot_ready};
end

always @(posedge clk) begin
	file_wr <= 1'b0;
	prg_eject <= 1'b0;
	crt_eject <= 1'b0;

	if (reset) begin
		state <= S_IDLE;
		cur <= 3'd4;
		pending4 <= 1'b0; pending5 <= 1'b0; pending6 <= 1'b0;
		wait_ready <= 1'b0;
		sector <= 32'd0; nsec <= 32'd0; size_cur <= 32'd0;
		feed_idx <= 10'd0; feed_total <= 10'd512; feed_gap <= 4'd0; feed_sector <= 32'd0;
		slot_cur <= 8'd1;
		sdc_rd <= 8'd0; sdc_sector <= 32'd0;
		file_reset <= 1'b0; file_active <= 1'b0;
		file_size <= 32'd0; file_addr <= 32'd0; file_data <= 8'd0;
		file_slot <= 8'd1;
		busy <= 1'b0; error <= 1'b0;
	end
	else begin
		// ---------------------------------------------------- mount/eject
		if (mount_pulse[4]) pending4 <= 1'b1;
		if (mount_pulse[5])
			pending5 <= 1'b1;
		if (mount_pulse[6]) pending6 <= 1'b1;

		if (eject_pulse[4]) begin
			pending4 <= 1'b0;
			prg_eject <= 1'b1;
			if (cur == 3'd4 && state != S_IDLE) begin
				sdc_rd <= 8'd0;
				file_active <= 1'b0;
				state <= S_DRAIN;
			end
		end
		if (eject_pulse[5]) begin
			pending5 <= 1'b0;
			crt_eject <= 1'b1;
			if (cur == 3'd5 && state != S_IDLE) begin
				sdc_rd <= 8'd0;
				file_active <= 1'b0;
				state <= S_DRAIN;
			end
		end
		if (eject_pulse[6]) begin
			pending6 <= 1'b0;
			if (cur == 3'd6 && state != S_IDLE) begin
				sdc_rd <= 8'd0;
				file_active <= 1'b0;
				state <= S_DRAIN;
			end
		end

		// a C64 reset re-loads a mounted PRG after the KERNAL has booted;
		// a CRT stays in SRAM and the cartridge logic is not reset by F12
		if (reset_rise) begin
			if (mounted[4]) pending4 <= 1'b1;
			if (cur == 3'd4 && state != S_IDLE) begin
				sdc_rd <= 8'd0;
				file_active <= 1'b0;
				state <= S_DRAIN;
			end
		end

		// ------------------------------------------------------ state machine
		case (state)
			S_IDLE: begin
				sdc_rd <= 8'd0;
				busy <= 1'b0;
				file_active <= 1'b0;
				if (pending4 && mounted[4]) begin
					pending4 <= 1'b0;
					cur <= 3'd4;
					slot_cur <= 8'd1;
					size_cur <= size4[31:0];
					wait_ready <= 1'b1;
					state <= S_START;
				end
				else if (pending5 && mounted[5]) begin
					pending5 <= 1'b0;
					cur <= 3'd5;
					slot_cur <= 8'd5;
					size_cur <= size5[31:0];
					wait_ready <= 1'b0;
					state <= S_START;
				end
				else if (pending6 && mounted[6]) begin
					pending6 <= 1'b0;
					cur <= 3'd6;
					slot_cur <= 8'd6;
					size_cur <= size6[31:0];
					wait_ready <= 1'b0;
					state <= S_START;
				end
			end

			S_START: begin
				busy <= 1'b1;
				file_reset <= 1'b1;
				file_slot <= slot_cur;
				file_size <= size_cur;
				file_active <= 1'b0;
				sector <= 32'd0;
				nsec <= (size_cur + 32'd511) >> 9;
				state <= S_WAIT;
			end

			S_WAIT: begin
				file_reset <= 1'b0;
				if (!wait_ready || boot_ready_s) begin
					file_active <= 1'b1;
					state <= S_REQ;
				end
			end

			S_REQ: begin
				sdc_sector <= sector;
				sdc_rd <= (8'd1 << cur);
				if (sdc_busy && (sdc_slot == cur)) begin
					sdc_rd <= 8'd0;
					state <= S_READ;
				end
			end

			S_READ: begin
				sdc_rd <= 8'd0;
				// capture the burst into the sector buffer, do not feed yet
				if (sdc_byte_strobe && (sdc_slot == cur))
					sbuf[sdc_byte_addr] <= sdc_byte_data;
				if (sdc_done && (sdc_slot == cur)) begin
					if (sdc_error) begin
						file_active <= 1'b0;
						error <= 1'b1;
						state <= S_IDLE;
					end
					else begin
						feed_sector <= sector;
						feed_idx <= 10'd0;
						feed_gap <= 4'd8;
						// the last sector may be shorter than 512 bytes
						if ((sector + 32'd1) >= nsec) begin
							if (size_cur[8:0] == 9'd0)
								feed_total <= 10'd512;
							else
								feed_total <= {1'b0, size_cur[8:0]};
						end
						else
							feed_total <= 10'd512;
						state <= S_FEED;
					end
				end
			end

			S_FEED: begin
				if (feed_gap != 4'd0)
					feed_gap <= feed_gap - 4'd1;
				else if (feed_idx < feed_total) begin
					// pace the parser: it drains a 16-byte queue through SRAM
					file_wr <= 1'b1;
					file_addr <= {feed_sector[22:0], feed_idx[8:0]};
					file_data <= sbuf[feed_idx[8:0]];
					feed_idx <= feed_idx + 10'd1;
					feed_gap <= 4'd8;
				end
				else if ((feed_sector + 32'd1) >= nsec) begin
					file_active <= 1'b0;
					state <= S_IDLE;
				end
				else begin
					sector <= feed_sector + 32'd1;
					state <= S_REQ;
				end
			end

			S_DRAIN: begin
				sdc_rd <= 8'd0;
				file_active <= 1'b0;
				if (!sdc_busy)
					state <= S_IDLE;
			end

			default: state <= S_IDLE;
		endcase
	end
end

endmodule
`default_nettype wire
