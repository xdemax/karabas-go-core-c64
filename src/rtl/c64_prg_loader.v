// PRG loader for the Karabas C64 core.
//
// The MiSTer/Tang autoboot normally holds the C64 in reset, lets the KERNAL
// boot, copies the PRG into C64 RAM, writes the BASIC zero-page pointers and
// types RUN + Enter.  The Karabas MCU FILELOAD stream has no wait/backpressure
// input, so holding reset while the bytes arrive loses the payload.
//
// This loader therefore writes the payload directly into C64 RAM through the
// existing p_* port while the C64 is already sitting at BASIC READY (the state
// the OSD file menu returns to).  At the end it writes exactly the MiSTer
// inj_meminit pointer table and asks c64_machine to type RUN + Enter.
//
//   file_reset  one clock at the start, file_slot 1 selects this loader
//   file_active level while bytes come, file_wr one clock per byte
//   file_addr   byte offset (0/1 = load address, >=2 = payload)
//
// The staging/boot ports are kept in the interface for compatibility but are
// unused: prg_hold is always 0, stg_req/rd_req are always 0.

`timescale 1ns / 1ps
`default_nettype none

module c64_prg_loader (
	input wire clk,                     // clk_host (25 MHz)
	input wire reset,                   // reset_host

	input wire        file_reset,
	input wire        file_active,
	input wire        file_wr,
	input wire [31:0] file_size,
	input wire [31:0] file_addr,
	input wire [7:0]  file_data,
	input wire [7:0]  file_slot,

	input wire        boot_ready,       // unused
	input wire        eject,            // mounted PRG was ejected

	output reg        stg_req,
	output reg [15:0] stg_addr,
	output reg [7:0]  stg_data,
	input wire        stg_ack,

	output reg        rd_req,
	output reg [15:0] rd_addr,
	input wire [7:0]  rd_data,
	input wire        rd_ack,

	// C64 RAM write port (c64_memory)
	output reg        p_req,
	output reg [15:0] p_addr,
	output reg [7:0]  p_data,
	input wire        p_ack,

	output reg        prg_hold,         // always 0
	output reg        run_req,          // type RUN + Enter
	output reg        busy,
	output reg        error
);

localparam [7:0] PRG_SLOT = 8'd1;

localparam [1:0] S_IDLE   = 2'd0;
localparam [1:0] S_STREAM = 2'd1;
localparam [1:0] S_DRAIN  = 2'd2;
localparam [1:0] S_RUN    = 2'd3;

reg [1:0] state = S_IDLE;

reg [7:0]  load_lo = 8'd0;
reg [15:0] load_addr = 16'd0;
reg [15:0] end_addr = 16'd0;
reg        slot_ok = 1'b0;
reg        seen_active = 1'b0;
reg        file_done = 1'b0;

