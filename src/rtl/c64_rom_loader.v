// ROM file loader for the C64 core, using the img_sdc image slots.
//
// The Karabas file mounter gives every OSD "F" item a slot.  This core uses:
//
//   slot 2: C64 ROM (BASIC + KERNAL map, 14 bit)
//           8192  bytes -> KERNAL only, written at 0x2000..0x3FFF
//           16384 bytes -> BASIC (0x0000..0x1FFF) + KERNAL (0x2000..0x3FFF)
//   slot 3: 1541 ROM, 16384 bytes, written at 0x0000..0x3FFF
//
// The stock ROMs stay in the core; the overlay is selected only after a
// complete, valid image has been read.  An invalid size, a read error, an
// eject or an empty slot leaves the "loaded" flags clear and the stock ROMs
// selected.
//
// img_sdc serves one request at a time and gives the lowest slot priority, so
// the disk loader (slot 0) is never disturbed by a ROM load; the ROM loader
// simply keeps its request asserted until its slot is served.

`timescale 1ns / 1ps
`default_nettype none

module c64_rom_loader (
	input wire        clk,          // clk_host, same as img_sdc
	input wire        reset,        // power-on only: mounted ROM survives a C64 reset

	// mount tracker
	input wire [7:0]  mounted,
	input wire [63:0] size2,
	input wire [63:0] size3,
	input wire [7:0]  mount_pulse,
	input wire [7:0]  eject_pulse,

	// img_sdc request
	output reg [7:0]  sdc_rd,
	output reg [31:0] sdc_sector,
	input wire        sdc_busy,
	input wire        sdc_done,
	input wire        sdc_error,
	input wire [2:0]  sdc_slot,
	input wire        sdc_byte_strobe,
	input wire [8:0]  sdc_byte_addr,
	input wire [7:0]  sdc_byte_data,

	// C64 ROM write port (14-bit BASIC+KERNAL map)
	output reg [13:0] c64rom_addr,
	output reg [7:0]  c64rom_data,
	output reg        c64rom_wr,

	// 1541 ROM write port
	output reg [13:0] c1541rom_addr,
	output reg [7:0]  c1541rom_data,
	output reg        c1541rom_wr,

	// selected only after a complete, valid image
	output reg        kernal_loaded,
	output reg        basic_loaded,
	output reg [1:0]  c1541_loaded,

	// high while a load/eject is in progress; its falling edge resets the C64
	output wire       busy
);

localparam S_IDLE  = 2'd0;
localparam S_REQ   = 2'd1;
localparam S_WAIT  = 2'd2;
localparam S_DRAIN = 2'd3;

reg [1:0]  state = S_IDLE;
reg [2:0]  cur = 3'd2;
reg [63:0] cur_size = 64'd0;
reg [31:0] sector = 32'd0;
reg [31:0] nsec = 32'd0;

reg pending2 = 1'b0;
reg pending3 = 1'b0;
reg [15:0] busy_hold = 16'd0;

