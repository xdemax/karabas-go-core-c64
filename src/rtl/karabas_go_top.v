`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- Commodore 64 for Karabas Go (XC6SLX25, VGA through the video DAC, PCM5102).
--
-- Same machine and 720 x 576 @ 50 Hz video as the Mini G wrapper.  The board differences: VGA 8:8:8 +
-- V_CLK instead of HDMI, no FT_CLK_OUT, the FT812 SPI is on separate pins, MCU_SCK is not on a clock
-- pin (no IBUFG, bursts at the link clock), and the CF/FDC pins exist.
------------------------------------------------------------------------------------------------------------------*/

module karabas_go_top (
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

	//------------------ vga dac -------------
	output wire [7:0] 		VGA_R,
	output wire [7:0] 		VGA_G,
	output wire [7:0] 		VGA_B,
	output wire 			VGA_HS,
	output wire 			VGA_VS,
	output wire 			V_CLK,

	//------------------ ft812 spi and ctl ---
	output wire 			FT_SPI_CS_N,
	output wire 			FT_SPI_SCK,
	input wire 				FT_SPI_MISO,
	output wire 			FT_SPI_MOSI,
	input wire 				FT_INT_N,
	input wire 				FT_CLK,
	output wire 			FT_OE_N,

	//------------------ cf card -------------
	output wire [2:0] 	WA,
	output wire [1:0] 	WCS_N,
	output wire 			WRD_N,
	output wire 			WWR_N,
	output wire 			WRESET_N,
	inout wire [15:0] 	WD,

	//------------------ fdc -----------------
	input wire 				FDC_INDEX,
	output wire [1:0] 		FDC_DRIVE,
	output wire 			FDC_MOTOR,
	output wire 			FDC_DIR,
	output wire 			FDC_STEP,
	output wire 			FDC_WDATA,
	output wire 			FDC_WGATE,
	input wire 				FDC_TR00,
	input wire 				FDC_WPRT,
	input wire 				FDC_RDATA,
	output wire 			FDC_SIDE_N,

	//------------------ analog in/out -------
	output wire 			TAPE_OUT,
	input wire 				TAPE_IN,
	output wire 			BEEPER,

	//------------------ i2s dac -------------
	output wire          DAC_LRCK,
	output wire          DAC_DAT,
	output wire          DAC_BCK,
	output wire          DAC_MUTE,

	//------------------ mcu spi -------------
	input wire 				MCU_CS_N,
	input wire 				MCU_SCK,
	inout wire 				MCU_MOSI,
	output wire 			MCU_MISO,
	input wire 				MCU_SPI_FT_CS_N,
	input wire 				MCU_SPI_SD2_CS_N,
	inout wire [1:0] 		MCU_SPI_IO,  // [0] burst ready, [1] burst cs_n

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
assign BEEPER = 1'b0;
assign UART_CTS = 1'bz;
assign ESP_RESET_N = 1'bz;
assign ESP_BOOT_N = 1'bz;
assign MIDI_TX = 1'b1;
assign MIDI_CLK = 1'b1;
assign MIDI_RESET_N = 1'b1;
assign FT_OE_N = 1'b1;     // the FT812 does not drive the video DAC
assign DAC_MUTE = 1'b1;    // soft mute of the PCM5102: 1 = sound on
assign FDC_DRIVE = 2'b00;
assign FDC_MOTOR = 1'b0;
assign FDC_DIR = 1'b0;
assign FDC_STEP = 1'b0;
assign FDC_WDATA = 1'b0;
assign FDC_WGATE = 1'b0;
assign FDC_SIDE_N = 1'b1;
assign SDR_A = 13'd0;
assign SDR_CLK = 1'b0;
assign SDR_BA = 2'd0;
assign SDR_DQM = 2'b11;
assign SDR_WE_N = 1'b1;
assign SDR_CAS_N = 1'b1;
assign SDR_RAS_N = 1'b1;
assign SDR_DQ = 16'hzzzz;

// system clocks: VCO 1000 MHz (50 * 20); 31.25 MHz for both the C64 core
// and the VGA pixel clock (exact 1008x624 PAL timing), 8 MHz FT812,
// 25 MHz MCU, 62.5 MHz SRAM.  CLKOUT1 is the raw pixel clock before its BUFG.
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

// the pixel clock of the video DAC
ODDR2 u_v_clk(.Q(V_CLK), .C0(clk_vid), .C1(~clk_vid), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));

//---------- MCU ------------
wire [7:0] hid_kb_status, hid_kb_dat0, hid_kb_dat1, hid_kb_dat2, hid_kb_dat3, hid_kb_dat4, hid_kb_dat5;
wire [7:0] ms_x, ms_y;
wire [2:0] ms_b;
wire ms_upd;
wire [15:0] softsw_command, osd_command;
wire [1:0] hw_btn;
wire mcu_busy;
wire dvi_only;
wire matrix_cmd_wr;
wire [23:0] matrix_cmd;
wire [7:0] img_mounted, img_data, img_result;
wire [63:0] img_size;
wire [8:0] img_data_addr;
wire [15:0] img_sum;
wire [23:0] img_q_di;
wire img_data_wr, img_result_wr, img_q_wr, img_q_ack;
wire [7:0] rtc_a, rtc_do;

wire [7:0] kb_scancode;
wire kb_scancode_upd;

wire [12:0] joy_l, joy_r;
wire [1:0] btns;

wire file_reset, file_active, file_wr;
wire [31:0] file_size, file_addr;
wire [7:0] file_data, file_slot;

// MCU_SCK is not on a clock pin on the Go: no IBUFG, the link uses the pin directly and
// the bursts run at the link clock.
wire mcu_sck = MCU_SCK;

wire mcu_burst_ready;
assign MCU_SPI_IO[0] = mcu_burst_ready;
assign MCU_SPI_IO[1] = 1'bz;

wire mcu_ft_spi_on, mcu_ft_vga_on, mcu_ft_sck, mcu_ft_mosi, mcu_ft_cs_n;
assign FT_SPI_CS_N = mcu_ft_spi_on ? mcu_ft_cs_n : 1'b1;
assign FT_SPI_SCK = mcu_ft_spi_on ? MCU_SCK : 1'b1;
assign FT_SPI_MOSI = mcu_ft_spi_on ? mcu_ft_mosi : 1'b1;

kg_mcu #(
	.BURST_MAX_MHZ(0),
	.CS_FILTER(3),
	.ENABLE_RTC(0),
	.ENABLE_UART(0),
	.ENABLE_MATRIX(1),
	.ENABLE_DEBUG(0),
	.ENABLE_IMG(1),
	.ENABLE_FILE(1),
	.FILE_CMDS(0),
	.FILE_WR_EACH(0),
	.FILE_TO_ROM(0),
	.ENABLE_FT(1),
	.ENABLE_SD2(0)
) mcu(
	.CLK				(clk_host),
	.N_RESET			(locked),

	.MCU_MOSI		(MCU_MOSI),
	.MCU_MISO		(MCU_MISO),
	.MCU_SCK			(mcu_sck),
	.MCU_SS			(MCU_CS_N),

	.MCU_SPI_FT_SS	(MCU_SPI_FT_CS_N),
	.MCU_SPI_SD2_SS(MCU_SPI_SD2_CS_N),
	.MCU_BURST_CS_N(MCU_SPI_IO[1]),
	.MCU_BURST_READY(mcu_burst_ready),

	.FDD_CHNG_REQ	(1'b0),
	.FDD_CHNG_DS	(2'b00),
	.FDD_CHNG_WR	(),
	.FDD_CHNG		(),

	.MS_X				(ms_x),
	.MS_Y				(ms_y),
	.MS_Z				(),
	.MS_B				(ms_b),
	.MS_UPD			(ms_upd),

	.KB_STATUS		(hid_kb_status),
	.KB_DAT0			(hid_kb_dat0),
	.KB_DAT1			(hid_kb_dat1),
	.KB_DAT2			(hid_kb_dat2),
	.KB_DAT3			(hid_kb_dat3),
	.KB_DAT4			(hid_kb_dat4),
	.KB_DAT5			(hid_kb_dat5),

	.KB_SCANCODE	(kb_scancode),
	.KB_SCANCODE_UPD(kb_scancode_upd),
	.XT_SCANCODE	(),
	.XT_SCANCODE_UPD(),

	.JOY_L			(joy_l),
	.JOY_R			(joy_r),
	.BTNS				(btns),

	.RTC_A			(8'd0),
	.RTC_DI			(8'd0),
	.RTC_DO			(rtc_do),
	.RTC_CS			(1'b0),
	.RTC_WR_N		(1'b1),

	.UART_RX_DATA	(),
	.UART_RX_IDX	(),
	.UART_TX_DATA	(8'd0),
	.UART_TX_WR		(1'b0),
	.UART_TX_MODE	(1'b0),
	.UART_DLL		(8'd0),
	.UART_DLM		(8'd0),
	.UART_DLL_WR	(1'b0),
	.UART_DLM_WR	(1'b0),

	.ROMLOADER_ACTIVE(),
	.ROMLOAD_ADDR	(),
	.ROMLOAD_DATA	(),
	.ROMLOAD_WR		(),
	.IOCTL_ACTIVE	(),

	.SOFTSW_COMMAND(softsw_command),
	.OSD_COMMAND	(osd_command),

	.FT_SPI_ON		(mcu_ft_spi_on),
	.FT_VGA_ON		(mcu_ft_vga_on),
	.FT_SCK			(mcu_ft_sck),
	.FT_MISO			(FT_SPI_MISO),
	.FT_MOSI			(mcu_ft_mosi),
	.FT_CS_N			(mcu_ft_cs_n),
	.FT_RESET		(),

	.HWID				(),
	.CORE_BUILD		(),
	.FW_BUILD		(),
	.DVI_ONLY		(dvi_only),

	.SD2_MISO		(1'b1),
	.MATRIX_CMD		(matrix_cmd),
	.MATRIX_CMD_WR	(matrix_cmd_wr),
	.DEBUG_ADDR		(16'd0),
	.DEBUG_DATA		(16'd0),
	.IMG_Q_WR		(img_q_wr),
	.IMG_Q_DI		(img_q_di),
	.IMG_Q_ACK		(img_q_ack),
	.IMG_MOUNTED	(img_mounted),
	.IMG_SIZE		(img_size),
	.IMG_DATA_WR	(img_data_wr),
	.IMG_DATA_ADDR	(img_data_addr),
	.IMG_DATA		(img_data),
	.IMG_RESULT_WR	(img_result_wr),
	.IMG_RESULT		(img_result),
	.IMG_SUM			(img_sum),
	.PS2_COMMAND	(16'h0000),
	.PS2_COMMAND_WR(1'b0),
	.ESP_UART_RX_DATA(8'h00),
	.ESP_UART_RX_WR(1'b0),
	.FLASHBOOT_START(1'b0),
	.FLASHBOOT_COREID(5'd0),
	.PRN_DATA		(8'h00),
	.PRN_WR			(1'b0),

	.FILELOAD_RESET(file_reset),
	.FILELOAD_ACTIVE(file_active),
	.FILELOAD_SIZE	(file_size),
	.FILELOAD_ADDR	(file_addr),
	.FILELOAD_DATA	(file_data),
	.FILELOAD_WR		(file_wr),
	.FILELOAD_SLOT	(file_slot),

	.BUSY				(mcu_busy)
);

//---------- image files of the mcu: slot 0 = disk 8 ------------
wire [7:0] sdc_mounted;
wire [63:0] sdc_size;
wire [7:0] sdc_rd;
wire [31:0] sdc_sector;
wire [7:0] sd_rd = sdc_rd;
wire [7:0] sd_wr = 8'd0;
wire [31:0] sd_sector = sdc_sector;
wire sd_busy, sd_done, sd_error, sd_byte_strobe;
wire [2:0] sd_slot;
wire [8:0] sd_byte_index;
wire [7:0] sd_rd_data, sd_wr_data;
wire loader_busy;

img_sdc #(.OUT_LATENCY(3), .TIMEOUT(24'd5000000)) img(
	.clk					(clk_host),
	.reset				(areset),
	.img_mounted		(img_mounted),
	.img_size			(img_size),
	.img_data_wr		(img_data_wr),
	.img_data_addr		(img_data_addr),
	.img_data			(img_data),
	.img_result_wr		(img_result_wr),
	.img_result			(img_result),
	.img_sum				(img_sum),
	.img_q_wr			(img_q_wr),
	.img_q_di			(img_q_di),
	.img_q_ack			(img_q_ack),
	.sdc_img_mounted	(sdc_mounted),
	.sdc_img_size		(sdc_size),
	.sdc_rd				(sd_rd),
	.sdc_wr				(sd_wr),
	.sdc_sector			(sd_sector),
	.sdc_busy			(sd_busy),
	.sdc_done			(sd_done),
	.sdc_error			(sd_error),
	.sdc_slot			(sd_slot),
	.sdc_byte_in_strobe(sd_byte_strobe),
	.sdc_byte_addr		(sd_byte_index),
	.sdc_byte_in_data	(sd_rd_data),
	.sdc_byte_out_data(sd_wr_data)
);

//---------- Soft switches ------------
wire [31:0] softsw;
kg_soft_switches #(.N(2), .INIT(32'h00000000)) soft_switches(
	.clk		(clk_host),
	.command	(softsw_command),
	.regs		(softsw),
	.upd		()
);

//---------- video ------------
wire [23:0] vid_rgb, osd_rgb;
wire vid_hs, vid_vs, vid_de;
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
// holding c64_reset high for as long as softsw[0] stayed set hung the board.
reg softsw0_d = 1'b0;
reg [20:0] sw_reset_cnt = 21'd0;
always @(posedge clk_sys) begin
	softsw0_d <= softsw[0];
	if (softsw[0] && !softsw0_d)
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
	.sw_joy_swap(softsw[8]),
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

// the OSD commands of the mcu (host clock) into clk_vid: a value is taken when it is the same on two clocks
reg [15:0] osd_s1 = 16'd0, osd_s2 = 16'd0, osd_vid = 16'd0;
always @(posedge clk_vid) begin
	osd_s1 <= osd_command;
	osd_s2 <= osd_s1;
	if (osd_s1 == osd_s2) osd_vid <= osd_s2;
end

assign vid_rgb = c64_rgb;
assign vid_hs  = c64_hs;
assign vid_vs  = c64_vs;
assign vid_de  = c64_de;

kg_osd_overlay #(.H_OFFSET(176), .V_OFFSET(52), .H_DIV4_WIDTH(1200), .V_DIV4_HEIGHT(800)) overlay(
	.clk				(clk_vid),
	.rgb_i			(vid_rgb),
	.rgb_o			(osd_rgb),
	.hsync_i			(vid_hs),
	.vsync_i			(vid_vs),
	.v_offset		(11'd0),
	.h_offset		(11'd0),
	.osd_command	(osd_vid)
);

//---------- audio ------------
// Take one sample every 48 kHz and hold it for the whole audio period; the SID
// output changes at 31.25 MHz and the DAC must not catch a bus transition.
reg [15:0] aud_acc = 16'd0;   // 48 kHz from 31.25 MHz: +48 modulo 31250
reg [31:0] aud_hold = 32'd0;
always @(posedge clk_sys) begin
	if (aud_acc >= 16'd31250 - 16'd48) begin
		aud_acc <= aud_acc + 16'd48 - 16'd31250;
		aud_hold <= {c64_audio_l[17], c64_audio_l[17:3],
		             c64_audio_r[17], c64_audio_r[17:3]};
	end
	else
		aud_acc <= aud_acc + 16'd48;
end

// level meters on the two LED matrices of the MCU: peaks of L/R as CMD 70/71
audio_peaks #(.PERIOD_BITS(19)) matrix_peaks(
	.clk      (clk_host),
	.audio_l  (aud_hold[31:16]),
	.audio_r  (aud_hold[15:0]),
	.cmd_wr   (matrix_cmd_wr),
	.cmd      (matrix_cmd)
);

//---------- i2s DAC (PCM5102) ------------
wire i2s_din, i2s_bck, i2s_ws;
kg_pcm5102 #(.DIV_BITS(2)) dac(
	.clk		(clk_sys),
	.reset	(areset),
	.left		(aud_hold[31:16]),
	.right	(aud_hold[15:0]),
	.din		(i2s_din),
	.bck		(i2s_bck),
	.lrck		(i2s_ws)
);
// The Go board's PCM5102 takes BCK directly: kg_pcm5102 changes DIN/LRCK on the
// falling BCK, and the DAC samples the next rising edge (as in the MSX Go top).
assign DAC_BCK = i2s_bck;
assign DAC_LRCK = i2s_ws;
assign DAC_DAT = i2s_din;

//---------- VGA ------------
assign VGA_R = osd_rgb[23:16];
assign VGA_G = osd_rgb[15:8];
assign VGA_B = osd_rgb[7:0];
assign VGA_HS = ~vid_hs;
assign VGA_VS = ~vid_vs;

endmodule

`default_nettype wire
