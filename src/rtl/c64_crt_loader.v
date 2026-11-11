// CRT cartridge loader, ported from the MiSTer c64.sv CRT parser.
//
// The F-item image stream (CRT item, slot 5) is parsed here:
//   0x00..0x3F  cartridge header (id, EXROM, GAME)
//   0x40..      CHIP packets (16-byte header + data)
// The CHIP data is written sequentially to the cartridge ROM area
// (0x020000 word base) and the bank map is handed to cartridge.v.
// The C64 is held in reset while loading; after the last byte it boots with
// the cartridge attached.

`timescale 1ns / 1ps
`default_nettype none

module c64_crt_loader (
	input wire clk,                     // clk_host
	input wire reset,                   // reset_host

	input wire        file_reset,
	input wire        file_active,
	input wire        file_wr,
	input wire [31:0] file_size,
	input wire [31:0] file_addr,
	input wire [7:0]  file_data,
	input wire [7:0]  file_slot,
	input wire        eject,

	// cartridge.v controls
	output reg        cart_loading,
	output reg [7:0]  cart_id,
	output reg        cart_exrom,
	output reg        cart_game,
	output reg        cart_bank_hi,
	output reg        cart_bank_16k,
	output reg [7:0]  cart_bank_num,
	output wire [7:0] cart_bank_addr,
	output reg        cart_bank_wr_tgl,  // toggle, synchronised in c64_machine
	output wire [7:0] dbg_id_parsed,

	// hold the C64 in reset while the cartridge is loaded
	output reg        cart_hold,

	// cartridge ROM write port (c64_memory, absolute 21-bit word address)
	output reg        crt_req,
	output reg [20:0] crt_addr,
	output reg [7:0]  crt_data,
	input wire        crt_ack,

	output reg        busy,
	output reg        error
);

localparam [7:0] CRT_SLOT = 8'd5;

localparam [1:0] S_IDLE  = 2'd0;
localparam [1:0] S_STREAM= 2'd1;
localparam [1:0] S_DRAIN = 2'd2;
localparam [1:0] S_WAIT  = 2'd3;

reg [1:0] state = S_IDLE;

reg [7:0]  id_hi = 8'd0;
reg [7:0]  id_parsed = 8'd255;
reg        slot_ok = 1'b0;
reg        seen_active = 1'b0;
reg        file_done = 1'b0;

// MiSTer CRT parser state
reg [15:0] blk_len = 16'd0;
reg [3:0]  hdr_cnt = 4'd0;
reg [19:0] data_count = 20'd0;   // bytes accepted (address of next byte)
reg [19:0] data_done = 20'd0;    // bytes written to SRAM