wire [15:0] byte_index = (sector[15:0] << 9) + {7'd0, sdc_byte_addr};

// the current request is being ejected: stop it and wait until img_sdc is free
wire eject_cur = (eject_pulse[2] && (state != S_IDLE) && (cur == 3'd2)) ||
                 (eject_pulse[3] && (state != S_IDLE) && (cur == 3'd3));

assign busy = (state != S_IDLE) || pending2 || pending3 || (busy_hold != 16'd0);

always @(posedge clk) begin
	c64rom_wr  <= 1'b0;
	c1541rom_wr <= 1'b0;

	if (reset) begin
		state <= S_IDLE;
		cur <= 3'd2;
		cur_size <= 64'd0;
		sector <= 32'd0;
		nsec <= 32'd0;
		pending2 <= 1'b0;
		pending3 <= 1'b0;
		busy_hold <= 16'd0;
		sdc_rd <= 8'd0;
		sdc_sector <= 32'd0;
		c64rom_addr <= 14'd0;
		c64rom_data <= 8'd0;
		c1541rom_addr <= 14'd0;
		c1541rom_data <= 8'd0;
		kernal_loaded <= 1'b0;
		basic_loaded <= 1'b0;
		c1541_loaded <= 2'b00;
	end
	else begin
		// busy hold: set below on every mount/eject, counts down otherwise
		if (busy_hold != 16'd0)
			busy_hold <= busy_hold - 16'd1;

		// ---------------------------------------------------------- events
		if (mount_pulse[2]) begin
			kernal_loaded <= 1'b0;
			basic_loaded  <= 1'b0;
			if ((size2 == 64'd8192) || (size2 == 64'd16384))
				pending2 <= 1'b1;
			else
				pending2 <= 1'b0;
			busy_hold <= 16'hFFFF;
		end
		if (mount_pulse[3]) begin
			c1541_loaded <= 2'b00;
			if ((size3 == 64'd8192) || (size3 == 64'd16384))
				pending3 <= 1'b1;
			else
				pending3 <= 1'b0;
			busy_hold <= 16'hFFFF;
		end
		if (eject_pulse[2]) begin
			pending2 <= 1'b0;
			kernal_loaded <= 1'b0;
			basic_loaded  <= 1'b0;
			busy_hold <= 16'hFFFF;
		end
		if (eject_pulse[3]) begin
			pending3 <= 1'b0;
			c1541_loaded <= 2'b00;
			busy_hold <= 16'hFFFF;
		end

		// ---------------------------------------------------------- state machine
		if (eject_cur) begin
			sdc_rd <= 8'd0;
			state <= S_DRAIN;
		end
		else case (state)
			S_IDLE: begin
				sdc_rd <= 8'd0;
				if (pending2 && mounted[2]) begin
					pending2 <= 1'b0;
					cur <= 3'd2;
					cur_size <= size2;
					sector <= 32'd0;
					nsec <= (size2 + 64'd511) >> 9;
					kernal_loaded <= 1'b0;
					basic_loaded  <= 1'b0;
					state <= S_REQ;
				end
				else if (pending3 && mounted[3]) begin
					pending3 <= 1'b0;
					cur <= 3'd3;
					cur_size <= size3;
					sector <= 32'd0;
					nsec <= (size3 + 64'd511) >> 9;
					c1541_loaded <= 2'b00;
					state <= S_REQ;
				end
			end

			S_REQ: begin
				sdc_sector <= sector;
				if (cur == 3'd2)
					sdc_rd <= 8'h04;
				else
					sdc_rd <= 8'h08;
				if (sdc_busy && (sdc_slot == cur)) begin
					sdc_rd <= 8'd0;
					state <= S_WAIT;
				end
			end

			S_WAIT: begin
				sdc_rd <= 8'd0;
				if (sdc_done && (sdc_slot == cur)) begin
					if (sdc_error) begin
						state <= S_IDLE;
					end
					else if ((sector + 32'd1) >= nsec) begin
						if (cur == 3'd2) begin
							kernal_loaded <= 1'b1;
							if (cur_size == 64'd16384)
								basic_loaded <= 1'b1;
						end
						else begin
							if (cur_size == 64'd16384)
								c1541_loaded <= 2'b11;
							else
								c1541_loaded <= 2'b10;
						end
						state <= S_IDLE;
					end
					else begin
						sector <= sector + 32'd1;
						state <= S_REQ;
					end
				end
			end

			S_DRAIN: begin
				sdc_rd <= 8'd0;
				if (!sdc_busy)
					state <= S_IDLE;
			end

			default: state <= S_IDLE;
		endcase

		// ------------------------------------------------ overlay write
		// The bytes of the sector arrive while the request is in S_WAIT.
		if (sdc_byte_strobe && (state == S_WAIT) && (sdc_slot == cur)) begin
			if ({48'd0, byte_index} < cur_size) begin
				if (cur == 3'd2) begin
					if (cur_size == 64'd8192)
						c64rom_addr <= 14'h2000 + byte_index[12:0];
					else
						c64rom_addr <= byte_index[13:0];
					c64rom_data <= sdc_byte_data;
					c64rom_wr   <= 1'b1;
				end
				else begin
					if (cur_size == 64'd8192)
						c1541rom_addr <= 14'h2000 + byte_index[12:0];
					else
						c1541rom_addr <= byte_index[13:0];
					c1541rom_data <= sdc_byte_data;
					c1541rom_wr   <= 1'b1;
				end
			end
		end
	end
end

endmodule
`default_nettype wire
