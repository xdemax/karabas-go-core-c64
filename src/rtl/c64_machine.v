// The Commodore 64 machine of the Karabas Mini G: the MiSTer fpga64_sid_iec (6510, VIC-II, CIAs,
// SID), the cartridge logic, the SRAM controller, the video output and the 1541 drive.
`timescale 1ns / 1ps
`default_nettype none

module c64_machine (
	input wire clk_sys,
	input wire clk_sram,
	input wire clk_vid,
	input wire clk_host,
	input wire reset,          // C64/1541 reset (power-on, OSD, button, ROM load)
	input wire reset_host,     // power-on only: image mounts survive a C64 reset

	// disk/ROM image loader (img_sdc, clk_host)
	input wire [7:0]   sdc_img_mounted,
	input wire [63:0]  sdc_img_size,
	output wire [7:0]  sdc_rd,
	output wire [31:0] sdc_sector,
	input wire         sdc_busy,
	input wire         sdc_done,
	input wire         sdc_error,
	input wire [2:0]   sdc_slot,
	input wire         sdc_byte_strobe,
	input wire [8:0]   sdc_byte_addr,
	input wire [7:0]   sdc_byte_data,
	output wire        loader_busy,
	output wire        rom_busy,

	// ROM file loader (FILELOAD, clk_host)
	input wire         file_active,
	input wire         file_reset,
	input wire         file_wr,
	input wire [31:0]  file_size,
	input wire [31:0]  file_addr,
	input wire [7:0]   file_data,
	input wire [7:0]   file_slot,

	// USB keyboard (PS/2 set 2 bytes from the MCU) and joysticks
	input wire [7:0] kb_scancode,
	input wire kb_scancode_upd,
	input wire [12:0] joy_l,
	input wire [12:0] joy_r,
	input wire sw_joy_swap,

	// SRAM
	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N,
	output wire [1:0] MRD_N,

	// video (clk_vid)
	output wire [23:0] rgb,
	output wire hs,
	output wire vs,
	output wire de,

	// audio (clk_sys, 18 bit two's complement)
	output wire signed [17:0] audio_l,
	output wire signed [17:0] audio_r,

	// 1541 activity
	output wire drive_led
);

// ------------------------------------------------------------------ PS/2 keyboard
reg [10:0] ps2_key = 11'd0;
reg kb_upd_d = 1'b0;
reg kb_ext = 1'b0, kb_rel = 1'b0;