// ---- write queue (16 entries) -------------------------------------------
reg [15:0] q_addr [0:15];
reg [7:0]  q_data [0:15];
reg [3:0]  q_wp = 4'd0, q_rp = 4'd0;
reg [4:0]  q_cnt = 5'd0;
wire       q_full = (q_cnt == 5'd16);
wire       q_empty = (q_cnt == 5'd0);
wire [15:0] q_addr_cur = q_addr[q_rp];
wire [7:0]  q_data_cur = q_data[q_rp];

// ---- MiSTer inj_meminit pointer table -----------------------------------
reg [3:0]  post_idx = 4'd0;
reg [15:0] post_addr;
reg [7:0]  post_data;
always @(*) begin
	case (post_idx)
		4'd0:  begin post_addr = 16'h002B; post_data = 8'h01;          end
		4'd1:  begin post_addr = 16'h002C; post_data = 8'h08;          end
		4'd2:  begin post_addr = 16'h002D; post_data = end_addr[7:0];  end
		4'd3:  begin post_addr = 16'h002E; post_data = end_addr[15:8]; end
		4'd4:  begin post_addr = 16'h002F; post_data = end_addr[7:0];  end
		4'd5:  begin post_addr = 16'h0030; post_data = end_addr[15:8]; end
		4'd6:  begin post_addr = 16'h0031; post_data = end_addr[7:0];  end
		4'd7:  begin post_addr = 16'h0032; post_data = end_addr[15:8]; end
		4'd8:  begin post_addr = 16'h00AC; post_data = 8'h00;          end
		4'd9:  begin post_addr = 16'h00AD; post_data = 8'h00;          end
		4'd10: begin post_addr = 16'h00AE; post_data = end_addr[7:0];  end
		default: begin post_addr = 16'h00AF; post_data = end_addr[15:8]; end
	endcase
end

// ---- handshake synchroniser --------------------------------------------
reg [1:0] p_ack_s = 2'b00;
always @(posedge clk)
	p_ack_s <= {p_ack_s[0], p_ack};

wire file_byte = file_wr && slot_ok && file_active;
wire payload_byte = file_byte && (file_addr >= 32'd2);
wire p_pop = p_req && p_ack_s[1] && (q_cnt != 5'd0);
wire push = payload_byte && (!q_full || p_pop);
wire [15:0] payload_addr = load_addr + file_addr[15:0] - 16'd2;
wire post_start = file_done && q_empty && (post_idx != 4'd12) && !p_req;

reg [1:0] p_gap = 2'd0;

always @(posedge clk) begin
	if (reset) begin
		state <= S_IDLE;
		load_lo <= 8'd0; load_addr <= 16'd0; end_addr <= 16'd0;
		slot_ok <= 1'b0; seen_active <= 1'b0; file_done <= 1'b0;
		q_wp <= 4'd0; q_rp <= 4'd0; q_cnt <= 5'd0;
		post_idx <= 4'd0; p_gap <= 2'd0;
		p_req <= 1'b0; p_addr <= 16'd0; p_data <= 8'd0;
		prg_hold <= 1'b0; run_req <= 1'b0; busy <= 1'b0; error <= 1'b0;
		stg_req <= 1'b0; stg_addr <= 16'd0; stg_data <= 8'd0;
		rd_req <= 1'b0; rd_addr <= 16'd0;
	end
	else begin
		stg_req <= 1'b0;
		rd_req  <= 1'b0;

		if (eject) begin
			state <= S_IDLE;
			slot_ok <= 1'b0;
			seen_active <= 1'b0; file_done <= 1'b0;
			q_wp <= 4'd0; q_rp <= 4'd0; q_cnt <= 5'd0;
			p_req <= 1'b0; p_gap <= 2'd0;
			post_idx <= 4'd0;
			prg_hold <= 1'b0; run_req <= 1'b0; busy <= 1'b0; error <= 1'b0;
		end
		else if (file_reset) begin
			slot_ok <= (file_slot == PRG_SLOT);
			load_lo <= 8'd0; load_addr <= 16'd0; end_addr <= 16'd0;
			seen_active <= 1'b0; file_done <= 1'b0;
			q_wp <= 4'd0; q_rp <= 4'd0; q_cnt <= 5'd0;
			post_idx <= 4'd0; p_gap <= 2'd0;
			p_req <= 1'b0;
			prg_hold <= 1'b0;          // never hold the C64 in reset
			run_req <= 1'b0;
			error <= 1'b0;
			busy <= (file_slot == PRG_SLOT);
			state <= (file_slot == PRG_SLOT) ? S_STREAM : S_IDLE;
		end
		else begin
			if (state == S_STREAM) begin
				if (file_active && slot_ok)
					seen_active <= 1'b1;
				if (seen_active && !file_active && !file_done) begin
					file_done <= 1'b1;
					if (file_size < 32'd2 || file_size > 32'd65538) begin
						error <= 1'b1;
						state <= S_IDLE;
						busy <= 1'b0;
					end
					else begin
						end_addr <= load_addr + file_size[15:0] - 16'd2;
						state <= S_DRAIN;
					end
				end
				if (file_byte) begin
					if (file_addr == 32'd0)
						load_lo <= file_data;
					else if (file_addr == 32'd1)
						load_addr <= {file_data, load_lo};
					else if (!push) begin
						error <= 1'b1;
						state <= S_IDLE;
						busy <= 1'b0;
					end
				end
			end

			// ------------------------------------------------ p write FSM
			if (p_req) begin
				if (p_ack_s[1]) begin
					p_req <= 1'b0;
					p_gap <= 2'd2;
					if (q_cnt != 5'd0)
						q_rp <= q_rp + 4'd1;
					else if (post_idx != 4'd12)
						post_idx <= post_idx + 4'd1;
				end
			end
			else if (p_gap != 2'd0)
				p_gap <= p_gap - 2'd1;
			else if (!p_ack_s[1] && (q_cnt != 5'd0 || post_start)) begin
				p_req <= 1'b1;
				if (q_cnt != 5'd0) begin
					p_addr <= q_addr_cur;
					p_data <= q_data_cur;
				end
				else begin
					p_addr <= post_addr;
					p_data <= post_data;
				end
			end

			if (push) begin
				q_addr[q_wp] <= payload_addr;
				q_data[q_wp] <= file_data;
				q_wp <= q_wp + 4'd1;
			end
			q_cnt <= q_cnt + (push ? 5'd1 : 5'd0) - (p_pop ? 5'd1 : 5'd0);

			if (state == S_DRAIN && q_empty && !p_req && post_idx == 4'd12) begin
				run_req <= 1'b1;
				busy <= 1'b0;
				state <= S_RUN;
			end
			if (state == S_RUN)
				state <= S_IDLE;
		end
	end
end

endmodule
`default_nettype wire
