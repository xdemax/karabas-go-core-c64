// MiSTer SID tables, 8580-only, Verilog-2001 port.
// The 6581 tables, filter curve and DAC model are intentionally absent.
`timescale 1ns / 1ps

module sid_tables
(
	input             clock,

	// waves
	input      [11:0] acc_t,
	output reg  [7:0] _st_out,
	output reg  [7:0] p_t_out,
	output reg  [7:0] ps__out,
	output reg  [7:0] pst_out,

	// filter
	input      [10:0] Fc,
	output     [15:0] F0
);

// 8580 P+T and P+S waveforms (MiSTer tables).
reg [7:0] wave8580_p_t  [0:2047];
reg [7:0] wave8580_ps_  [0:4095];

initial begin
	$readmemh("rtl/sid_mister8580/wave8580_p_t.hex", wave8580_p_t);
	$readmemh("rtl/sid_mister8580/wave8580_ps_.hex", wave8580_ps_);
end

always @(posedge clock)
	p_t_out <= wave8580_p_t[acc_t[10:0]];

always @(posedge clock)
	ps__out <= wave8580_ps_[acc_t];

// S + T (8580)
always @(posedge clock) begin
	_st_out <= {
		1'b0,
		((acc_t & 12'h7fc) == 12'h7fc),
		((acc_t & 12'h7e0) == 12'h7e0) | ((acc_t & 12'h3fe) == 12'h3fe),
		((acc_t & 12'h7e0) == 12'h7e0) | ((acc_t & 12'h5ff) == 12'h5ff) | ((acc_t & 12'h3f0) == 12'h3f0),
		((acc_t & 12'h7e0) == 12'h7e0) | ((acc_t & 12'h1f8) == 12'h1f8) | ((acc_t & 12'h3f0) == 12'h3f0),
		((acc_t & 12'h0fc) == 12'h0fc) | ((acc_t & 12'h1f8) == 12'h1f8) | ((acc_t & 12'h3f0) == 12'h3f0),
		((acc_t & 12'h07e) == 12'h07e) | ((acc_t & 12'h1f8) == 12'h1f8) | ((acc_t & 12'h0fc) == 12'h0fc),
		((acc_t & 12'h13f) == 12'h13f) | ((acc_t & 12'h07e) == 12'h07e) | ((acc_t & 12'h7fa) == 12'h7fa) | ((acc_t & 12'h0bf) == 12'h0bf) | ((acc_t & 12'h0fc) == 12'h0fc)
	};
end

// P + S + T (8580)
always @(posedge clock) begin
	pst_out <= {
		1'b0,
		((acc_t & 12'h7fc) == 12'h7fc) | ((acc_t & 12'h7fb) == 12'h7fb),
		((acc_t & 12'h7ef) == 12'h7ef) | ((acc_t & 12'h7f7) == 12'h7f7) | ((acc_t & 12'h7fc) == 12'h7fc) | ((acc_t & 12'h7fb) == 12'h7fb) | ((acc_t & 12'h3ff) == 12'h3ff),
		((acc_t & 12'h7fc) == 12'h7fc) | ((acc_t & 12'h3ff) == 12'h3ff) | ((acc_t & 12'h7f7) == 12'h7f7) | ((acc_t & 12'h7fb) == 12'h7fb),
		((acc_t & 12'h7fc) == 12'h7fc) | ((acc_t & 12'h3ff) == 12'h3ff) | ((acc_t & 12'h7fb) == 12'h7fb),
		((acc_t & 12'h7fd) == 12'h7fd) | ((acc_t & 12'h3ff) == 12'h3ff) | ((acc_t & 12'h7fe) == 12'h7fe),
		((acc_t & 12'h7fd) == 12'h7fd) | ((acc_t & 12'h3ff) == 12'h3ff) | ((acc_t & 12'h7fe) == 12'h7fe),
		((acc_t & 12'h3ff) == 12'h3ff) | ((acc_t & 12'h7fe) == 12'h7fe)
	};
end

// 8580 filter cutoff: F0 = 5 * Fc.
assign F0 = {3'b000, Fc, 2'b00} + Fc;

endmodule
