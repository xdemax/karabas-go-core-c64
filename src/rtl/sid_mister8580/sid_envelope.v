// MiSTer SID envelope, Verilog-2001 port (identical behaviour to sid_envelope.sv).
`timescale 1ns / 1ps

module sid_envelope
(
	input            clock,
	input            ce_1m,

	input            reset,
	input            gate,
	input     [ 7:0] att_dec,
	input     [ 7:0] sus_rel,

	output reg [7:0] envelope
);

localparam [1:0] ST_RELEASE = 2'd0;
localparam [1:0] ST_ATTACK  = 2'd1;
localparam [1:0] ST_DEC_SUS = 2'd2;

reg  [1:0] state;

function [14:0] rate_value;
	input [3:0] idx;
	begin
		case (idx)
			4'd0:  rate_value = 15'd8;
			4'd1:  rate_value = 15'd31;
			4'd2:  rate_value = 15'd62;
			4'd3:  rate_value = 15'd94;
			4'd4:  rate_value = 15'd148;
			4'd5:  rate_value = 15'd219;
			4'd6:  rate_value = 15'd266;
			4'd7:  rate_value = 15'd312;
			4'd8:  rate_value = 15'd391;
			4'd9:  rate_value = 15'd976;
			4'd10: rate_value = 15'd1953;
			4'd11: rate_value = 15'd3125;
			4'd12: rate_value = 15'd3906;
			4'd13: rate_value = 15'd11719;
			4'd14: rate_value = 15'd19531;
			default: rate_value = 15'd31250;
		endcase
	end
endfunction

wire [14:0] rate_period = rate_value(
	(state == ST_ATTACK)  ? att_dec[7:4] :
	(state == ST_DEC_SUS) ? att_dec[3:0] : sus_rel[3:0]);

always @(posedge clock) begin : env_seq
	reg        hold_zero;
	reg  [4:0] exponential_counter_period;
	reg        gate_edge;
	reg [14:0] rate_counter;
	reg  [4:0] exponential_counter;

	case (envelope)
		8'hff: exponential_counter_period <= 0;
		8'h5d: exponential_counter_period <= 1;
		8'h36: exponential_counter_period <= 3;
		8'h1a: exponential_counter_period <= 7;
		8'h0e: exponential_counter_period <= 15;
		8'h06: exponential_counter_period <= 29;
		8'h00: exponential_counter_period <= 0;
	endcase

	if (reset) begin
		state <= ST_RELEASE;
		gate_edge <= gate;
		envelope  <= 0;
		hold_zero <= 1;
		exponential_counter <= 0;
		exponential_counter_period <= 0;
		rate_counter <= 0;
	end
	else if (ce_1m) begin
		rate_counter <= rate_counter + 1'd1;
		if (rate_counter == rate_period) begin
			rate_counter <= 0;

			exponential_counter <= exponential_counter + 1'b1;
			if (state == ST_ATTACK || exponential_counter == exponential_counter_period) begin
				exponential_counter <= 0;

				case (state)
					ST_ATTACK: begin
						envelope <= envelope + 1'b1;
						if (envelope == 8'hfe) state <= ST_DEC_SUS;
					end
					ST_DEC_SUS: begin
						if (envelope != {2{sus_rel[7:4]}} && !hold_zero)
							envelope <= envelope - 1'b1;
					end
					ST_RELEASE: begin
						if (!hold_zero) envelope <= envelope - 1'b1;
					end
				endcase

				if (state != ST_ATTACK && envelope == 1) hold_zero <= 1;
			end
		end

		gate_edge <= gate;
		if (~gate_edge & gate) begin
			state <= ST_ATTACK;
			hold_zero <= 0;
		end
		if (gate_edge & ~gate) state <= ST_RELEASE;
	end
end

endmodule
