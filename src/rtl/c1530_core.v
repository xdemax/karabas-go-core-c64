// C1530 TAP player core, Verilog-2001 port of MiSTer c1530.sv.
// The FIFO is external (see c64_tape.v); this module only implements the
// pulse timing, header skip and motor/sense behaviour.
`timescale 1ns / 1ps
`default_nettype none

module c1530_core (
	input  wire        clk32,
	input  wire        restart_tape,
	input  wire [1:0]  tap_version,

	input  wire [7:0]  fifo_do,
	input  wire        fifo_empty,
	output reg         fifo_rdreq,
	output reg         fifo_error,

	input  wire        cass_sense,
	output reg         cass_read,
	input  wire        cass_write,
	input  wire        cass_motor,
	output wire        cass_run
);

reg [5:0]  tap_player_tick_cnt;
reg [23:0] wave_cnt;
reg [23:0] wave_len;
reg        get_24bits_len;
reg [7:0]  start_bytes;
reg        initial_delay;
reg        skip_bytes;

reg        cass_motor_D;
reg        motor;
reg [23:0] motor_counter;

assign cass_run = motor;

always @(posedge clk32 or posedge restart_tape) begin
	if (restart_tape) begin
		{start_bytes, skip_bytes, get_24bits_len} <= {8'h00, 1'b1, 1'b0};
		tap_player_tick_cnt <= 6'h00;
		wave_len  <= 24'h000004;
		wave_cnt  <= 24'h000000;
		initial_delay  <= 1'b1;
		fifo_rdreq     <= 1'b0;
		fifo_error     <= 1'b0;
		{motor, cass_read} <= 2'b11;
	end
	else begin
		// simulate tape motor momentum
		cass_motor_D <= cass_motor;
		if (cass_motor_D != cass_motor)
			motor_counter <= 24'd320000;
		else if (motor_counter != 0)
			motor_counter <= motor_counter - 1'd1;
		else
			motor <= cass_motor;

		fifo_rdreq <= 1'b0;

		if (~motor & ~cass_sense) begin
			tap_player_tick_cnt <= tap_player_tick_cnt + 1'd1;

			if ((tap_player_tick_cnt == 6'h1F) & ~skip_bytes) begin
				if (~tap_version[1]) begin
					if (wave_cnt > {14'b0, wave_len[10:1]})
						cass_read <= 1'b1;
					else
						cass_read <= 1'b0;
				end

				tap_player_tick_cnt <= 6'h00;
				wave_cnt <= wave_cnt + 1'b1;

				if (wave_cnt == wave_len - 1'b1) begin
					wave_cnt <= 24'h000000;
					if (tap_version == 2'd2)
						cass_read <= ~cass_read;

					if (fifo_empty) begin
						fifo_error <= 1'b1;
					end
					else begin
						fifo_rdreq <= 1'b1;
						if (fifo_do == 8'h00) begin
							wave_len       <= 24'h000100;
							get_24bits_len <= tap_version[0] | tap_version[1];
						end
						else begin
							{initial_delay, wave_len} <= {1'b0, 13'b0, fifo_do, 3'b000};
						end
					end
				end
			end

			// catch 24-bit wave_len for data 0x00 in TAP version 1/2
			if (get_24bits_len & ~skip_bytes & tap_player_tick_cnt[0]) begin
				if (tap_player_tick_cnt == 6'h05)
					get_24bits_len <= 1'b0;

				if (fifo_empty) begin
					fifo_error <= 1'b1;
				end
				else begin
					fifo_rdreq <= 1'b1;
					wave_len <= {fifo_do, wave_len[23:8]};
					if (initial_delay)
						wave_len <= 24'h000004;
				end

				if (~tap_version[1])
					cass_read <= 1'b1;
			end

			// skip the TAP header bytes
			if (skip_bytes & ~fifo_empty & tap_player_tick_cnt[0]) begin
				{fifo_rdreq, cass_read} <= 2'b11;
				if (start_bytes < 8'h14)
					start_bytes <= start_bytes + 8'h01;
				else
					skip_bytes <= 1'b0;
			end
		end
		else begin
			cass_read <= 1'b1;
			tap_player_tick_cnt <= tap_player_tick_cnt + 1'd1;
		end
	end
end

endmodule
`default_nettype wire
