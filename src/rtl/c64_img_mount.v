// Per-slot mount tracker for the Karabas file mounter (img_sdc).
//
// kg_mcu_img signals a mount with a ONE-CLOCK pulse on img_mounted[slot] and
// the new IMG_SIZE.  img_sdc passes both through one clock later.  The old
// code used the pulse directly as a level, which works only if the firmware
// holds the line; this tracker turns either a pulse or a level into:
//
//   mounted[n]      persistent "an image is in slot n"
//   size0/2/3...    last size reported for the slots used by this core
//   mount_pulse[n]  one clock: (new) image in slot n, load it
//   eject_pulse[n]  one clock: slot n became empty
//
// The firmware sends a size-0 mount before the real size of a new image
// ("size 0 first: the core sees an eject before a new image").  A size-0
// pulse only arms an eject: if a non-zero mount follows within EJECT_GRACE,
// the eject is cancelled.  A real Del sends size 0 and nothing after it, so
// the eject fires when the grace window expires.  This is the same idea as
// kg_bk_ram's GRACE_CLOCKS.
//
// A level-mode falling edge after the line was high for a few clocks is also
// accepted as an eject, so older mcu implementations keep working.

`timescale 1ns / 1ps
`default_nettype none

module c64_img_mount (
	input wire        clk,
	input wire        reset,

	input wire [7:0]  sdc_img_mounted,
	input wire [63:0] sdc_img_size,

	output reg [7:0]  mounted,
	output reg [63:0] size0,
	output reg [63:0] size2,
	output reg [63:0] size3,
	output reg [63:0] size4,
	output reg [63:0] size5,
	output reg [63:0] size6,

	output reg [7:0]  mount_pulse,
	output reg [7:0]  eject_pulse
);

// 10 ms at clk_host = 25 MHz
localparam [19:0] EJECT_GRACE = 20'd250_000;

reg [7:0]  hi_d;
reg [2:0]  hi_cnt [0:7];
reg [7:0]  eject_armed;
reg [19:0] eject_cnt;

integer i;

always @(posedge clk) begin
	mount_pulse <= 8'd0;
	eject_pulse <= 8'd0;

	if (reset) begin
		hi_d   <= 8'd0;
		mounted <= 8'd0;
		size0  <= 64'd0;
		size2  <= 64'd0;
		size3  <= 64'd0;
		size4  <= 64'd0;
		size5  <= 64'd0;
		size6  <= 64'd0;
		eject_armed <= 8'd0;
		eject_cnt   <= 20'd0;
		for (i = 0; i < 8; i = i + 1)
			hi_cnt[i] <= 3'd0;
	end
	else begin
		hi_d <= sdc_img_mounted;

		// saturating high-time counter, used to tell a level from a pulse
		for (i = 0; i < 8; i = i + 1) begin
			if (sdc_img_mounted[i]) begin
				if (hi_cnt[i] != 3'd7)
					hi_cnt[i] <= hi_cnt[i] + 3'd1;
			end
			else
				hi_cnt[i] <= 3'd0;
		end

		// the armed size-0 eject becomes real only when no size follows
		if (eject_armed != 8'd0) begin
			if (eject_cnt != 20'd0)
				eject_cnt <= eject_cnt - 20'd1;
			else begin
				for (i = 0; i < 8; i = i + 1) begin
					if (eject_armed[i]) begin
						mounted[i]     <= 1'b0;
						eject_pulse[i] <= 1'b1;
					end
				end
				eject_armed <= 8'd0;
			end
		end

		for (i = 0; i < 8; i = i + 1) begin
			// rising edge (pulse mode mount, or level-mode mount)
			if (sdc_img_mounted[i] && !hi_d[i]) begin
				if (sdc_img_size == 64'd0) begin
					eject_armed[i] <= 1'b1;
					eject_cnt     <= EJECT_GRACE;
					eject_pulse[i] <= 1'b0; // a new size-0 mount restarts the grace
				end
				else begin
					eject_armed[i] <= 1'b0;
					mounted[i]     <= 1'b1;
					mount_pulse[i] <= 1'b1;
					eject_pulse[i] <= 1'b0; // a mount in this clock wins
					if (i == 0)
						size0 <= sdc_img_size;
					else if (i == 2)
						size2 <= sdc_img_size;
					else if (i == 3)
						size3 <= sdc_img_size;
					else if (i == 4)
						size4 <= sdc_img_size;
					else if (i == 5)
						size5 <= sdc_img_size;
					else if (i == 6)
						size6 <= sdc_img_size;
				end
			end

			// level-mode eject: the line was high long enough and fell
			else if (!sdc_img_mounted[i] && hi_d[i] && (hi_cnt[i] >= 3'd4)) begin
				eject_armed[i] <= 1'b0;
				mounted[i]     <= 1'b0;
				eject_pulse[i] <= 1'b1;
			end
		end
	end
end

endmodule
`default_nettype wire
