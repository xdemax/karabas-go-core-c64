// MiSTer SID top, single 8580, Verilog-2001 port.
//
// The port list is the same as MiSTer's sid_top so fpga64_sid_iec.vhd does
// not change.  The 6581 paths, the second chip and the DUAL state machine are
// removed.  The three voices share one waveform-table/filter pipeline, one
// pass per 1 MHz SID cycle.
`timescale 1ns / 1ps

module sid_top
(
	input         reset,

	input         clk,
	input         ce_1m,

	input   [1:0] cs,
	input         we,
	input   [4:0] addr,
	input   [7:0] data_in,
	output  [7:0] data_out,

	input   [12:0] fc_offset_l,
	input   [7:0]  pot_x_l,
	input   [7:0]  pot_y_l,
	input   [17:0] ext_in_l,
	output  [17:0] audio_l,

	input   [12:0] fc_offset_r,
	input   [7:0]  pot_x_r,
	input   [7:0]  pot_y_r,
	input   [17:0] ext_in_r,
	output  [17:0] audio_r,

	input   [1:0]  filter_en,
	input   [1:0]  mode,
	input   [3:0]  cfg,

	input          ld_clk,
	input   [11:0] ld_addr,
	input   [15:0] ld_data,
	input          ld_wr
);

// ------------------------------------------------------------------ registers
reg  [15:0] Voice_1_Freq;
reg  [11:0] Voice_1_Pw;
reg   [7:0] Voice_1_Control;
reg   [7:0] Voice_1_Att_dec;
reg   [7:0] Voice_1_Sus_Rel;

reg  [15:0] Voice_2_Freq;
reg  [11:0] Voice_2_Pw;
reg   [7:0] Voice_2_Control;
reg   [7:0] Voice_2_Att_dec;
reg   [7:0] Voice_2_Sus_Rel;

reg  [15:0] Voice_3_Freq;
reg  [11:0] Voice_3_Pw;
reg   [7:0] Voice_3_Control;
reg   [7:0] Voice_3_Att_dec;
reg   [7:0] Voice_3_Sus_Rel;

reg  [10:0] Filter_Fc;
reg   [7:0] Filter_Res_Filt;
reg   [7:0] Filter_Mode_Vol;

reg   [7:0] bus_data;

wire  [7:0] Misc_Osc3;
wire  [7:0] Misc_Env3;

wire [21:0] voice_1;
wire [21:0] voice_2;
wire [21:0] voice_3;

wire        voice_1_PA_MSB;
wire        voice_2_PA_MSB;
wire        voice_3_PA_MSB;

reg   [7:0] _st_out [0:2];
reg   [7:0] p_t_out [0:2];
reg   [7:0] ps__out [0:2];
reg   [7:0] pst_out [0:2];
wire [11:0] acc_t   [0:2];

wire        cs_any = |cs;

always @(posedge clk) begin
	if (reset) begin
		Voice_1_Freq <= 0;
		Voice_1_Pw <= 0;
		Voice_1_Control <= 0;
		Voice_1_Att_dec <= 0;
		Voice_1_Sus_Rel <= 0;
		Voice_2_Freq <= 0;
		Voice_2_Pw <= 0;
		Voice_2_Control <= 0;
		Voice_2_Att_dec <= 0;
		Voice_2_Sus_Rel <= 0;
		Voice_3_Freq <= 0;
		Voice_3_Pw <= 0;
		Voice_3_Control <= 0;
		Voice_3_Att_dec <= 0;
		Voice_3_Sus_Rel <= 0;
		Filter_Fc <= 0;
		Filter_Res_Filt <= 0;
		Filter_Mode_Vol <= 0;
		bus_data <= 0;
	end
	else if (cs_any) begin
		if (we) begin
			bus_data <= data_in;
			case (addr)
				5'h00: Voice_1_Freq[7:0]  <= data_in;
				5'h01: Voice_1_Freq[15:8] <= data_in;
				5'h02: Voice_1_Pw[7:0]    <= data_in;
				5'h03: Voice_1_Pw[11:8]   <= data_in[3:0];
				5'h04: Voice_1_Control    <= data_in;
				5'h05: Voice_1_Att_dec    <= data_in;
				5'h06: Voice_1_Sus_Rel    <= data_in;
				5'h07: Voice_2_Freq[7:0]  <= data_in;
				5'h08: Voice_2_Freq[15:8] <= data_in;
				5'h09: Voice_2_Pw[7:0]    <= data_in;
				5'h0a: Voice_2_Pw[11:8]   <= data_in[3:0];
				5'h0b: Voice_2_Control    <= data_in;
				5'h0c: Voice_2_Att_dec    <= data_in;
				5'h0d: Voice_2_Sus_Rel    <= data_in;
				5'h0e: Voice_3_Freq[7:0]  <= data_in;
				5'h0f: Voice_3_Freq[15:8] <= data_in;
				5'h10: Voice_3_Pw[7:0]    <= data_in;
				5'h11: Voice_3_Pw[11:8]   <= data_in[3:0];
				5'h12: Voice_3_Control    <= data_in;
				5'h13: Voice_3_Att_dec    <= data_in;
				5'h14: Voice_3_Sus_Rel    <= data_in;
				5'h15: Filter_Fc[2:0]     <= data_in[2:0];
				5'h16: Filter_Fc[10:3]    <= data_in;
				5'h17: Filter_Res_Filt    <= data_in;
				5'h18: Filter_Mode_Vol    <= data_in;
			endcase
		end
		else begin
			case (addr)
				5'h19: bus_data <= pot_x_l;
				5'h1a: bus_data <= pot_y_l;
				5'h1b: bus_data <= Misc_Osc3;
				5'h1c: bus_data <= Misc_Env3;
			endcase
		end
	end
end

assign data_out = bus_data;

// ------------------------------------------------------------------ voices
sid_voice v1
(
	.clock(clk),
	.ce_1m(ce_1m),
	.reset(reset),
	.freq(Voice_1_Freq),
	.pw(Voice_1_Pw),
	.control(Voice_1_Control),
	.att_dec(Voice_1_Att_dec),
	.sus_rel(Voice_1_Sus_Rel),
	.osc_msb_in(voice_3_PA_MSB),
	.osc_msb_out(voice_1_PA_MSB),
	.voice_out(voice_1),
	._st_out(_st_out[0]),
	.p_t_out(p_t_out[0]),
	.ps__out(ps__out[0]),
	.pst_out(pst_out[0]),
	.acc_t(acc_t[0])
);

sid_voice v2
(
	.clock(clk),
	.ce_1m(ce_1m),
	.reset(reset),
	.freq(Voice_2_Freq),
	.pw(Voice_2_Pw),
	.control(Voice_2_Control),
	.att_dec(Voice_2_Att_dec),
	.sus_rel(Voice_2_Sus_Rel),
	.osc_msb_in(voice_1_PA_MSB),
	.osc_msb_out(voice_2_PA_MSB),
	.voice_out(voice_2),
	._st_out(_st_out[1]),
	.p_t_out(p_t_out[1]),
	.ps__out(ps__out[1]),
	.pst_out(pst_out[1]),
	.acc_t(acc_t[1])
);

sid_voice v3
(
	.clock(clk),
	.ce_1m(ce_1m),
	.reset(reset),
	.freq(Voice_3_Freq),
	.pw(Voice_3_Pw),
	.control(Voice_3_Control),
	.att_dec(Voice_3_Att_dec),
	.sus_rel(Voice_3_Sus_Rel),
	.osc_msb_in(voice_2_PA_MSB),
	.osc_msb_out(voice_3_PA_MSB),
	.voice_out(voice_3),
	.osc_out(Misc_Osc3),
	.env_out(Misc_Env3),
	._st_out(_st_out[2]),
	.p_t_out(p_t_out[2]),
	.ps__out(ps__out[2]),
	.pst_out(pst_out[2]),
	.acc_t(acc_t[2])
);

// ------------------------------------------------------- shared table/filter
wire [15:0] F0;
reg  [11:0] f_acc_t;
reg   [3:0] state;
reg   [2:0] v;
reg  [17:0] audio;

wire  [7:0] f__st_out;
wire  [7:0] f_p_t_out;
wire  [7:0] f_ps__out;
wire  [7:0] f_pst_out;
wire [17:0] faudio;

sid_tables tables
(
	.clock(clk),
	.acc_t(f_acc_t),
	._st_out(f__st_out),
	.p_t_out(f_p_t_out),
	.ps__out(f_ps__out),
	.pst_out(f_pst_out),
	.Fc(Filter_Fc),
	.F0(F0)
);

sid_filter filter
(
	.clk(clk),
	.state(state[2:0]),
	.F0(F0),
	.Res_Filt(Filter_Res_Filt),
	.Mode_Vol(Filter_Mode_Vol),
	.voice1(voice_1),
	.voice2(voice_2),
	.voice3(voice_3),
	.ext_in($signed({ext_in_l[17], ext_in_l, 3'b000})),
	.audio(faudio)
);

// One filter pass per SID cycle: states 0..8, then wait for ce_1m.
always @(posedge clk) begin
	if (reset) begin
		state <= 0;
		f_acc_t <= 0;
		v <= 0;
		audio <= 0;
	end
	else begin
		if (ce_1m)
			state <= 0;
		else if (state != 4'd8)
			state <= state + 1'd1;

		case (state)
			4'd1: begin f_acc_t <= acc_t[0]; v <= 3'd0; end
			4'd3: begin f_acc_t <= acc_t[1]; v <= 3'd1; end
			4'd5: begin f_acc_t <= acc_t[2]; v <= 3'd2; end
		endcase

		case (state)
			4'd3, 4'd5, 4'd7: begin
				_st_out[v] <= f__st_out;
				p_t_out[v] <= f_p_t_out;
				ps__out[v] <= f_ps__out;
				pst_out[v] <= f_pst_out;
			end
		endcase

		if (state == 4'd8)
			audio <= faudio;
	end
end

assign audio_l = audio;
assign audio_r = audio;

// Unused MiSTer ports, kept for the fpga64_sid_iec interface.
wire unused = fc_offset_l[12] ^ fc_offset_r[12] ^ pot_x_r[0] ^ pot_y_r[0] ^
              ext_in_r[0] ^ filter_en[0] ^ filter_en[1] ^ mode[0] ^ mode[1] ^
              cfg[0] ^ cfg[1] ^ cfg[2] ^ cfg[3] ^ ld_clk ^ ld_addr[0] ^
              ld_data[0] ^ ld_wr;

endmodule