// output queue
reg [7:0]  q_data [0:15];
reg [3:0]  q_wp = 4'd0, q_rp = 4'd0;
reg [4:0]  q_cnt = 5'd0;
wire       q_full = (q_cnt == 5'd16);
wire       q_empty = (q_cnt == 5'd0);

reg [1:0]  crt_ack_s = 2'b00;
reg [1:0]  crt_gap = 2'd0;

reg [24:0] finish_cnt = 25'd0;
reg [24:0] eject_hold_cnt = 25'd0;

wire file_byte = file_wr && slot_ok && file_active;
wire q_pop = crt_req && crt_ack_s[1];
wire push = file_byte && (file_addr >= 32'h40) && (blk_len != 16'd0) &&
            (hdr_cnt == 4'd0) && (!q_full || q_pop);

// cartridge.v wants the destination 8 KB page of the next CHIP
assign cart_bank_addr = {1'b0, data_count[19:13]};
assign dbg_id_parsed = id_parsed;

always @(posedge clk)
	crt_ack_s <= {crt_ack_s[0], crt_ack};

always @(posedge clk) begin
	if (reset) begin
		state <= S_IDLE;
		cart_loading <= 1'b0;
		cart_id <= 8'd255;
		cart_exrom <= 1'b1;
		cart_game <= 1'b1;
		cart_bank_hi <= 1'b0;
		cart_bank_16k <= 1'b0;
		cart_bank_num <= 8'd0;
		cart_bank_wr_tgl <= 1'b0;
		cart_hold <= 1'b0;
		crt_req <= 1'b0; crt_addr <= 21'd0; crt_data <= 8'd0;
		q_wp <= 4'd0; q_rp <= 4'd0; q_cnt <= 5'd0;
		crt_gap <= 2'd0; finish_cnt <= 25'd0;
		id_hi <= 8'd0; id_parsed <= 8'd255;
		slot_ok <= 1'b0; seen_active <= 1'b0; file_done <= 1'b0;
		blk_len <= 16'd0; hdr_cnt <= 4'd0;
		data_count <= 20'd0; data_done <= 20'd0;
		busy <= 1'b0; error <= 1'b0;
	end
	else begin
		if (eject_hold_cnt != 25'd0) begin
			eject_hold_cnt <= eject_hold_cnt - 25'd1;
			if (eject_hold_cnt == 25'd1)
				cart_hold <= 1'b0;
		end
		if (eject) begin
			state <= S_IDLE;
			slot_ok <= 1'b0;
			seen_active <= 1'b0; file_done <= 1'b0;
			q_wp <= 4'd0; q_rp <= 4'd0; q_cnt <= 5'd0;
			crt_req <= 1'b0; crt_gap <= 2'd0;
			cart_loading <= 1'b0;
			cart_hold <= 1'b1; // reset the C64 into BASIC after eject
			eject_hold_cnt <= 25'd2_000_000;
			cart_id <= 8'd255;
			cart_exrom <= 1'b1;
			cart_game <= 1'b1;
			cart_bank_hi <= 1'b0;
			cart_bank_16k <= 1'b0;
			cart_bank_num <= 8'd0;
			busy <= 1'b0; error <= 1'b0;
		end
		else if (file_reset) begin
			slot_ok <= (file_slot == CRT_SLOT);
			id_hi <= 8'd0; id_parsed <= 8'd255;
			seen_active <= 1'b0; file_done <= 1'b0;
			blk_len <= 16'd0; hdr_cnt <= 4'd0;
			data_count <= 20'd0; data_done <= 20'd0;
			q_wp <= 4'd0; q_rp <= 4'd0; q_cnt <= 5'd0;
			crt_req <= 1'b0; crt_gap <= 2'd0;
			finish_cnt <= 25'd0;
			eject_hold_cnt <= 25'd0;
			error <= 1'b0;
			cart_id <= 8'd255;
			cart_exrom <= 1'b1;
			cart_game <= 1'b1;
			cart_bank_hi <= 1'b0;
			cart_bank_16k <= 1'b0;
			cart_bank_num <= 8'd0;
			if (file_slot == CRT_SLOT) begin
				state <= S_STREAM;
				cart_loading <= 1'b1;
				cart_hold <= 1'b1;       // C64 boots after the cart is ready
				busy <= 1'b1;
			end
			else begin
				state <= S_IDLE;
				cart_loading <= 1'b0;
				cart_hold <= 1'b0;
				busy <= 1'b0;
			end
		end
		else begin
			// ---------------------------------------------------- file input
			if (state == S_STREAM) begin
				if (file_active && slot_ok)
					seen_active <= 1'b1;

				if (file_byte) begin
					if (file_addr < 32'h40) begin
						// cartridge header
						if (file_addr == 32'h16) id_hi <= file_data;
						if (file_addr == 32'h17) id_parsed <= id_hi ? 8'd255 : file_data;
						if (file_addr == 32'h18) cart_exrom <= file_data[0];
						if (file_addr == 32'h19) cart_game  <= file_data[0];
					end
					else if (blk_len == 16'd0 || hdr_cnt != 4'd0) begin
						// CHIP packet header, same byte counters as MiSTer
						hdr_cnt <= hdr_cnt + 4'd1;
						if (hdr_cnt == 4'd6)
							blk_len <= {file_data, 8'h00};
						if (hdr_cnt == 4'd11)
							cart_bank_num <= file_data;
						if (hdr_cnt == 4'd12)
							cart_bank_hi <= (file_data > 8'h80);
						if (hdr_cnt == 4'd14)
							cart_bank_16k <= (file_data > 8'h20);
						if (hdr_cnt == 4'd15) begin
							cart_bank_wr_tgl <= ~cart_bank_wr_tgl;
							if (blk_len == 16'd0) begin
								// should not happen for a valid header
								error <= 1'b1;
							end
						end
					end
					else begin
						// CHIP data byte (the queue push itself is below)
						if (!q_full || q_pop) begin
							data_count <= data_count + 20'd1;
							blk_len <= blk_len - 16'd1;
						end
						else begin
							error <= 1'b1;
							cart_loading <= 1'b0;
							cart_hold <= 1'b0;
							busy <= 1'b0;
							state <= S_IDLE;
						end
					end
				end

				if (seen_active && !file_active && !file_done) begin
					file_done <= 1'b1;
					state <= S_DRAIN;
				end
			end

			// -------------------------------------------------- SRAM writer
			if (crt_req) begin
				if (crt_ack_s[1]) begin
					crt_req <= 1'b0;
					crt_gap <= 2'd2;
					if (!q_empty) begin
						q_rp <= q_rp + 4'd1;
						data_done <= data_done + 20'd1;
					end
				end
			end
			else if (crt_gap != 2'd0)
				crt_gap <= crt_gap - 2'd1;
			else if (!q_empty && !crt_ack_s[1]) begin
				crt_req <= 1'b1;
				crt_addr <= 21'h020000 + data_done;
				crt_data <= q_data[q_rp];
			end

			// ------------------------------------------------------ queue
			if (push) begin
				q_data[q_wp] <= file_data;
				q_wp <= q_wp + 4'd1;
			end
			q_cnt <= q_cnt + (push ? 5'd1 : 5'd0) - (q_pop ? 5'd1 : 5'd0);

			// ------------------------------------------------------ finish
			if (state == S_DRAIN && q_empty && !crt_req) begin
				cart_loading <= 1'b0;
				cart_id <= id_parsed;
				cart_exrom <= cart_exrom;
				cart_game <= cart_game;
				finish_cnt <= 25'd2_000_000; // 80 ms to settle
				state <= S_WAIT;
			end
			if (state == S_WAIT) begin
				if (finish_cnt != 25'd0)
					finish_cnt <= finish_cnt - 25'd1;
				else begin
					cart_hold <= 1'b0;
					busy <= 1'b0;
					state <= S_IDLE;
				end
			end
		end
	end
end

endmodule
`default_nettype wire
