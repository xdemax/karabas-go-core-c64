// MiSTer SID filter, 8580-only Verilog-2001 port.
// The 6581 compressor, mixer DC and 6581 1/Q row are removed; the 8580
// filter state machine and pipeline stages are kept.
`timescale 1ns / 1ps

module sid_filter
(
	input               clk,
	input         [2:0] state,

	input        [15:0] F0,
	input         [7:0] Res_Filt,
	input         [7:0] Mode_Vol,
	input signed [21:0] voice1,
	input signed [21:0] voice2,
	input signed [21:0] voice3,
	input signed [21:0] ext_in,

	output       [17:0] audio
);

// Clamp to 16 bits.
function signed [15:0] clamp;
	input signed [16:0] x;
	begin
		clamp = (^x[16:15]) ? {x[16], {15{x[15]}}} : x[15:0];
	end
endfunction

// Clamp to 18 bits, for the widened (+2 fractional bits) integrators.
function signed [17:0] clamp18;
	input signed [18:0] x;
	begin
		clamp18 = (^x[18:17]) ? {x[18], {17{x[17]}}} : x[17:0];
	end
endfunction

// MOS8580: 1/Q =~ 2^((4 - res)/8), the second row of the MiSTer table.
function [10:0] q_value;
	input [3:0] idx;
	begin
		case (idx)
			4'd0:  q_value = 11'd1448;
			4'd1:  q_value = 11'd1328;
			4'd2:  q_value = 11'd1218;
			4'd3:  q_value = 11'd1117;
			4'd4:  q_value = 11'd1024;
			4'd5:  q_value = 11'd939;
			4'd6:  q_value = 11'd861;
			4'd7:  q_value = 11'd790;
			4'd8:  q_value = 11'd724;
			4'd9:  q_value = 11'd664;
			4'd10: q_value = 11'd609;
			4'd11: q_value = 11'd558;
			4'd12: q_value = 11'd512;
			4'd13: q_value = 11'd470;
			4'd14: q_value = 11'd431;
			default: q_value = 11'd395;
		endcase
	end
endfunction

// o = c +- (a * b)
reg signed  [33:0] c;
reg                s;
reg signed  [15:0] a;
reg signed  [17:0] b;
wire signed [33:0] m = a * b;
wire signed [33:0] o = s ? (c - m) : (c + m);

// Filter states (18 bits, +2 fractional bits)
reg signed [17:0] vlp, vlp2, vlp_next;
reg signed [17:0] vbp, vbp2, vbp_next;
reg signed [17:0] vhp, vhp2, vhp_next;
reg signed [18:0] dv;

// Filtered-tap mix and registered snapshots.
reg signed [16:0] tmix;
reg signed [16:0] tmix_s;
reg signed [15:0] tmix_c;
reg signed [15:0] tmix_c_r;

always @(*) begin
	dv       = o >>> 17;
	vlp_next = clamp18(vlp + dv);
	vbp_next = clamp18(vbp + dv);
	vhp_next = clamp18(o[28:10]);

	// 8580: linear filtered-tap mix.
	tmix = (Mode_Vol[4] ? $signed(vlp2[17:2])     : 17'sd0) +
	       (Mode_Vol[5] ? $signed(vbp2[17:2])     : 17'sd0) +
	       (Mode_Vol[6] ? $signed(vhp_next[17:2]) : 17'sd0);

	tmix_c = clamp(tmix_s);
end

// Filter
always @(posedge clk) begin : filter_seq
	reg [10:0] _1_Q_lsl10;
	reg signed [17:0] vi;
	reg signed [15:0] vd;

	case (state)
		2: begin
			_1_Q_lsl10 <= q_value(Res_Filt[7:4]);

			vi <= ((Res_Filt[0] ? $signed({{2{voice1[21]}}, voice1}) : 24'sd0) +
			       (Res_Filt[1] ? $signed({{2{voice2[21]}}, voice2}) : 24'sd0) +
			       (Res_Filt[2] ? $signed({{2{voice3[21]}}, voice3}) : 24'sd0) +
			       (Res_Filt[3] ? $signed({{2{ext_in[21]}}, ext_in}) : 24'sd0)) >>> 5;

			vd <= ((Res_Filt[0] ? 24'sd0 : $signed({{2{voice1[21]}}, voice1})) +
			       (Res_Filt[1] ? 24'sd0 : $signed({{2{voice2[21]}}, voice2})) +
			       ((Res_Filt[2] | Mode_Vol[7]) ? 24'sd0 : $signed({{2{voice3[21]}}, voice3})) +
			       (Res_Filt[3] ? 24'sd0 : $signed({{2{ext_in[21]}}, ext_in}))) >>> 7;

			c <= 0;
			s <= 1;
			a <= F0;
			b <= vbp;
		end
		3: begin
			{ vlp, vlp2 } <= { vlp2, vlp_next };
			c <= 0;
			s <= 1;
			b <= vhp;
		end
		4: begin
			{ vbp, vbp2 } <= { vbp2, vbp_next };
			c <= -($signed({{16{vlp2[17]}}, vlp2}) + $signed({{16{vi[17]}}, vi})) <<< 10;
			s <= 0;
			a <= _1_Q_lsl10;
			b <= vbp_next;
		end
		5: begin
			{ vhp, vhp2 } <= { vhp2, vhp_next };
			tmix_s <= tmix;
		end
		6: begin
			tmix_c_r <= tmix_c;
		end
		7: begin
			c <= 0;
			s <= 0;
			a <= {12'b0, Mode_Vol[3:0]};
			b <= clamp(vd + tmix_c_r);
		end
	endcase
end

assign audio = o[19:2];

endmodule
