// MiSTer SID voice, 8580-only Verilog-2001 port.
// The 6581 DAC / DC paths are removed; the 8580 paths are kept unchanged.
`timescale 1ns / 1ps

module sid_voice
(
	input         clock,
	input         ce_1m,
	input         reset,
	input  [15:0] freq,
	input  [11:0] pw,
	input   [7:0] control,
	input   [7:0] att_dec,
	input   [7:0] sus_rel,
	input         osc_msb_in,

	input   [7:0] _st_out,
	input   [7:0] p_t_out,
	input   [7:0] ps__out,
	input   [7:0] pst_out,

	output [11:0] acc_t,

	output        osc_msb_out,
	output [21:0] voice_out,
	output [ 7:0] osc_out,
	output [ 7:0] env_out
);

localparam        [12:0] WAVEFORM_DC_8580 = 13'h800;
localparam        [23:0] WF_0_TTL_8580    = 24'd5000000;
localparam        [23:0] NOISE_TTL_8580   = 24'h950000;

wire test_ctrl    = control[3];
wire ringmod_ctrl = control[2];
wire sync_ctrl    = control[1];

assign osc_msb_out = oscillator[23];
assign voice_out   = dca_out;
assign osc_out     = wave_out;
assign env_out     = envelope;

// Envelope
wire [7:0] envelope;
sid_envelope adsr
(
	.clock(clock),
	.ce_1m(ce_1m),
	.reset(reset),
	.gate(control[0]),
	.att_dec(att_dec),
	.sus_rel(sus_rel),
	.envelope(envelope)
);

// Phase accumulator
reg  [23:0] oscillator;
reg         osc_msb_in_prv;
always @(posedge clock) begin
	if (ce_1m) begin
		osc_msb_in_prv <= osc_msb_in;
		oscillator <= (reset || test_ctrl || (sync_ctrl && ~osc_msb_in && osc_msb_in_prv)) ?
			24'd0 : (oscillator + freq);
	end
end

assign acc_t = {oscillator[23], oscillator[22:12] ^ {11{~control[5] & ((ringmod_ctrl & ~osc_msb_in) ^ oscillator[23])}}};

// Waveform generator
reg [11:0] noise;
reg [11:0] saw_tri;
reg        pulse;
always @(posedge clock) begin : wave_gen
	reg clk, clk_d;
	reg osc_edge;
	reg [23:0] noise_age;
	reg [22:0] lfsr_noise;

	if (reset) begin
		saw_tri    <= 0;
		pulse      <= 0;
		noise      <= 0;
		osc_edge   <= 0;
		lfsr_noise <= 23'h7fffff;
		noise_age  <= 0;
	end
	else begin
		if (ce_1m) begin
			osc_edge <= oscillator[19];
			clk      <= ~(reset || test_ctrl || (~osc_edge & oscillator[19]));
			clk_d    <= clk;

			saw_tri <= acc_t;
			pulse   <= (test_ctrl || (oscillator[23:12] >= pw));
			noise   <= {lfsr_noise[20], lfsr_noise[18], lfsr_noise[14], lfsr_noise[11],
			            lfsr_noise[9], lfsr_noise[5], lfsr_noise[2], lfsr_noise[0], 4'b0000};

			if (~clk) begin
				if (noise_age >= NOISE_TTL_8580) noise <= 12'hfff;
				else noise_age <= noise_age + 1'd1;
			end
			else begin
				noise_age <= 0;
				if (clk & ~clk_d) begin
					lfsr_noise <= {lfsr_noise[21:0], (reset | test_ctrl | lfsr_noise[22]) ^ lfsr_noise[17]};
				end
				else if (control[7] & |control[6:4]) begin
					lfsr_noise[20] <= lfsr_noise[20] & wave_out[7];
					lfsr_noise[18] <= lfsr_noise[18] & wave_out[6];
					lfsr_noise[14] <= lfsr_noise[14] & wave_out[5];
					lfsr_noise[11] <= lfsr_noise[11] & wave_out[4];
					lfsr_noise[ 9] <= lfsr_noise[ 9] & wave_out[3];
					lfsr_noise[ 5] <= lfsr_noise[ 5] & wave_out[2];
					lfsr_noise[ 2] <= lfsr_noise[ 2] & wave_out[1];
					lfsr_noise[ 0] <= lfsr_noise[ 0] & wave_out[0];
				end
			end
		end
	end
end

reg [11:0] norm;
reg  [7:0] comb;

// Waveform output selector (8580 tables).
always @(*) begin
	case (control[7:4])
		4'b0001: norm = {saw_tri[10:0], 1'b0};
		4'b0010: norm = saw_tri;
		4'b0100: norm = {12{pulse}};
		4'b1000: norm = noise;
		default: norm = 12'd0;
	endcase

	case (control[7:4])
		4'b0011: comb = _st_out;
		4'b0101: comb = p_t_out & {8{pulse}};
		4'b0110: comb = ps__out & {8{pulse}};
		4'b0111: comb = pst_out & {8{pulse}};
		default: comb = 8'd0;
	endcase
end

// OSC3 readback
reg [7:0] wave_out;
always @(posedge clock)
	if (ce_1m) wave_out <= norm[11:4] | comb;

// 8580 DAC: no 6581 R-2R model, no mode mux.
reg signed [12:0] dac_out;
reg        [23:0] keep_cnt;
reg signed [21:0] dca_out;

always @(posedge clock) begin : dac_seq
	reg signed [8:0] env_dac;

	if (reset) begin
		keep_cnt <= 0;
		dac_out  <= 0;
		dca_out  <= 0;
	end
	else if (ce_1m) begin
		if (control[7:4]) begin
			keep_cnt <= WF_0_TTL_8580;
			dac_out  <= $signed({1'b0, norm | {comb, 4'b0}}) - 13'sd2048;
		end
		else if (keep_cnt) begin
			keep_cnt <= keep_cnt - 1'd1;
		end
		else begin
			dac_out <= 0;
		end

		env_dac <= $signed({1'b0, envelope});
		dca_out <= dac_out * env_dac;
	end
end

endmodule