always @(posedge clk_sys) begin
	kb_upd_d <= kb_scancode_upd;
	if (reset) begin
		ps2_key <= 11'd0;
		kb_ext <= 1'b0;
		kb_rel <= 1'b0;
	end
	else if (kb_scancode_upd != kb_upd_d) begin
		if (kb_scancode == 8'hE0)
			kb_ext <= 1'b1;
		else if (kb_scancode == 8'hF0)
			kb_rel <= 1'b1;
		else begin
			ps2_key <= {~ps2_key[10], ~kb_rel, kb_ext, kb_scancode};
			kb_ext <= 1'b0;
			kb_rel <= 1'b0;
		end
	end
end

// PRG autostart: after the loader releases the C64, type RUN + Enter.
reg        prg_run_s1 = 1'b0, prg_run_s2 = 1'b0, prg_run_d = 1'b0;
reg        inj_active = 1'b0, inj_tgl = 1'b0;
reg [3:0]  inj_state = 4'd0;
reg [24:0] inj_timer = 25'd0;
reg [10:0] inj_key = 11'd0;
wire [10:0] ps2_key_core = inj_active ? inj_key : ps2_key;

always @(posedge clk_sys) begin
	prg_run_s1 <= prg_run;
	prg_run_s2 <= prg_run_s1;
	prg_run_d  <= prg_run_s2;

	if (reset) begin
		inj_active <= 1'b0;
		inj_state  <= 4'd0;
		inj_timer  <= 25'd0;
		inj_key    <= 11'd0;
		inj_tgl    <= 1'b0;
	end
	else if (!inj_active) begin
		inj_key <= 11'd0;
		if (prg_run_s2 && !prg_run_d) begin
			inj_active <= 1'b1;
			inj_state  <= 4'd0;
			inj_timer  <= 25'd20_000_000; // wait for KERNAL boot ~0.64 s
			inj_tgl    <= 1'b0;
		end
	end
	else if (inj_timer != 25'd0)
		inj_timer <= inj_timer - 25'd1;
	else begin
		case (inj_state)
			4'd0: begin // R press
				inj_key <= {~inj_tgl, 1'b1, 1'b0, 8'h2D};
				inj_tgl <= ~inj_tgl;
				inj_state <= 4'd1;
				inj_timer <= 25'd1_280_000;
			end
			4'd1: begin // R release
				inj_key <= {~inj_tgl, 1'b0, 1'b0, 8'h2D};
				inj_tgl <= ~inj_tgl;
				inj_state <= 4'd2;
				inj_timer <= 25'd1_280_000;
			end
			4'd2: begin // U press
				inj_key <= {~inj_tgl, 1'b1, 1'b0, 8'h3C};
				inj_tgl <= ~inj_tgl;
				inj_state <= 4'd3;
				inj_timer <= 25'd1_280_000;
			end
			4'd3: begin // U release
				inj_key <= {~inj_tgl, 1'b0, 1'b0, 8'h3C};
				inj_tgl <= ~inj_tgl;
				inj_state <= 4'd4;
				inj_timer <= 25'd1_280_000;
			end
			4'd4: begin // N press
				inj_key <= {~inj_tgl, 1'b1, 1'b0, 8'h31};
				inj_tgl <= ~inj_tgl;
				inj_state <= 4'd5;
				inj_timer <= 25'd1_280_000;
			end
			4'd5: begin // N release
				inj_key <= {~inj_tgl, 1'b0, 1'b0, 8'h31};
				inj_tgl <= ~inj_tgl;
				inj_state <= 4'd6;
				inj_timer <= 25'd1_280_000;
			end
			4'd6: begin // Enter press
				inj_key <= {~inj_tgl, 1'b1, 1'b0, 8'h5A};
				inj_tgl <= ~inj_tgl;
				inj_state <= 4'd7;
				inj_timer <= 25'd1_280_000;
			end
			4'd7: begin // Enter release
				inj_key <= {~inj_tgl, 1'b0, 1'b0, 8'h5A};
				inj_tgl <= ~inj_tgl;
				inj_state <= 4'd8;
				inj_timer <= 25'd1_280_000;
			end
			default: begin
				inj_active <= 1'b0;
				inj_key <= 11'd0;
			end
		endcase
	end
end

// ------------------------------------------------------------------ joysticks
// Karabas bits: 1 up, 2 down, 3 left, 4 right, 6 A, 7 B, 8 C
wire [6:0] joy_a = sw_joy_swap ?
	{joy_r[8], joy_r[7], joy_r[6], joy_r[4], joy_r[3], joy_r[2], joy_r[1]} :
	{joy_l[8], joy_l[7], joy_l[6], joy_l[4], joy_l[3], joy_l[2], joy_l[1]};
wire [6:0] joy_b = sw_joy_swap ?
	{joy_l[8], joy_l[7], joy_l[6], joy_l[4], joy_l[3], joy_l[2], joy_l[1]} :
	{joy_r[8], joy_r[7], joy_r[6], joy_r[4], joy_r[3], joy_r[2], joy_r[1]};

// ------------------------------------------------------------------ C64
wire [15:0] c64_addr;
wire [7:0] c64_mem_din, c64_mem_dout;
wire cart_game, cart_exrom;
wire [7:0] c64_data_out, c64_data_in;
wire ram_ce, ram_we;
wire io_cycle, ext_cycle, refresh;
wire c64_hsync, c64_vsync, c64_pixel_ce;
wire [7:0] vic_r, vic_g, vic_b;
wire [17:0] sid_audio_l, sid_audio_r;
wire c64_pause;

wire c64_iec_data_o, c64_iec_clk_o, c64_iec_atn_o;
reg c64_iec_data_i, c64_iec_clk_i;
wire drive_iec_data_o, drive_iec_clk_o;

wire prg_hold, prg_run;


// CRT cartridge loader (FL item, slot 4)
wire        crt_cart_loading;
wire [7:0]  crt_cart_id;
wire        crt_cart_exrom, crt_cart_game;
wire        crt_bank_hi, crt_bank_16k;
wire [7:0]  crt_bank_num, crt_bank_addr;
wire        crt_bank_wr_tgl;
wire        crt_hold;
wire        tap_busy;
reg         tap_busy_s1 = 1'b0, tap_busy_s2 = 1'b0;
always @(posedge clk_sys) begin
	tap_busy_s1 <= tap_busy;
	tap_busy_s2 <= tap_busy_s1;
end
wire        crt_busy;
wire        crt_req;
wire [20:0] crt_addr;
wire [7:0]  crt_data;
wire        crt_ack;

reg [2:0] cart_bank_tgl_s = 3'b000;
always @(posedge clk_sys)
	cart_bank_tgl_s <= {cart_bank_tgl_s[1:0], crt_bank_wr_tgl};
wire crt_bank_wr = cart_bank_tgl_s[2] ^ cart_bank_tgl_s[1];

reg cart_hold_s1 = 1'b0, cart_hold_s2 = 1'b0;
always @(posedge clk_sys) begin
	cart_hold_s1 <= crt_hold;
	cart_hold_s2 <= cart_hold_s1;
end

// The PRG loader runs in clk_host but must also abort on the core reset
// (F12), otherwise a stuck loader keeps the C64 in reset forever.
reg reset_host_s1 = 1'b0, reset_host_s2 = 1'b0;
always @(posedge clk_host) begin
	reset_host_s1 <= reset;
	reset_host_s2 <= reset_host_s1;
end
wire prg_reset = reset_host | reset_host_s2;

// $FFCF is the KERNAL CHRIN entry the BASIC READY loop sits in.  This is the
// same "boot finished" point used by the MiSTer C64 autoboot.
reg c64_at_ffcf = 1'b0;
always @(posedge clk_sys)
	c64_at_ffcf <= (c64_addr == 16'hFFCF);
reg [1:0] prg_boot_s = 2'b00;
always @(posedge clk_host)
	prg_boot_s <= {prg_boot_s[0], c64_at_ffcf};
wire prg_boot_ready = prg_boot_s[1];

reg prg_hold_s1, prg_hold_s2;
always @(posedge clk_sys) begin
	prg_hold_s1 <= prg_hold;
	prg_hold_s2 <= prg_hold_s1;
end
wire c64_core_reset = reset | prg_hold_s2 | cart_hold_s2 | tap_busy_s2;

wire nmi, cart_oe, io_rom, cart_mem_req;
wire [7:0] cart_data;
wire romL, romH, UMAXromH, IOE, IOF;
wire freeze_key, mod_key, nmi_ack;

wire [24:0] cart_addr;
wire cart_ce, cart_we;
wire [7:0] cart_wrdata;

// ------------------------------------------------------------------ image mount tracker
// img_sdc reports a mount as a one-clock pulse with the size of the slot.
// Keep a persistent mask/size here; the disk and ROM loaders both use it.
wire [7:0]  img_mounted;
wire [63:0] img_size0, img_size2, img_size3, img_size4, img_size5, img_size6;
wire [7:0]  img_mount_pulse, img_eject_pulse;

c64_img_mount img_mount(
	.clk(clk_host),
	.reset(reset_host),
	.sdc_img_mounted(sdc_img_mounted),
	.sdc_img_size(sdc_img_size),
	.mounted(img_mounted),
	.size0(img_size0),
	.size2(img_size2),
	.size3(img_size3),
	.size4(img_size4),
	.size5(img_size5),
	.size6(img_size6),
	.mount_pulse(img_mount_pulse),
	.eject_pulse(img_eject_pulse)
);

// ------------------------------------------------------------------ ROM overlay loader
wire [13:0] c64rom_addr;
wire [7:0]  c64rom_data;
wire        c64rom_wr;
wire [13:0] c1541rom_addr;
wire [7:0]  c1541rom_data;
wire        c1541rom_wr;
wire        kernal_loaded;
wire        basic_loaded;
wire [1:0]  c1541_loaded;
wire [7:0]  rom_sdc_rd;
wire [31:0] rom_sdc_sector;

c64_rom_loader rom_loader(
	.clk(clk_host),
	.reset(reset_host),
	.mounted(img_mounted),
	.size2(img_size2),
	.size3(img_size3),
	.mount_pulse(img_mount_pulse),
	.eject_pulse(img_eject_pulse),
	.sdc_rd(rom_sdc_rd),
	.sdc_sector(rom_sdc_sector),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_slot(sdc_slot),
	.sdc_byte_strobe(sdc_byte_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_data(sdc_byte_data),
	.c64rom_addr(c64rom_addr),
	.c64rom_data(c64rom_data),
	.c64rom_wr(c64rom_wr),
	.c1541rom_addr(c1541rom_addr),
	.c1541rom_data(c1541rom_data),
	.c1541rom_wr(c1541rom_wr),
	.kernal_loaded(kernal_loaded),
	.basic_loaded(basic_loaded),
	.c1541_loaded(c1541_loaded),
	.busy(rom_busy)
);

// one img_sdc request bus: disk 0 wins, then ROM 2/3, then PRG/CRT/TAP 4/5/6
wire [7:0]  d64_sdc_rd;
wire [31:0] d64_sdc_sector;
wire [7:0]  imgfile_sdc_rd;
wire [31:0] imgfile_sdc_sector;

assign sdc_rd = d64_sdc_rd | rom_sdc_rd | imgfile_sdc_rd;
assign sdc_sector = (d64_sdc_rd != 8'd0) ? d64_sdc_sector :
                    (rom_sdc_rd != 8'd0) ? rom_sdc_sector : imgfile_sdc_sector;

fpga64_sid_iec c64(
	.clk32       (clk_sys),
	.reset_n     (~c64_core_reset),
	.bios        (2'b00),
	.pause       (1'b0),
	.pause_out   (c64_pause),

	.ps2_key     (ps2_key_core),
	// Keep the physical key matrix across a C64 reset: Final Cartridge III
	// and similar carts check RUN/STOP at boot, so a held key must survive.
	.kbd_reset   (reset_host),
	.shift_mod   (2'b00),

	.ramAddr     (c64_addr),
	.ramDin      (c64_data_in),
	.ramDout     (c64_data_out),
	.ramCE       (ram_ce),
	.ramWE       (ram_we),

	.io_cycle    (io_cycle),
	.ext_cycle   (ext_cycle),
	.refresh     (refresh),

	.cia_mode    (1'b0),
	.turbo_mode  (2'b00),
	.turbo_speed (2'b00),

	.vic_variant (2'b00),
	.ntscMode    (1'b0),
	.hsync       (c64_hsync),
	.vsync       (c64_vsync),
	.pixel_ce    (c64_pixel_ce),
	.palette     (3'd0),
	.r           (vic_r),
	.g           (vic_g),
	.b           (vic_b),

	.game        (cart_game),
	.exrom       (cart_exrom),
	.io_rom      (io_rom),
	.io_ext      (cart_oe),
	.io_data     (cart_data),
	.irq_n       (1'b1),
	.nmi_n       (~nmi),
	.nmi_ack     (nmi_ack),
	.romL        (romL),
	.romH        (romH),
	.UMAXromH    (UMAXromH),
	.IOE         (IOE),
	.IOF         (IOF),
	.freeze_key  (freeze_key),
	.mod_key     (mod_key),
	.tape_play   (),
	.tape_rew    (),
	.tape_stop   (),
	.tape_ff     (),
	.tape_reset_counter (),

	.dma_req     (1'b0),
	.dma_cycle   (),
	.dma_addr    (16'd0),
	.dma_dout    (8'd0),
	.dma_din     (),
	.dma_we      (1'b0),
	.irq_ext_n   (1'b1),

	.joyA        (joy_a),
	.joyB        (joy_b),
	.pot1        (8'hFF),
	.pot2        (8'hFF),
	.pot3        (8'hFF),
	.pot4        (8'hFF),

	.audio_l     (sid_audio_l),
	.audio_r     (sid_audio_r),
	.sid_filter  (2'b11),
	.sid_ver     (2'b00),
	.sid_mode    (3'd0),
	.sid_cfg     (4'd0),
	.sid_fc_off_l(13'd0),
	.sid_fc_off_r(13'd0),
	.sid_ld_clk  (clk_sys),
	.sid_ld_addr (12'd0),
	.sid_ld_data (16'd0),
	.sid_ld_wr   (1'b0),
	.sid_digifix (1'b0),

	.pb_i        (8'hFF),
	.pb_o        (),
	.pa2_i       (1'b1),
	.pa2_o       (),
	.pc2_n_o     (),
	.flag2_n_i   (1'b1),
	.sp2_i       (1'b1),
	.sp2_o       (),
	.sp1_i       (1'b1),
	.sp1_o       (),
	.cnt2_i      (1'b1),
	.cnt2_o      (),
	.cnt1_i      (1'b1),
	.cnt1_o      (),

	.iec_data_o  (c64_iec_data_o),
	.iec_data_i  (c64_iec_data_i),
	.iec_clk_o   (c64_iec_clk_o),
	.iec_clk_i   (c64_iec_clk_i),
	.iec_atn_o   (c64_iec_atn_o),

	.c64rom_addr (c64rom_addr),
	.c64rom_data (c64rom_data),
	.c64rom_wr   (c64rom_wr),
	.c64rom_clk  (clk_host),
	.kernal_loaded(kernal_loaded),
	.basic_loaded(basic_loaded),

	.cass_motor  (cass_motor),
	.cass_write  (cass_write),
	.cass_sense  (cass_sense),
	.cass_read   (cass_read)
);

// The SID output is unipolar: the voice/filter path returns a positive
// 18-bit value with a large DC component.  Do the DC removal in the unsigned
// domain (subtract a slow average of the unsigned sample), then the result is
// a signed AC signal.  Treating the raw value as signed made a step at the
// middle of the scale, which clicked on loud effects and took away headroom.
// Shift 18 at 31.25 MHz: time constant ~8.4 ms, high-pass ~19 Hz.
wire signed [19:0] aud_raw_l = {2'b00, sid_audio_l};
wire signed [19:0] aud_raw_r = {2'b00, sid_audio_r};
reg  signed [19:0] aud_dc_l = 20'sd0;
reg  signed [19:0] aud_dc_r = 20'sd0;
reg  signed [19:0] aud_ac_l = 20'sd0;
reg  signed [19:0] aud_ac_r = 20'sd0;
always @(posedge clk_sys) begin
	if (reset) begin
		aud_dc_l <= 20'sd0;
		aud_dc_r <= 20'sd0;
		aud_ac_l <= 20'sd0;
		aud_ac_r <= 20'sd0;
	end
	else begin
		aud_dc_l <= aud_dc_l + ((aud_raw_l - aud_dc_l) >>> 18);
		aud_dc_r <= aud_dc_r + ((aud_raw_r - aud_dc_r) >>> 18);
		aud_ac_l <= aud_raw_l - aud_dc_l;
		aud_ac_r <= aud_raw_r - aud_dc_r;
	end
end

assign audio_l = aud_ac_l[17:0];
assign audio_r = aud_ac_r[17:0];

// ------------------------------------------------------------------ cartridge
cartridge cart(
	.clk32(clk_sys),
	// MiSTer resets the cartridge with the C64: a game may have switched to
	// a non-boot bank/mode, and the KERNAL reset check must see bank 0 again.
	.reset_n(~c64_core_reset),

	.cart_loading(crt_cart_loading),
	.cart_id(crt_cart_id),
	.cart_exrom(crt_cart_exrom),
	.cart_game(crt_cart_game),
	.cart_bank_hi(crt_bank_hi),
	.cart_bank_16k(crt_bank_16k),
	.cart_bank_num(crt_bank_num),
	.cart_bank_addr(crt_bank_addr),
	.cart_bank_wr(crt_bank_wr),
	.cart_boot(1'b1),

	.exrom(cart_exrom),
	.game(cart_game),

	.romL(romL),
	.romH(romH),
	.UMAXromH(UMAXromH),
	.IOE(IOE),
	.IOF(IOF),
	.mem_write(ram_we),
	.mem_ce(ram_ce),
	.mem_ce_out(cart_ce),
	.mem_write_out(cart_we),
	.mem_in(c64_mem_dout),
	.mem_out(cart_wrdata),
	.mem_addr(cart_addr),
	.mem_req(cart_mem_req),
	.mem_cycle(io_cycle),
	.IO_rom(io_rom),
	.IO_rd(cart_oe),
	.IO_data(cart_data),
	.addr_in(c64_addr),
	.data_in(c64_data_out),
	.data_out(c64_data_in),

	.freeze_key(freeze_key),
	.mod_key(mod_key),
	.nmi(nmi),
	.nmi_ack(nmi_ack)
);

// ------------------------------------------------------------------ 1541
wire [18:0] dsk_addr;
wire [7:0] dsk_data_in;
wire        dsk_wr;
wire host_loadrom;

c1541_sd drive(
	.clk32(clk_sys),
	.clk32n(1'b0),
	.clk_c1541(clk_sys),
	.disk_num(10'd0),

	.iec_atn_i(~c64_iec_atn_o),
	.iec_data_i(~c64_iec_data_o),
	.iec_clk_i(~c64_iec_clk_o),
	.iec_data_o(drive_iec_data_o),
	.iec_clk_o(drive_iec_clk_o),
	.iec_reset_i(reset),

	.c1541rom_clk(clk_host),
	.c1541rom_wr(c1541rom_wr),
	.c1541rom_addr(c1541rom_addr),
	.c1541rom_data(c1541rom_data),
	.c1541_loaded(c1541_loaded),

	.dsk_addr(dsk_addr),
	.dsk_data_in(dsk_data_in),
	.dsk_data_out(),
	.dsk_wr(dsk_wr),
	.led(drive_led),

	.rom_c1541(1'b0),
	.host_loadrom(host_loadrom)
);

// current D64 byte, re-read from SRAM through the D64 port
wire [18:0] d64_mem_addr;
wire        d64_mem_rd;
wire [7:0]  d64_mem_data;
wire        d64_mem_ack;

c64_d64_rd d64_rd(
	.clk(clk_sys),
	.reset(reset),
	.invalidate(loader_busy),
	.dsk_addr(dsk_addr),
	.dsk_data_in(dsk_data_in),
	.mem_addr(d64_mem_addr),
	.mem_rd(d64_mem_rd),
	.mem_data(d64_mem_data),
	.mem_ack(d64_mem_ack)
);

// synchronise the drive outputs into the C64 (as in the UnoXT core)
reg iec_data_d1 = 1'b1, iec_data_d2 = 1'b1;
reg iec_clk_d1 = 1'b1, iec_clk_d2 = 1'b1;
always @(posedge clk_sys) begin
	iec_data_d1 <= ~drive_iec_data_o;
	iec_clk_d1  <= ~drive_iec_clk_o;
	if (iec_data_d1 == iec_data_d2) c64_iec_data_i <= iec_data_d2;
	if (iec_clk_d1 == iec_clk_d2)   c64_iec_clk_i  <= iec_clk_d2;
	iec_data_d2 <= iec_data_d1;
	iec_clk_d2  <= iec_clk_d1;
end

// ------------------------------------------------------------------ SRAM and video

// ------------------------------------------------------------------ D64 image loader
wire        h_req;
wire [17:0] h_addr;
wire [7:0]  h_data;
wire        h_ack;

c64_d64_loader d64_loader(
	.clk(clk_host),
	.reset(reset_host),
	.img_mounted(img_mounted),
	.img_size(img_size0),
	.mount_pulse(img_mount_pulse[0]),
	.eject_pulse(img_eject_pulse[0]),
	.sdc_rd(d64_sdc_rd),
	.sdc_sector(d64_sdc_sector),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_slot(sdc_slot),
	.sdc_byte_strobe(sdc_byte_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_data(sdc_byte_data),
	.h_req(h_req),
	.h_addr(h_addr),
	.h_data(h_data),
	.h_ack(h_ack),
	.busy(loader_busy),
	.ready(d64_ready)
);

// PRG file loader (FL OSD item, slot 1), MiSTer/Tang flow.  The MCU stream is
// staged in free SRAM, then copied to C64 RAM after the KERNAL has booted.
// F-image byte stream shared by the PRG and CRT parsers
wire        img_file_reset, img_file_active;
wire [31:0] img_file_size, img_file_addr;
wire [7:0]  img_file_data, img_file_slot;
wire        img_file_wr;
wire        prg_eject, crt_eject;

// TAP image loader / C1530 player
wire        tap_wr_req, tap_wr_ack;
wire [18:0] tap_wr_addr;
wire [7:0]  tap_wr_data;
wire        tap_loaded;
wire [19:0] tap_size;
wire [1:0]  tap_version;
wire        tape_rd_req, tape_rd_ack;
wire [18:0] tape_rd_addr;
wire [15:0] tape_rd_data;
wire        cass_motor, cass_write, cass_read, cass_sense, cass_run;
wire        tape_end, tape_error;

wire        prg_p_req;
wire [15:0] prg_p_addr;
wire [7:0]  prg_p_data;
wire        prg_p_ack;
wire        prg_stg_req;
wire [15:0] prg_stg_addr;
wire [7:0]  prg_stg_data;
wire        prg_stg_ack;
wire        prg_rd_req;
wire [15:0] prg_rd_addr;
wire [7:0]  prg_rd_data;
wire        prg_rd_ack;

c64_img_file_loader img_file_loader(
	.clk(clk_host),
	.reset(reset_host),
	.mounted(img_mounted),
	.size4(img_size4),
	.size5(img_size5),
	.size6(img_size6),
	.mount_pulse(img_mount_pulse),
	.eject_pulse(img_eject_pulse),
	.c64_reset(reset),
	.boot_ready(prg_boot_ready),
	.sdc_rd(imgfile_sdc_rd),
	.sdc_sector(imgfile_sdc_sector),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_slot(sdc_slot),
	.sdc_byte_strobe(sdc_byte_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_data(sdc_byte_data),
	.file_reset(img_file_reset),
	.file_active(img_file_active),
	.file_size(img_file_size),
	.file_addr(img_file_addr),
	.file_data(img_file_data),
	.file_wr(img_file_wr),
	.file_slot(img_file_slot),
	.prg_eject(prg_eject),
	.crt_eject(crt_eject),
	.busy(),
	.error()
);

c64_crt_loader crt_loader(
	.clk(clk_host),
	.reset(reset_host),
	.file_reset(img_file_reset),
	.file_active(img_file_active),
	.file_wr(img_file_wr),
	.file_size(img_file_size),
	.file_addr(img_file_addr),
	.file_data(img_file_data),
	.file_slot(img_file_slot),
	.eject(crt_eject),
	.cart_loading(crt_cart_loading),
	.cart_id(crt_cart_id),
	.cart_exrom(crt_cart_exrom),
	.cart_game(crt_cart_game),
	.cart_bank_hi(crt_bank_hi),
	.cart_bank_16k(crt_bank_16k),
	.cart_bank_num(crt_bank_num),
	.cart_bank_addr(crt_bank_addr),
	.cart_bank_wr_tgl(crt_bank_wr_tgl),
	.cart_hold(crt_hold),
	.crt_req(crt_req),
	.crt_addr(crt_addr),
	.crt_data(crt_data),
	.crt_ack(crt_ack),
	.busy(crt_busy),
	.error()
);

c64_tap_loader tap_loader(
	.clk(clk_host),
	.reset(reset_host),
	.file_reset(img_file_reset),
	.file_active(img_file_active),
	.file_wr(img_file_wr),
	.file_size(img_file_size),
	.file_addr(img_file_addr),
	.file_data(img_file_data),
	.file_slot(img_file_slot),
	.eject(img_eject_pulse[6]),
	.tap_wr_req(tap_wr_req),
	.tap_wr_addr(tap_wr_addr),
	.tap_wr_data(tap_wr_data),
	.tap_wr_ack(tap_wr_ack),
	.tap_loaded(tap_loaded),
	.tap_size(tap_size),
	.tap_version(tap_version),
	.busy(tap_busy),
	.error(tape_error)
);

c64_tape tape(
	.clk(clk_sys),
	.reset(reset),
	.tap_loaded(tap_loaded),
	.tap_size(tap_size),
	.tap_version(tap_version),
	.loader_error(tape_error),
	.tap_rd_req(tape_rd_req),
	.tap_rd_addr(tape_rd_addr),
	.tap_rd_data(tape_rd_data),
	.tap_rd_ack(tape_rd_ack),
	.cass_motor(cass_motor),
	.cass_write(cass_write),
	.cass_read(cass_read),
	.cass_sense(cass_sense),
	.cass_run(cass_run),
	.tap_play_addr(),
	.tap_end(tape_end),
	.tap_error()
);

c64_prg_loader prg_loader(
	.clk(clk_host),
	.reset(prg_reset),
	.file_reset(file_reset),
	.file_active(file_active),
	.file_wr(file_wr),
	.file_size(file_size),
	.file_addr(file_addr),
	.file_data(file_data),
	.file_slot(file_slot),
	.boot_ready(prg_boot_ready),
	.eject(1'b0),
	.stg_req(prg_stg_req),
	.stg_addr(prg_stg_addr),
	.stg_data(prg_stg_data),
	.stg_ack(prg_stg_ack),
	.rd_req(prg_rd_req),
	.rd_addr(prg_rd_addr),
	.rd_data(prg_rd_data),
	.rd_ack(prg_rd_ack),
	.p_req(prg_p_req),
	.p_addr(prg_p_addr),
	.p_data(prg_p_data),
	.p_ack(prg_p_ack),
	.prg_hold(prg_hold),
	.run_req(prg_run),
	.busy(),
	.error()
);

c64_memory mem(
	.clk_sys(clk_sys),
	.clk_sram(clk_sram),
	.reset(reset),
	.c_addr(cart_addr),
	.c_ce(cart_ce),
	.c_we(cart_we),
	.c_din(cart_wrdata),
	.c_dout(c64_mem_dout),
	.d_addr(d64_mem_addr),
	.d_rd(d64_mem_rd),
	.d_wr(1'b0),
	.d_din(8'd0),
	.d_dout(d64_mem_data),
	.d_ack(d64_mem_ack),
	.h_req(h_req),
	.h_addr(h_addr),
	.h_data(h_data),
	.h_ack(h_ack),
	.p_req(prg_p_req),
	.p_addr(prg_p_addr),
	.p_data(prg_p_data),
	.p_ack(prg_p_ack),
	.c64_hold(prg_hold | crt_hold | tap_busy_s2),
	.crt_req(crt_req),
	.crt_addr(crt_addr),
	.crt_data(crt_data),
	.crt_ack(crt_ack),
	.tap_wr_req(tap_wr_req),
	.tap_wr_addr(tap_wr_addr),
	.tap_wr_data(tap_wr_data),
	.tap_wr_ack(tap_wr_ack),
	.stg_req(prg_stg_req),
	.stg_addr(prg_stg_addr),
	.stg_data(prg_stg_data),
	.stg_ack(prg_stg_ack),
	.rd_req(prg_rd_req),
	.rd_addr(prg_rd_addr),
	.rd_data(prg_rd_data),
	.rd_ack(prg_rd_ack),
	.vr_req(tape_rd_req),
	.vr_addr(tape_rd_addr),
	.vr_data(tape_rd_data),
	.vr_ack(tape_rd_ack),
	.MA(MA),
	.MD(MD),
	.MWR_N(MWR_N),
	.MRD_N(MRD_N)
);

// ------------------------------------------------------------------ diagnostics
wire d64_ready;

// The UnoXT 1541 detects a disk change on the falling edge of host_loadrom.
// The D64 image is written by the loader after power-up, so pulse this line
// once the loader is ready; the drive then re-reads the (complete) image.
reg [15:0] loadrom_hold = 16'd0;
reg        host_loadrom_r = 1'b0;
reg        loadrom_done = 1'b0;
always @(posedge clk_sys) begin
	if (reset) begin
		host_loadrom_r <= 1'b0;
		loadrom_hold   <= 16'd0;
		loadrom_done   <= 1'b0;
	end
	else begin
		if (!d64_ready)
			loadrom_done <= 1'b0;

		if (d64_ready && !loadrom_done && loadrom_hold == 16'd0) begin
			host_loadrom_r <= 1'b1;
			loadrom_hold   <= 16'd4096;
			loadrom_done   <= 1'b1;
		end
		else if (loadrom_hold != 16'd0) begin
			loadrom_hold <= loadrom_hold - 16'd1;
			if (loadrom_hold == 16'd1)
				host_loadrom_r <= 1'b0;
		end
	end
end
assign host_loadrom = host_loadrom_r;

// activity marker in the bottom border: disk 8 / tape T, green read / red write
reg disk_led_s1, disk_led_s2;
reg dsk_wr_s1, dsk_wr_s2;
reg tape_act_s1, tape_act_s2;
reg tape_wr_s1, tape_wr_s2;
always @(posedge clk_vid) begin
	disk_led_s1 <= drive_led;
	disk_led_s2 <= disk_led_s1;
	dsk_wr_s1   <= dsk_wr;
	dsk_wr_s2   <= dsk_wr_s1;
	// cass_run is the motor level: 0 = motor on (tape playing).  Also show T
	// while the TAP image itself is being loaded into SRAM.
	tape_act_s1 <= (~cass_run) | tap_busy_s2;
	tape_act_s2 <= tape_act_s1;
	tape_wr_s1  <= cass_write;
	tape_wr_s2  <= tape_wr_s1;
end
wire disk_act_vid = disk_led_s2;

c64_video video(
	.clk_sys(clk_sys),
	.clk_vid(clk_vid),
	.reset(reset_host),
	.disk_act(disk_act_vid),
	.disk_wr(dsk_wr_s2),
	.tape_act(tape_act_s2),
	.tape_wr(tape_wr_s2),
	.vic_r(vic_r),
	.vic_g(vic_g),
	.vic_b(vic_b),
	.vic_hsync(c64_hsync),
	.vic_vsync(c64_vsync),
	.vic_pixel_ce(c64_pixel_ce),
	.pause(c64_pause),
	.rgb(rgb),
	.hs(hs),
	.vs(vs),
	.de(de)
);

endmodule
`default_nettype wire
