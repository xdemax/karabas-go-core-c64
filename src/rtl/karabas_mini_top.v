`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- Commodore 64 for Karabas Mini rev A-F (XC6SLX25, HDMI + sigma-delta audio).
--
-- Same machine and video as the Mini G wrapper.  The board differences: sigma-delta DAC on AUDIO_L/R
-- instead of the PCM5102, MCU_SCK is not on a clock pin (no IBUFG, bursts at the link clock), FT_CLK_OUT
-- is E7 (MCU_IO<4> in the older pinout), and the FT812 / UART / MIDI pins differ.
------------------------------------------------------------------------------------------------------------------*/

module karabas_mini_top (
	//------------------ global clock --------
	input wire 				CLK_50MHZ,

	//------------------ esp8266 uart --------
	inout wire 				ESP_RESET_N,
	inout wire 				ESP_BOOT_N,
	inout wire 				UART_RX,
	inout wire 				UART_TX,
	inout wire 				UART_CTS,

	//------------------ sram ----------------
	output wire [20:0] 	MA,
	inout wire [15:0] 	MD,
	output wire [1:0] 	MWR_N,
	output wire [1:0] 	MRD_N,

	//------------------ sdram ---------------
	output wire [1:0] 	SDR_BA,
	output wire [12:0] 	SDR_A,
	output wire 			SDR_CLK,
	output wire [1:0] 	SDR_DQM,
	output wire 			SDR_WE_N,
	output wire 			SDR_CAS_N,
	output wire 			SDR_RAS_N,
	inout wire [15:0] 	SDR_DQ,

	//------------------ sd2 -----------------
	output wire 			SD_CS_N,
	output wire 			SD_CLK,
	inout wire 				SD_DI,
	inout wire 				SD_DO,
	input wire 				SD_DET_N,

	//------------------ ft812 rgb + sync ----
	input wire [7:0] 		VGA_R,
	input wire [7:0] 		VGA_G,
	input wire [7:0] 		VGA_B,
	input wire 				VGA_HS,
	input wire 				VGA_VS,

	//------------------ dvi / hdmi ----------
	output wire [3:0] 	TMDS_P,
	output wire [3:0] 	TMDS_N,

	//------------------ ft812 spi and ctl ---
	inout wire 				FT_SPI_CS_N,
	inout wire 				FT_SPI_SCK,
	input wire 				FT_SPI_MISO,
	inout wire 				FT_SPI_MOSI,
	input wire 				FT_INT_N,
	input wire 				FT_CLK,
	input wire 				FT_AUDIO,
	input wire 				FT_DE,
	input wire 				FT_DISP,
	output wire 			FT_RESET,
	output wire 			FT_CLK_OUT,

	//------------------ cf card -------------
	output wire [2:0] 	WA,
	output wire [1:0] 	WCS_N,
	output wire 			WRD_N,
	output wire 			WWR_N,
	output wire 			WRESET_N,
	inout wire [15:0] 	WD,

	//------------------ analog in/out -------
	output wire 			TAPE_OUT,
	input wire 				TAPE_IN,

	//------------------ sigma-delta audio ---
	output wire          AUDIO_L,
	output wire          AUDIO_R,

	//------------------ adc -----------------
	output wire 			ADC_CLK,
	inout wire 				ADC_BCK,
	inout wire 				ADC_LRCK,
	input wire 				ADC_DOUT,

	//------------------ mcu spi -------------
	input wire 				MCU_CS_N,
	input wire 				MCU_SCK,
	input wire 				MCU_MOSI,
	output wire 			MCU_MISO,
	inout wire [3:0] 		MCU_IO,  // [0] burst cs_n (input), [1] MCU_INT, [2] sd2 cs_n, [3] ft cs_n

	//------------------ midi ----------------
	output wire 			MIDI_TX,
	output wire 			MIDI_CLK,
	output wire 			MIDI_RESET_N,

	//------------------ optional flash ------
	output wire 			FLASH_CS_N,
	input wire  			FLASH_DO,
	output wire 			FLASH_DI,
	output wire 			FLASH_SCK,
	output wire 			FLASH_WP_N,
	output wire 			FLASH_HOLD_N
);

// unused
assign FLASH_CS_N = 1'b1;
assign FLASH_DI = 1'b1;
assign FLASH_SCK = 1'b0;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;
assign SD_CS_N = 1'b1;
assign SD_CLK = 1'b0;
assign SD_DI = 1'bz;
assign SD_DO = 1'bz;
assign WA = 3'd0;
assign WCS_N = 2'b11;
assign WRD_N = 1'b1;
assign WWR_N = 1'b1;
assign WRESET_N = 1'b0;
assign WD = 16'hzzzz;
assign TAPE_OUT = 1'b0;
assign UART_CTS = 1'bz;
assign ESP_RESET_N = 1'bz;
assign ESP_BOOT_N = 1'bz;
assign MIDI_TX = 1'b1;
assign MIDI_CLK = 1'b1;
assign MIDI_RESET_N = 1'b1;
assign FT_RESET = 1'b1;
assign ADC_CLK = 1'b0;
assign ADC_BCK = 1'bz;
assign ADC_LRCK = 1'bz;
assign SDR_A = 13'd0;
assign SDR_CLK = 1'b0;
assign SDR_BA = 2'd0;
assign SDR_DQM = 2'b11;
assign SDR_WE_N = 1'b1;
assign SDR_CAS_N = 1'b1;
assign SDR_RAS_N = 1'b1;
assign SDR_DQ = 16'hzzzz;

// system clocks: VCO 1000 MHz (50 * 20); 31.25 MHz for both the C64 core
// and the HDMI pixel clock (Tang/C64Nano-style exact 1008x624 PAL timing),
// 8 MHz FT812, 25 MHz MCU, 62.5 MHz SRAM.  CLKOUT1 is raw (the BUFGMUX of
// kg_hdmi_ft takes it); CLKOUT0 is the core clock at the same frequency.
wire [5:0] pll_clk;
wire locked;
kg_pll #(
	.DIVCLK_DIVIDE(1),
	.CLKFBOUT_MULT(20),
	.CLKOUT0_DIVIDE(32),
	.CLKOUT1_DIVIDE(32),
	.CLKOUT2_DIVIDE(125),
	.CLKOUT3_DIVIDE(40),
	.CLKOUT4_DIVIDE(16),
	.BUFG_MASK(6'b011101)
) pll (
	.clk_in		(CLK_50MHZ),
	.rst			(1'b0),
	.clk_out		(pll_clk),
	.locked		(locked)
);
wire clk_sys = pll_clk[0];
wire clk_vid_pll = pll_clk[1];
wire clk_8mhz = pll_clk[2];
wire clk_host = pll_clk[3];
wire clk_sram = pll_clk[4];
wire clk_vid;
BUFG bufg_clk_vid(.I(clk_vid_pll), .O(clk_vid));
wire areset = ~locked;

// ft clk 8mhz out: the FT812 must always have its clock
ODDR2 u_ft_clk(.Q(FT_CLK_OUT), .C0(clk_8mhz), .C1(~clk_8mhz), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));

//---------- MCU ------------
// karabas: MCU link v2 (karabas-go-firmware docs/link_v2.md, kg_mcu2)
wire [15:0] sw;                    // SYS switches, switch n = sw[n*8 +: 8]
wire [5:0] btns;
wire [1:0] hw_btn = btns[1:0];
wire mcu_busy;
wire dvi_only;
wire mcu_int;
wire matrix_cmd_wr;
wire [23:0] matrix_cmd;

// HID: PS/2 set 2 bytes (the keyboard of the C64) and the joysticks
wire [7:0] ps2_code;
wire ps2_kind, ps2_wr;
reg  ps2_upd_tgl = 1'b0;
always @(posedge clk_host)
	if (ps2_wr && !ps2_kind) ps2_upd_tgl <= ~ps2_upd_tgl;
wire [7:0] kb_scancode = ps2_code;
wire kb_scancode_upd = ps2_upd_tgl;
wire [15:0] joy_l16, joy_r16;
wire [12:0] joy_l = joy_l16[12:0];
wire [12:0] joy_r = joy_r16[12:0];

// LOAD: FL items come as LD kind 2 (the PRG file loader); kind 1 is accepted too
wire [1:0] ld_kind;
wire [7:0] ld_slot, ld_data;
wire [31:0] ld_size, ld_addr;
wire ld_start, ld_active, ld_end, ld_wr;
wire ld_file = (ld_kind == 2'd1) || (ld_kind == 2'd2);
wire file_reset = ld_start && ld_file;
wire file_active = ld_active && ld_file;
wire file_wr = ld_wr && ld_file;
wire [31:0] file_size = ld_size;
wire [31:0] file_addr = ld_addr;
wire [7:0] file_data = ld_data;
wire [7:0] file_slot = ld_slot;

// OSD: the bitmap of kg_l2_osd, drawn by kg_l2_osd_overlay in clk_vid
wire osd_wr, osd_en, osd_zoom;
wire [11:0] osd_waddr;
wire [7:0] osd_wdata;
wire [23:0] osd_fg, osd_bg;
wire [1:0] osd_alpha, osd_place;
wire [4:0] osd_px, osd_ph;
wire [3:0] osd_py;
wire [5:0] osd_pw;

// Before rev.G MCU_SCK is not on a clock pin: no IBUFG, kg_mcu2 takes the pin
// directly (CLOCK_DEDICATED_ROUTE = FALSE in the ucf).
wire mcu_sck = MCU_SCK;

assign MCU_IO[1] = mcu_int;
assign MCU_IO[0] = 1'bz;
assign MCU_IO[3:2] = 2'bzz;

wire mcu_ft_spi_on, mcu_ft_vga_on, mcu_ft_sck, mcu_ft_mosi, mcu_ft_cs_n;
assign FT_SPI_CS_N = mcu_ft_spi_on ? mcu_ft_cs_n : 1'b1;
assign FT_SPI_SCK = mcu_ft_spi_on ? MCU_SCK : 1'b0;
assign FT_SPI_MOSI = mcu_ft_spi_on ? mcu_ft_mosi : 1'b0;

//---------- image files of the mcu: slot 0 = disk 8 ------------
wire [7:0] sdc_mounted;
wire [63:0] sdc_size;
wire [7:0] sdc_rd;
wire [31:0] sdc_sector;
wire sd_busy, sd_done, sd_error, sd_byte_strobe;
wire [2:0] sd_slot;
wire [8:0] sd_byte_index;
wire [7:0] sd_rd_data;
wire loader_busy;

kg_mcu2 #(
	.CAPS(16'h0000),
	.SW_N(2),
	.SW_INIT(16'd0),
	.CS_FILTER(3),
	.ENABLE_OSD(1),
	.ENABLE_IMG(1),
	.IMG_OUT_LATENCY(3),
	.ENABLE_AUX(1),
	.ENABLE_FT(1),
	.ENABLE_SD2(0)
) mcu(
	.CLK				(clk_host),
	.N_RESET			(locked),

	.MCU_SCK			(mcu_sck),
	.MCU_MOSI		(MCU_MOSI),
	.MCU_MISO		(MCU_MISO),
	.MCU_SS			(MCU_CS_N),
	.MCU_INT			(mcu_int),
	.MCU_SPI_FT_SS	(MCU_IO[3]),
	.MCU_SPI_SD2_SS(1'b1),

	.SW				(sw),
	.SW_WR			(),
	.SW_INDEX		(),
	.SW_VALUE		(),
	.HW_ID			(),
	.DVI_ONLY		(dvi_only),
	.CORE_BUILD		(),
	.FW_BUILD		(),
	.BUSY				(mcu_busy),
	.BTNS				(btns),
	.RELOAD_REQ		(1'b0),
	.RELOAD_CORE	(8'd0),

	.KBD				(),
	.KBD_WR			(),
	.PS2_CODE		(ps2_code),
	.PS2_KIND		(ps2_kind),
	.PS2_WR			(ps2_wr),
	.MS_X				(),
	.MS_Y				(),
	.MS_Z				(),
	.MS_B				(),
	.MS_WR			(),
	.JOY_L			(joy_l16),
	.JOY_R			(joy_r16),
	.JOY_WR			(),
	.PS2_CMD			(16'h0000),
	.PS2_CMD_WR		(1'b0),

	.LD_KIND			(ld_kind),
	.LD_SLOT			(ld_slot),
	.LD_SIZE			(ld_size),
	.LD_START		(ld_start),
	.LD_ACTIVE		(ld_active),
	.LD_END			(ld_end),
	.LD_ADDR			(ld_addr),
	.LD_DATA			(ld_data),
	.LD_WR			(ld_wr),
	.LD_READY		(1'b1),

	.OSD_WR			(osd_wr), .OSD_WADDR(osd_waddr), .OSD_WDATA(osd_wdata), .OSD_EN(osd_en),
	.OSD_FG			(osd_fg), .OSD_BG(osd_bg), .OSD_ALPHA(osd_alpha), .OSD_PX(osd_px), .OSD_PY(osd_py),
	.OSD_PW			(osd_pw), .OSD_PH(osd_ph), .OSD_PLACE(osd_place), .OSD_ZOOM(osd_zoom),

	.SDC_IMG_MOUNTED(sdc_mounted), .SDC_IMG_SIZE(sdc_size),
	.SDC_RD			(sdc_rd), .SDC_WR(8'd0), .SDC_SECTOR(sdc_sector),
	.SDC_BUSY		(sd_busy), .SDC_DONE(sd_done), .SDC_ERROR(sd_error), .SDC_SLOT(sd_slot),
	.SDC_BYTE_IN_STROBE(sd_byte_strobe), .SDC_BYTE_ADDR(sd_byte_index),
	.SDC_BYTE_IN_DATA(sd_rd_data), .SDC_BYTE_OUT_DATA(8'd0),
	.IMG_WP			(), .IMG_PHYS_WR(), .IMG_PHYS(), .IMG_FLUSH(),
	.FDD_CHNG_WR	(), .FDD_CHNG(), .FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0),
	.IMG_ACTIVE		(),
	.BK_MOUNT		(1'b0), .BK_FLUSHED(1'b0), .BK_SLOT(3'd0), .BK_SIZE(32'd0),
	.BK_KIND			(8'd0), .BK_RESULT(8'd0),

	.PORT_OUT_DATA	(), .PORT_OUT_WR(), .PORT_OUT_READY(4'd0),
	.PORT_IN_DATA	(32'd0), .PORT_IN_WR(4'd0), .PORT_CFG(128'd0), .PORT_IN_FULL(),
	.PORT_STAT		(), .PORT_STAT_WR(),

	.RTC_A			(8'd0), .RTC_DI(8'd0), .RTC_CS(1'b0), .RTC_WR_N(1'b1), .RTC_DO(),
	.MATRIX_CMD		(matrix_cmd), .MATRIX_CMD_WR(matrix_cmd_wr),
	.DEBUG_ADDR		(16'd0), .DEBUG_DATA(16'd0),

	.FT_SPI_ON		(mcu_ft_spi_on), .FT_VGA_ON(mcu_ft_vga_on), .FT_RESET(),
	.FT_SCK			(mcu_ft_sck), .FT_MOSI(mcu_ft_mosi), .FT_CS_N(mcu_ft_cs_n), .FT_MISO(FT_SPI_MISO),
	.SD2_SCK			(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

//---------- switches (kg_mcu2 SYS) ------------
wire sw_joy_swap = sw[8];   // switch 1: Joystick swap

//---------- video ------------
wire [23:0] vid_rgb, osd_rgb;
wire vid_hs, vid_vs, vid_de;
wire osd_hs, osd_vs, osd_de;
wire [23:0] c64_rgb;
wire c64_hs, c64_vs, c64_de;
wire signed [17:0] c64_audio_l, c64_audio_r;
// The ROM loader writes the overlay while the C64 keeps running.  Reset the
// C64 for ~67 ms after a load/eject has finished so the new ROM takes effect.
wire rom_busy;                 // clk_host, from c64_machine
reg  rom_busy_s1 = 1'b0;
reg  rom_busy_s2 = 1'b0;
reg [20:0] rom_reset_cnt = 21'd0;
always @(posedge clk_sys) begin
	rom_busy_s1 <= rom_busy;
	rom_busy_s2 <= rom_busy_s1;
	if (rom_busy_s1)
		rom_reset_cnt <= 21'd0;
	else if (rom_busy_s2)          // s1 = 0, s2 = 1: falling edge
		rom_reset_cnt <= 21'h1FFFFF;
	else if (rom_reset_cnt != 21'd0)
		rom_reset_cnt <= rom_reset_cnt - 21'd1;
end
wire rom_reset = |rom_reset_cnt;

// OSD Reset arrives as a soft-switch level.  Use its rising edge as a pulse:
// holding c64_reset high for as long as sw[0] stayed set hung the board.
reg softsw0_d = 1'b0;
reg [20:0] sw_reset_cnt = 21'd0;
always @(posedge clk_sys) begin
	softsw0_d <= sw[0];
	if (sw[0] && !softsw0_d)
		sw_reset_cnt <= 21'h1FFFFF;
	else if (sw_reset_cnt != 21'd0)
		sw_reset_cnt <= sw_reset_cnt - 21'd1;
end
wire sw_reset = |sw_reset_cnt;

wire c64_reset = ~locked | hw_btn[0] | rom_reset | sw_reset;
// image mounts survive a C64/OSD reset; only a power-on clears them
wire reset_host = ~locked;

c64_machine machine(
	.clk_sys		(clk_sys),
	.clk_sram	(clk_sram),
	.clk_vid		(clk_vid),
	.clk_host		(clk_host),
	.reset		(c64_reset),
	.reset_host	(reset_host),
	.sdc_img_mounted(sdc_mounted),
	.sdc_img_size	(sdc_size),
	.sdc_rd			(sdc_rd),
	.sdc_sector		(sdc_sector),
	.sdc_busy		(sd_busy),
	.sdc_done		(sd_done),
	.sdc_error		(sd_error),
	.sdc_slot		(sd_slot),
	.sdc_byte_strobe(sd_byte_strobe),
	.sdc_byte_addr	(sd_byte_index),
	.sdc_byte_data	(sd_rd_data),
	.loader_busy	(loader_busy),
	.rom_busy		(rom_busy),
	.file_active	(file_active),
	.file_reset		(file_reset),
	.file_wr		(file_wr),
	.file_size		(file_size),
	.file_addr		(file_addr),
	.file_data		(file_data),
	.file_slot		(file_slot),
	.kb_scancode	(kb_scancode),
	.kb_scancode_upd(kb_scancode_upd),
	.joy_l		(joy_l),
	.joy_r		(joy_r),
	.sw_joy_swap(sw_joy_swap),
	.tape_in(TAPE_IN),
	.MA			(MA),
	.MD			(MD),
	.MWR_N		(MWR_N),
	.MRD_N		(MRD_N),
	.rgb			(c64_rgb),
	.hs			(c64_hs),
	.vs			(c64_vs),
	.de			(c64_de),
	.audio_l		(c64_audio_l),
	.audio_r		(c64_audio_r),
	.drive_led	()
);

assign vid_rgb = c64_rgb;
assign vid_hs  = c64_hs;
assign vid_vs  = c64_vs;
assign vid_de  = c64_de;

// the bitmap OSD of link v2 (kg_l2_osd_overlay): the settings cross from clk_host
// internally, the picture is centred in the active area (scale 2 at 720 x 576)
kg_l2_osd_overlay overlay(
	.wclk			(clk_host),
	.osd_wr		(osd_wr), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata), .osd_en(osd_en),
	.osd_fg		(osd_fg), .osd_bg(osd_bg), .osd_alpha(osd_alpha), .osd_px(osd_px), .osd_py(osd_py),
	.osd_pw		(osd_pw), .osd_ph(osd_ph), .osd_place(osd_place), .osd_zoom(osd_zoom),
	.icon_on		(8'd0), .icon_act(8'd0),
	.clk			(clk_vid),
	.rgb_i		(vid_rgb), .hs_i(vid_hs), .vs_i(vid_vs), .de_i(vid_de),
	.rgb_o		(osd_rgb), .hs_o(osd_hs), .vs_o(osd_vs), .de_o(osd_de)
);

//---------- hdmi ------------
// FT video is not used (ft_sel = 0); FT_CLK is not on a clock pin before rev.G.
wire ft_clk_int = clk_8mhz;

// the audio of the C64 (clk_sys) into clk_vid: take one sample every 48 kHz and
// hold it for the whole audio period, as the MSX/Sega cores do.  The SID output
// changes at 31.25 MHz; feeding that directly into the HDMI sampler / I2S DAC
// lets them catch a bus transition (clicks).  The sample is stable for ~20 us.
reg [15:0] aud_acc = 16'd0;   // 48 kHz from 31.25 MHz: +48 modulo 31250
reg [31:0] aud_hold = 32'd0;
reg        aud_tgl = 1'b0;
always @(posedge clk_sys) begin
	if (aud_acc >= 16'd31250 - 16'd48) begin
		aud_acc <= aud_acc + 16'd48 - 16'd31250;
		aud_hold <= {c64_audio_l[17], c64_audio_l[17:3],
		             c64_audio_r[17], c64_audio_r[17:3]};
		aud_tgl <= ~aud_tgl;
	end
	else
		aud_acc <= aud_acc + 16'd48;
end

wire aud_tgl_vid;
kg_sync aud_sync (.clk(clk_vid), .d(aud_tgl), .q(aud_tgl_vid));
reg        aud_tgl_vid_d = 1'b0;
reg [31:0] aud_vid = 32'd0;
always @(posedge clk_vid) begin
	aud_tgl_vid_d <= aud_tgl_vid;
	if (aud_tgl_vid != aud_tgl_vid_d)
		aud_vid <= aud_hold;
end

// level meters on the two LED matrices of the MCU: peaks of L/R as CMD 70/71
audio_peaks #(.PERIOD_BITS(19)) matrix_peaks(
	.clk      (clk_host),
	.audio_l  (aud_hold[31:16]),
	.audio_r  (aud_hold[15:0]),
	.cmd_wr   (matrix_cmd_wr),
	.cmd      (matrix_cmd)
);

kg_hdmi_ft #(.SAMPLERATE(48000), .CLKRATE(31250000), .REF_MHZ(8'd31)) hdmi_top(
	.clk				(ft_clk_int),
	.clk_ref			(clk_vid),
	.clk_ref_pll		(clk_vid_pll),
	.clk_8			(clk_8mhz),
	.reset			(areset),

	.vga_rgb			(osd_rgb),
	.vga_hs			(osd_hs),
	.vga_vs			(osd_vs),
	.vga_de			(osd_de),

	.ft_rgb			({VGA_R, VGA_G, VGA_B}),
	.ft_hs			(VGA_HS),
	.ft_vs			(VGA_VS),
	.ft_de			(FT_DE),

	.ft_sel			(1'b0),

	.audio_en		(~dvi_only),
	.audio_l			(aud_vid[31:16]),
	.audio_r			(aud_vid[15:0]),

	.tmds_p			(TMDS_P),
	.tmds_n			(TMDS_N),

	.freq				()
);

//---------- sigma-delta audio (Mini rev A-F) ------------
// The 48 kHz sample is already held on clk_sys; offset binary for the first-order DAC.
kg_sigma_delta_dac dac_l (
	.clk		(clk_sys),
	.reset	(areset),
	.din		({~aud_hold[31], aud_hold[30:16]}),
	.dout		(AUDIO_L)
);
kg_sigma_delta_dac dac_r (
	.clk		(clk_sys),
	.reset	(areset),
	.din		({~aud_hold[15], aud_hold[14:0]}),
	.dout		(AUDIO_R)
);

endmodule

`default_nettype wire
