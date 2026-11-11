# C64 core on Karabas Mini G: audit request (for Kimi)

> **Обновление 2026-11-09:** проблема решена. Причина — старый видео-тракт
> с полным кадровым буфером в SRAM и свободно бегущим выходом; машина и VIC
> были исправны. Новый `src/rtl/c64video.v` (4 строки BRAM, genlock по кадру)
> грузит BASIC на обоих ядрах. Документ оставлен как история отладки;
> актуальное состояние — в `SESSION_FINDINGS_C64.md`.

## 1. What we are doing

Porting the MiSTer C64 core to the Karabas Mini G: Xilinx Spartan-6 XC6SLX25-2 FTG256,
HDMI (720x576@50), I2S DAC, 32 MB SDRAM, 4 MB SRAM (IS61WV20488, 2M x 16, 10 ns),
RP2040 firmware link (kg_mcu), OSD.

The machine is the MiSTer `fpga64_sid_iec` (T65 6510, VIC-II 656x, 2x CIA 6526, SID).
The 1541 drive is the UnoXT `c1541_sd` (D64).  ROMs are the original UnoXT
`rom_c64_basic.vhd`, `rom_c64_kernal.vhd`, `rom_c64_chargen.vhd`.

## 2. Current symptom and what was already tested

Symptom: the C64 shows a **uniform blue field** (the VIC border colour); BASIC does not
appear.  The Karabas OSD, HDMI, PLL and frame buffer work (OSD opens with Menu+Esc).

Tests already done:

1. ROMs: first MiSTer `std_C64.mif`/`chargen.mif` converted to VHDL; then switched to the
   original UnoXT ROMs.  Reset/IRQ/NMI vectors are the standard ones:
   `$FFFA=$FE43`, `$FFFC=$FCE2`, `$FFFE=$FF48`.  No change.
2. IRQ/NMI: tied the CPU `irq_n` and `nmi_n` inputs to '1' (interrupts disabled).  No change.
3. Reset: tied the C64 reset to `~pll_locked` only (removed the OSD reset item and the
   board button).  No change.
4. Debug: replaced the VIC picture with the CPU address (`dbg_cpu_addr`, latched at VIC
   VSYNC).  With the normal KERNAL the latched address was **$FFE0** every frame (solid
   yellow debug screen).  $FFE0 is inside the KERNAL indirect-vector table, not a normal
   reset/init address; it looks like a bad jump through a RAM vector.
5. **Important test:** patched the KERNAL reset vector to `$FF00` and put this tiny program at
   `$FF00` (no RAM use):

```asm
FF00: A9 05        LDA #$05
FF02: 8D 20 D0     STA $D020      ; border = green
FF05: A9 00        LDA #$00
FF07: 8D 21 D0     STA $D021      ; background = black
FF0A: A9 1B        LDA #$1B
FF0C: 8D 11 D0     STA $D011      ; DEN = 1
FF0F: 4C 10 FF     JMP $FF10      ; (program bug: should loop at $FF0F/$FF14)
```

Result: the border **turned green**.  So the CPU executes from ROM, the reset-vector read
works, and writes to the VIC registers work.  The tiny program did **not** use RAM (zero
page, stack, screen RAM).  The normal KERNAL does, and it does not initialise the screen.
This points at the **C64 RAM / SRAM path** (or at something the KERNAL needs early, e.g.
stack at $0100/$01FF or zero page).

We have not yet run a RAM read/write test from the tiny program; that is the next step.

## 3. Clocking and memory map

* `clk_sys`  = 31.25 MHz (PLL VCO 1000 MHz / 32) — C64 machine, SRAM phase 0.
* `clk_sram` = 62.5 MHz (VCO / 16) — SRAM controller, phase 0/1.
* `clk_vid`  = 27.027 MHz (VCO / 37) — HDMI pixel clock and frame buffer readout.
* `clk_host` = 25 MHz (VCO / 40) — kg_mcu.

SRAM word map (one byte per 16-bit word for the C64 bus; the video uses full 16-bit words):

| byte address | word address | use |
|---|---|---|
| 0x000000-0x00FFFF | 0x000000-0x00FFFF | C64 64 KB RAM |
| 0x010000-0x01FFFF | 0x010000-0x01FFFF | cartridge RAM |
| 0x200000-0x2FFFFF | 0x020000-0x11FFFF | cartridge ROM (1 MB, `cartridge.v` layout) |
| d_addr | 0x120000 + d_addr[17:0] | D64 image |
| video frame | 0x160000 / 0x1A0000 | two 256K-word frame buffers |

The C64/cartridge port is served in `clk_sram` phase 0; the auxiliary port (D64, video
write/read) in phase 1.

## 4. Code

### 4.1 `src/rtl/c64_memory.v` (full)

```verilog
// SRAM controller of the C64 core (Karabas Mini G, IS61WV20488, 2M x 16, 10 ns).
//
// The C64/cartridge memory is accessed on clk_sys (31.25 MHz), one byte per 16-bit word (the low
// byte is used).  The SRAM itself runs at clk_sram = 2 * clk_sys (62.5 MHz): phase 0 serves the
// C64 bus, phase 1 serves the D64 image and the video frame buffer.
//
//   byte address                word address
//   0x000000-0x00FFFF  C64 RAM   0x000000-0x00FFFF
//   0x010000-0x01FFFF  cart RAM  0x010000-0x01FFFF
//   0x200000-0x2FFFFF  cart ROM  0x020000-0x11FFFF (1 MB, the layout of cartridge.v)
//   d_addr             D64       0x120000 + d_addr (256 KB)
//   video frame                 0x160000 / 0x1A0000 (256 KB each)
//
// An auxiliary read returns its data on the clk_sys edge after the request; the video read engine
// and the 1541 tolerate that one-cycle latency.
`timescale 1ns / 1ps
`default_nettype none

module c64_memory (
	input wire clk_sys,
	input wire clk_sram,
	input wire reset,

	// C64 / cartridge bus (clk_sys)
	input wire [24:0] c_addr,
	input wire        c_ce,
	input wire        c_we,
	input wire [7:0]  c_din,
	output reg [7:0]  c_dout,

	// D64 image (clk_sys)
	input wire [18:0] d_addr,
	input wire        d_rd,
	input wire        d_wr,
	input wire [7:0]  d_din,
	output reg [7:0]  d_dout,

	// video frame write (clk_sys)
	input wire        vw_wr,
	input wire [18:0] vw_addr,
	input wire [15:0] vw_data,

	// video frame read (clk_sys): a request is taken when vr_req is high; vr_data is valid on the
	// following clk_sys edge
	input wire        vr_req,
	input wire [18:0] vr_addr,
	output reg [15:0] vr_data,

	// SRAM pins
	output reg [20:0] MA = 21'd0,
	inout wire [15:0] MD,
	output reg [1:0]  MWR_N = 2'b11,
	output reg [1:0]  MRD_N = 2'b11
);

function [20:0] c_map;
	input [24:0] a;
	begin
		if (a[24:16] == 9'd0)
			c_map = {5'd0, a[15:0]};
		else if (a[24:16] == 9'd1)
			c_map = {5'd0, 1'b1, a[15:0]};
		else if (a[24:20] == 5'b0010_0 || a[24:20] == 5'b0010_1)
			c_map = {3'd0, 2'b01, a[19:0]}; // 0x020000 + 1 MB
		else
			c_map = 21'h1FFFFF;
	end
endfunction

reg phase = 1'b0; // 0: C64 bus, 1: auxiliary port

reg [7:0]  c_din_reg = 8'd0;
reg        sram_do = 1'b0;
reg [15:0] sram_wdata = 16'd0;

assign MD = sram_do ? sram_wdata : 16'hzzzz;

// auxiliary request seen at phase 1 and sampled at the next phase 0
reg        aux_rd = 1'b0;
reg        aux_vid = 1'b0; // 1: video, 0: D64
reg        c_read_q = 1'b0;

always @(posedge clk_sram) begin
	phase <= ~phase;

	if (reset) begin
		phase <= 1'b0;
		MA <= 21'd0;
		MWR_N <= 2'b11;
		MRD_N <= 2'b11;
		c_dout <= 8'd0;
		d_dout <= 8'd0;
		vr_data <= 16'd0;
		sram_do <= 1'b0;
		aux_rd <= 1'b0;
		aux_vid <= 1'b0;
		c_read_q <= 1'b0;
	end
	else if (phase == 1'b0) begin
		// ---- a new clk_sys cycle: the auxiliary read of the previous cycle is ready ----
		if (aux_rd) begin
			if (aux_vid)
				vr_data <= MD;
			else
				d_dout <= MD[7:0];
		end
		aux_rd <= 1'b0;

		// ---- C64 request ----
		c_din_reg <= c_din;
		c_read_q <= c_ce && !c_we;
		MA <= c_map(c_addr);
		if (c_ce && c_we) begin
			sram_do <= 1'b1;
			sram_wdata <= {8'h00, c_din};
			MWR_N <= 2'b10;
			MRD_N <= 2'b11;
		end
		else if (c_ce) begin
			sram_do <= 1'b0;
			MWR_N <= 2'b11;
			MRD_N <= 2'b00;
		end
		else begin
			sram_do <= 1'b0;
			MWR_N <= 2'b11;
			MRD_N <= 2'b11;
		end
	end
	else begin
		// ---- C64 read data is valid now ----
		if (c_read_q)
			c_dout <= MD[7:0];

		// ---- auxiliary port ----
		if (vw_wr) begin
			MA <= 21'h160000 + {2'b00, vw_addr};
			sram_do <= 1'b1;
			sram_wdata <= vw_data;
			MWR_N <= 2'b00;
			MRD_N <= 2'b11;
			aux_rd <= 1'b0;
		end
		else if (vr_req) begin
			MA <= 21'h160000 + {2'b00, vr_addr};
			sram_do <= 1'b0;
			MWR_N <= 2'b11;
			MRD_N <= 2'b00;
			aux_rd <= 1'b1;
			aux_vid <= 1'b1;
		end
		else if (d_rd || d_wr) begin
			MA <= 21'h120000 + {3'b000, d_addr[17:0]};
			if (d_wr) begin
				sram_do <= 1'b1;
				sram_wdata <= {8'h00, d_din};
				MWR_N <= 2'b10;
				MRD_N <= 2'b11;
				aux_rd <= 1'b0;
			end
			else begin
				sram_do <= 1'b0;
				MWR_N <= 2'b11;
				MRD_N <= 2'b00;
				aux_rd <= 1'b1;
				aux_vid <= 1'b0;
			end
		end
		else begin
			sram_do <= 1'b0;
			MWR_N <= 2'b11;
			MRD_N <= 2'b11;
			aux_rd <= 1'b0;
		end
	end
end

endmodule
`default_nettype wire

```

### 4.2 `src/rtl/c64_machine.v` (full)

```verilog
// The Commodore 64 machine of the Karabas Mini G: the MiSTer fpga64_sid_iec (6510, VIC-II, CIAs,
// SID), the cartridge logic, the SRAM controller, the video output and the 1541 drive.
`timescale 1ns / 1ps
`default_nettype none

module c64_machine (
	input wire clk_sys,
	input wire clk_sram,
	input wire clk_vid,
	input wire reset,

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
	output wire drive_led,

	// debug
	output wire [15:0] dbg_addr,
	output wire dbg_ce,
	output wire dbg_reset
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
wire [15:0] c64_cpu_addr;
wire c64_cpu_hasbus;
wire [7:0] vic_r, vic_g, vic_b;
wire [17:0] sid_audio_l, sid_audio_r;
wire c64_pause;

wire c64_iec_data_o, c64_iec_clk_o, c64_iec_atn_o;
reg c64_iec_data_i, c64_iec_clk_i;
wire drive_iec_data_o, drive_iec_clk_o;

wire nmi, cart_oe, io_rom, cart_mem_req;
wire [7:0] cart_data;
wire romL, romH, UMAXromH, IOE, IOF;
wire freeze_key, mod_key, nmi_ack;

wire [24:0] cart_addr;
wire cart_ce, cart_we;
wire [7:0] cart_wrdata;

fpga64_sid_iec c64(
	.clk32       (clk_sys),
	.reset_n     (~reset),
	.bios        (2'b00),
	.pause       (1'b0),
	.pause_out   (c64_pause),

	.ps2_key     (ps2_key),
	.kbd_reset   (1'b0),
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
	.dbg_cpu_addr(c64_cpu_addr),
	.dbg_cpu_hasbus(c64_cpu_hasbus),
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

	.c64rom_addr (14'd0),
	.c64rom_data (8'd0),
	.c64rom_wr   (1'b0),

	.cass_motor  (),
	.cass_write  (),
	.cass_sense  (1'b1),
	.cass_read   (1'b1)
);

assign audio_l = sid_audio_l;
assign audio_r = sid_audio_r;

// ------------------------------------------------------------------ cartridge
cartridge cart(
	.clk32(clk_sys),
	.reset_n(~reset),

	.cart_loading(1'b0),
	.cart_id(8'd255),
	.cart_exrom(1'b1),
	.cart_game(1'b1),
	.cart_bank_hi(1'b0),
	.cart_bank_16k(1'b0),
	.cart_bank_num(8'd0),
	.cart_bank_addr(8'd0),
	.cart_bank_wr(1'b0),
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
wire [7:0] dsk_data_in, dsk_data_out;
wire dsk_wr;
wire host_loadrom = 1'b0;

c1541_sd drive(
	.clk32(clk_sys),
	.clk32n(clk_sys),
	.clk_c1541(clk_sys),
	.disk_num(10'd0),

	.iec_atn_i(c64_iec_atn_o),
	.iec_data_i(c64_iec_data_o),
	.iec_clk_i(c64_iec_clk_o),
	.iec_data_o(drive_iec_data_o),
	.iec_clk_o(drive_iec_clk_o),
	.iec_reset_i(reset),

	.dsk_addr(dsk_addr),
	.dsk_data_in(dsk_data_in),
	.dsk_data_out(dsk_data_out),
	.dsk_wr(dsk_wr),

	.rom_c1541(1'b0),
	.host_loadrom(host_loadrom)
);
assign drive_led = 1'b0;

// synchronise the drive outputs into the C64 (as in the UnoXT core)
reg iec_data_d1 = 1'b1, iec_data_d2 = 1'b1;
reg iec_clk_d1 = 1'b1, iec_clk_d2 = 1'b1;
always @(posedge clk_sys) begin
	iec_data_d1 <= drive_iec_data_o;
	iec_clk_d1  <= drive_iec_clk_o;
	if (iec_data_d1 == iec_data_d2) c64_iec_data_i <= iec_data_d2;
	if (iec_clk_d1 == iec_clk_d2)   c64_iec_clk_i  <= iec_clk_d2;
	iec_data_d2 <= iec_data_d1;
	iec_clk_d2  <= iec_clk_d1;
end

// ------------------------------------------------------------------ SRAM and video
wire [7:0] d64_din, d64_dout;
wire d64_rd;

reg [18:0] d_addr_q = 19'd0;
always @(posedge clk_sys) d_addr_q <= dsk_addr;
assign d64_rd = (dsk_addr != d_addr_q);

wire vw_wr;
wire [18:0] vw_addr;
wire [15:0] vw_data;
wire vr_req;
wire [18:0] vr_addr;
wire [15:0] vr_data;

c64_memory mem(
	.clk_sys(clk_sys),
	.clk_sram(clk_sram),
	.reset(reset),
	.c_addr(cart_addr),
	.c_ce(cart_ce),
	.c_we(cart_we),
	.c_din(cart_wrdata),
	.c_dout(c64_mem_dout),
	.d_addr(dsk_addr),
	.d_rd(d64_rd),
	.d_wr(dsk_wr),
	.d_din(dsk_data_out),
	.d_dout(d64_dout),
	.vw_wr(vw_wr),
	.vw_addr(vw_addr),
	.vw_data(vw_data),
	.vr_req(vr_req),
	.vr_addr(vr_addr),
	.vr_data(vr_data),
	.MA(MA),
	.MD(MD),
	.MWR_N(MWR_N),
	.MRD_N(MRD_N)
);
assign dsk_data_in = d64_dout;

assign dbg_addr = c64_cpu_addr;
assign dbg_ce = c64_cpu_hasbus;
assign dbg_reset = reset;

c64_video video(
	.clk_sys(clk_sys),
	.clk_vid(clk_vid),
	.reset(reset),
	.vic_r(vic_r),
	.vic_g(vic_g),
	.vic_b(vic_b),
	.vic_hsync(c64_hsync),
	.vic_vsync(c64_vsync),
	.vic_pixel_ce(c64_pixel_ce),
	.pause(c64_pause),
	.dbg_mode(1'b0),
	.dbg_addr(c64_cpu_addr),
	.dbg_ce(c64_cpu_hasbus),
	.dbg_reset(reset),
	.dbg_vsync(c64_vsync),
	.vw_wr(vw_wr),
	.vw_addr(vw_addr),
	.vw_data(vw_data),
	.vr_req(vr_req),
	.vr_addr(vr_addr),
	.vr_data(vr_data),
	.rgb(rgb),
	.hs(hs),
	.vs(vs),
	.de(de)
);

endmodule
`default_nettype wire

```

### 4.3 `src/rtl/c64/fpga64_sid_iec.vhd`: CPU, IRQ/NMI and reset/enable

```vhdl
		else
			sum := sum + 100;
			if sum >= 31527954 then
				sum := sum - 31527954;
				todclk <= not todclk;
			end if;
		end if;
	end if;
end process;

-- -----------------------------------------------------------------------
-- 6510 CPU / DMA
-- -----------------------------------------------------------------------
cpu: entity work.cpu_6510
port map (
	clk => clk32,
	reset => reset,
	enable => enableCpu and not dma_active,
	nmi_n => '1', -- DEBUG: interrupts disabled
	nmi_ack => nmi_ack,
	irq_n => '1', -- DEBUG: interrupts disabled
	rdy => baLoc,

	di => cpuDi,
	addr => cpuAddr_pre,
	do => cpuDo_pre,
```

```vhdl
		preCycle <= sysCycleDef'succ(preCycle);
		if preCycle = sysCycleDef'high then
			preCycle <= sysCycleDef'low;
			if sysEnable = '1' then
				rfsh_cycle <= rfsh_cycle + 1;
			end if;
		end if;
		
		refresh <= '0';
		if preCycle = sysCycleDef'pred(CYCLE_EXT4) and rfsh_cycle = "00" then
			sysEnable <= not pause;
			refresh <= '1';
		end if;
	end if;
end process;

process(clk32)
begin
	if rising_edge(clk32) then
		if preCycle = sysCycleDef'high then
			reset <= not reset_n;
		end if;
	end if;
end process;

-- PHI0/2-clock emulation
process(clk32)
begin
	if rising_edge(clk32) then
		if sysCycle = sysCycleDef'pred(CYCLE_CPU0) then
			phi0_cpu <= '1';
			if baLoc = '1' or (cpuWe = '1' and dma_active = '0') or (ba_dma = '1' and dma_active = '1') then
				cpuHasBus <= '1';
			end if;
		end if;
		if sysCycle = sysCycleDef'high then
			phi0_cpu <= '0';
			cpuHasBus <= '0';
		end if;
	end if;
end process;

process(clk32)
```

### 4.4 `src/rtl/c64/fpga64_buslogic.vhd`: ROM/ROM select and PLA/RAM decode

```vhdl
	signal cs_UMAXromHLoc : std_logic;
	signal cs_UMAXnomapLoc: std_logic;
	signal ultimax        : std_logic;

	signal currentAddr    : unsigned(15 downto 0);
	
begin
	basic_rom: entity work.rom_c64_basic
	port map
	(
		clk  => clk,
		addr => cpuAddr(12 downto 0),
		do   => basic_do
	);

	kernal_rom: entity work.rom_c64_kernal
	port map
	(
		clk  => clk,
		addr => cpuAddr(12 downto 0),
		do   => kernal_do
	);

	chargen_rom: entity work.rom_c64_chargen
	port map
	(
		clk  => clk,
		addr => currentAddr(11 downto 0),
		do   => char_do
	);

	romData <= std_logic_vector(kernal_do) when cpuAddr(14) = '1' else std_logic_vector(basic_do);
	charData <= std_logic_vector(char_do);

	process(clk)
	begin
		if rising_edge(clk) then
			if reset = '1' then 
```

```vhdl
						when X"E" =>
							cs_ioELoc <= '1';
						when X"F" =>
							cs_ioFLoc <= '1';
						when others =>
							null;
					end case;
				else
					-- I/O space turned off. Read from charrom or write to RAM.
					if cpuWe = '0' then
						  cs_CharLoc <= '1';
					else
						  cs_ramLoc <= '1';
					end if;
				end if;
			when X"A" | X"B" =>
				if ultimax = '1' then
					cs_UMAXnomapLoc <= '1';
				elsif exrom = '0' and game = '0' and bankSwitch(1) = '1' then
				  -- this case should write to both C64 RAM and Cart RAM (if RAM is connected)
					cs_romHLoc <= '1';
				elsif ultimax = '0' and cpuWe = '0' and bankSwitch(1) = '1' and bankSwitch(0) = '1' then
					-- Access basic rom
					-- May need turning off if kernal banked out LCA
					cs_romLoc <= '1';
				else
					cs_ramLoc <= '1';
				end if;
			when X"8" | X"9" =>
				if ultimax = '1' then
					-- pass cpuWe to cartridge. Cartridge must block writes if no RAM connected.
					cs_romLLoc <= '1';
				elsif exrom = '0' and bankSwitch(1) = '1' and bankSwitch(0) = '1' then
				  -- this case should write to both C64 RAM and Cart RAM (if RAM is connected)
					cs_romLLoc <= '1';
				else
					cs_ramLoc <= '1';
				end if;
			when X"0" =>
				cs_ramLoc <= '1';
			when others =>
				-- If not in Ultimax mode access ram
				if ultimax = '0' then
					cs_ramLoc <= '1';
				else
					cs_UMAXnomapLoc <= '1';
				end if;
			end case;

			systemWe <= cpuWe;
		else
			-- The VIC-II has the bus, but only when aec is asserted
			if aec = '1' then
				currentAddr <= vicAddr;
			else
				currentAddr <= cpuAddr;
			end if;

			if ultimax = '0' and vicAddr(14 downto 12)="001" then
				vicCharLoc <= '1';
			elsif ultimax = '1' and vicAddr(13 downto 12)="11" then
				-- ultimax mode changes vic addressing - LCA 
				cs_UMAXromHLoc <= '1';
			else
				cs_ramLoc <= '1';
			end if;
		end if;
	end process;

	cs_ram <= cs_ramLoc or cs_romLLoc or cs_romHLoc or cs_UMAXromHLoc or cs_UMAXnomapLoc or cs_CharLoc or cs_romLoc;
	cs_vic <= cs_vicLoc and io_enable;
	cs_sid <= cs_sidLoc and io_enable;
	cs_color <= cs_colorLoc and io_enable;
	cs_cia1 <= cs_cia1Loc and io_enable;
	cs_cia2 <= cs_cia2Loc and io_enable;
	cs_ioE <= cs_ioELoc and io_enable;
	cs_ioF <= cs_ioFLoc and io_enable;
	cs_romL <= cs_romLLoc;
	cs_romH <= cs_romHLoc;
	cs_UMAXromH <= cs_UMAXromHLoc;

	dataToVic  <= unsigned(charData) when vicCharLoc = '1' else ramData;
	systemAddr <= currentAddr;
end architecture;
```

### 4.5 `src/rtl/c64/cpu_6510.vhd`: port reset value and CPU

```vhdl
architecture rtl of cpu_6510 is
	signal localA : std_logic_vector(23 downto 0);
	signal localDi : std_logic_vector(7 downto 0);
	signal localDo : std_logic_vector(7 downto 0);
	signal localWe : std_logic;

	signal currentIO : std_logic_vector(7 downto 0);
	signal ioDir : std_logic_vector(7 downto 0);
	signal ioData : std_logic_vector(7 downto 0);
	
	signal accessIO : std_logic;
begin

	cpu: entity work.T65
	port map(
		Mode    => "00",
		Res_n   => not reset,
		Enable  => enable,
		Clk     => clk,
		Rdy     => rdy,
		Abort_n => '1',
		IRQ_n   => irq_n,
		NMI_n   => nmi_n,
		SO_n    => '1',
		R_W_n   => localWe,
		A       => localA,
		DI      => localDi,
		DO      => localDo,
		NMI_ack => nmi_ack
	);

	accessIO <= '1' when localA(15 downto 1) = X"000"&"000" else '0';
	localDi  <= localDo when localWe = '0' else std_logic_vector(di) when accessIO = '0' else ioDir when localA(0) = '0' else currentIO;

	process(clk)
	begin
		if rising_edge(clk) then
			if accessIO = '1' then
				if localWe = '0' and enable = '1' then
					if localA(0) = '0' then
						ioDir <= localDo;
					else
						ioData <= localDo;
					end if;
				end if;
			end if;

			currentIO <= (ioData and ioDir) or (std_logic_vector(diIO) and not ioDir);

			if reset = '1' then
				ioDir <= (others => '0');
				ioData <= (others => '1');
				currentIO <= "00111111";  -- upper two bits are unused; ensure that the KERNAL is able to set Zero Page address $01 to $37 by default
			end if;
		end if;
	end process;

	-- Cunnect zee wires
	addr <= unsigned(localA(15 downto 0));
	do <= unsigned(localDo);
	we <= not localWe;
	doIO <= unsigned(currentIO);
end architecture;
```

### 4.6 `src/rtl/karabas_minig_top.v`: PLL and C64 reset

```verilog
// 25 MHz MCU.  CLKOUT1 is raw (the BUFGMUX of kg_hdmi_ft takes it).
wire [5:0] pll_clk;
wire locked;
kg_pll #(
	.DIVCLK_DIVIDE(1),
	.CLKFBOUT_MULT(20),
	.CLKOUT0_DIVIDE(32),
	.CLKOUT1_DIVIDE(37),
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
wire [7:0] hid_kb_status, hid_kb_dat0, hid_kb_dat1, hid_kb_dat2, hid_kb_dat3, hid_kb_dat4, hid_kb_dat5;
wire [7:0] ms_x, ms_y;
wire [2:0] ms_b;
wire ms_upd;
wire [15:0] softsw_command, osd_command;
```

```verilog
wire [23:0] vid_rgb, osd_rgb;
wire vid_hs, vid_vs, vid_de;
wire signed [17:0] c64_audio_l, c64_audio_r;
wire c64_reset = ~locked;

c64_machine machine(
	.clk_sys		(clk_sys),
	.clk_sram	(clk_sram),
	.clk_vid		(clk_vid),
	.reset		(c64_reset),
	.kb_scancode	(kb_scancode),
	.kb_scancode_upd(kb_scancode_upd),
	.joy_l		(joy_l),
	.joy_r		(joy_r),
	.sw_joy_swap(softsw[8]),
	.MA			(MA),
	.MD			(MD),
	.MWR_N		(MWR_N),
	.MRD_N		(MRD_N),
	.rgb			(vid_rgb),
	.hs			(vid_hs),
```

### 4.7 `src/rtl/c64_video.v`: capture and debug latch

```verilog
	output reg [23:0] rgb = 24'd0,
	output reg        hs = 1'b0,
	output reg        vs = 1'b0,
	output reg        de = 1'b0
);

// ------------------------------------------------------------------ capture
wire hsync_c, vsync_c, hblank_c, vblank_c;
video_sync vic_sync(
	.clk32   (clk_sys),
	.pause   (pause),
	.hsync   (vic_hsync),
	.vsync   (vic_vsync),
	.ntsc    (1'b0),
	.wide    (1'b0),
	.hsync_out (hsync_c),
	.vsync_out (vsync_c),
	.hblank  (hblank_c),
	.vblank  (vblank_c)
);

reg prev_hs = 1'b0, prev_vs = 1'b0;
reg [9:0] cap_x = 10'd0;
reg [8:0] cap_y = 9'd0;
reg [15:0] pix565;
reg [15:0] dbg_lat = 16'd0;
reg dbg_vs_d = 1'b0;

always @(posedge clk_sys) begin
	pix565 <= dbg_mode ? {dbg_lat[15:11], dbg_lat[10:5], dbg_lat[4:0]} : {vic_r[7:3], vic_g[7:2], vic_b[7:3]};
	vw_wr <= 1'b0;
	if (reset) begin
		cap_x <= 10'd0;
		cap_y <= 9'd0;
		prev_hs <= 1'b0;
		prev_vs <= 1'b0;
		dbg_vs_d <= 1'b0;
		dbg_lat <= 16'd0;
	end
	else begin
		dbg_vs_d <= dbg_vsync;
		if (dbg_vsync && !dbg_vs_d) dbg_lat <= dbg_addr;
		prev_hs <= hsync_c;
		prev_vs <= vsync_c;
		if (hsync_c && !prev_hs) begin
			cap_x <= 10'd0;
			if (vsync_c && !prev_vs)
				cap_y <= 9'd0;
			else if (cap_y != 9'd311)
				cap_y <= cap_y + 9'd1;
		end
		else if (vic_pixel_ce && cap_x != 10'd504 && cap_y != 9'd312) begin
			vw_wr <= 1'b1;
			vw_addr <= {cap_y, cap_x[8:0]};
			vw_data <= pix565;
			cap_x <= cap_x + 10'd1;
		end
	end
end

// ------------------------------------------------------------------ line fill engine (clk_sys)
```

## 5. Differences from the UnoXT core (same FPGA family)

* UnoXT uses the older `fpga64_sid_iec.vhd` (generic `resetCycles=4095`, `ramDataIn/Out`,
  `irq_n`/`nmi_n` inout, 8-bit `ps2_key`, `idle`, `dma_n`, `CPU_hasbus`) and the older
  `video_vicII_656x.vhd` / `mos6526.v` / `cpu_6510.vhd`.  We use the MiSTer versions
  (DMA, turbo, `pixel_ce`, `sid_*` ports, newer VIC).
* CPU and IRQ/NMI wiring is essentially the same:
  UnoXT: `irqLoc <= irq_cia1 and irq_vic and irq_n; nmiLoc <= irq_cia2 and nmi_n;`
  MiSTer: `irq_n => irq_cia1 and irq_vic and irq_n and irq_ext_n; nmi_n => irq_cia2 and nmi_n;`
* **Main difference:** UnoXT keeps the 64 KB C64 RAM in **BRAM** (`gen_ram`, one-cycle read).
  We keep it in external **SRAM** through `c64_memory.v` and `cartridge.v`.
  The KERNAL crashes before initialising the VIC; the tiny ROM program (no RAM) works.
  This is why the SRAM path is the prime suspect.
* UnoXT's `resetCycles=4095` holds reset much longer than MiSTer's one system cycle.
  We tried a long reset externally (reset tied to PLL lock) but not 4095 cycles after lock;
  the MiSTer internal reset releases after about one 32-cycle system cycle.

## 6. Questions for the audit

1. Is the timing of `c64_memory.v` compatible with `fpga64_sid_iec`/`cartridge.v`?
   `ramCE`/`ramAddr` are asserted for one `clk_sys` cycle; we latch the address at
   `clk_sram` phase 0 and return `c_dout` at phase 1 (one `clk_sys` later).  Is that the
   cycle at which the CPU/VIC samples `ramDin`?  Could the data be one cycle too early/late?
2. `cartridge.v` `mem_ce_out`/`mem_write_out`/`mem_addr` are combinational.  Does the
   C64 RAM read need a **registered** or a **combinational** data path?
3. Does `cartridge.v` expect the external memory to hold data until the next `mem_ce`, or
   can it change every `clk_sys`?
4. Is our `clk_sram` phase locked to `clk_sys`?  Both PLL outputs are 0 degrees, /16 and
   /32.  Could the first `phase=0` occur at the wrong `clk_sys` edge after reset?
5. Is the SRAM write pulse (phase 0 -> phase 1, 16 ns) and read latency (address at phase 0,
   sample MD at phase 1) correct for IS61WV20488 (tAA 10 ns)?  Should the read be sampled
   at phase 0 of the next `clk_sys` instead?
6. Could the KERNAL crash because the SRAM powers up with random data and the KERNAL's
   early stack/zero-page writes do not land?  Which RAM addresses are used first, and
   what would we see if only writes or only reads were broken?
7. Is the `cartridge.v` `mem_write_out` polarity (active high) and `mem_ce_out` connected
   correctly?  Is `mem_in` (data to CPU) taken at the right time?
8. Does the VIC fetch screen/character data through the same `ramAddr`/`ramDin` path?  If
   the VIC read timing is wrong, could the KERNAL run but the screen stay blank/blue?
9. Does the MiSTer `fpga64_sid_iec` require the older UnoXT `resetCycles` behaviour, or a
   longer `reset_n` after PLL lock, for the CIA/VIC/6510 port to settle?
10. Are there known differences between the MiSTer `fpga64_buslogic.vhd` and the UnoXT
    `fpga64_buslogic_roms_mmu.vhd` that matter when the RAM is external and slower/faster
    than the MiSTer SDRAM?
11. In `c64_machine.v`, is the `cartridge.v` connection correct for a machine with **no
    cartridge** (`cart_id=255`, `cart_exrom=1`, `cart_game=1`)?  Could `cartridge.v` still
    route C64 RAM accesses to the wrong place?
12. What is the best minimal test program to distinguish “CPU/ROM/VIC works” from “RAM
    works”: write/read $0400, $0100, $0000, and set the border to green/red?

## 7. What we will test next

Patch the tiny ROM program to write/read $0400, $0100 and $0000 and set the border to
green on success and red on failure.  If RAM fails, fix `c64_memory.v`; if RAM passes,
move to the VIC screen fetch and the KERNAL IRQ/vector path.

---

## 8. Session update 2026-11-08 (after the first audit request)

Additional results:

1. **SRAM RAM test passes.** A tiny program at `$FF00` (reset vector patched) does
   `STA $0400` / `LDA $0400` / `CMP #$AA`; the border turns green on success.
   The SRAM controller was changed to a full `clk_sys` access: address in phase 0,
   hold through phase 1, sample `MD` at the next phase 0 (~32 ns > 21 ns).
2. **VIC write and read-back work.** `$D020` changes the border; `$D011=$1B` is read
   back and compared, green on match.
3. **VIC raster test was inconclusive.** `LDA $D012; STA $D020` produced a green
   field with one blue band, not 16 distinct bands. The old UnoXT VIC is now used
   in a separate test build.
4. **UnoXT machine control build:** the UnoXT `fpga64_sid_iec` (older VIC/CIA/CPU,
   `resetCycles=4095`) with **64 KB C64 RAM in BRAM `gen_ram`** (exactly like
   `c64_zxt.vhd`) and our SRAM only for the frame buffer. It fits (47% LUT, 44/52
   RAMB16, timing 0) but still shows a black screen. The OSD works (`Menu+Esc`).
5. **Suspicion:** either the UnoXT machine does not start, or our `c64_video`
   cannot capture the old UnoXT VIC (`hSync/vSync` are `hBlanking/vBlanking`;
   `video_sync`/`pixel_ce` polarity/timing may differ from the MiSTer VIC).
6. The debug `dbg_vic="1111"` test was unreliable: `dbg_vic` may not reach
   `c64_video` (port/connection/optimization) or the debug branch was not active.
7. The main MiSTer sources were restored to a clean baseline (original KERNAL,
   `dbg_mode=0`, real `dbg_vic`, IRQ/NMI normal); test builds are in
   `doc/artifacts/`.

Next:
* build the normal UnoXT `c64u.kg` with the original KERNAL and 64 KB BRAM;
* test the video path with a free-running pattern independent of the VIC;
* check the old UnoXT VIC hsync/vsync/pixel_ce against `c64_video`;
* only then return to KERNAL/VIC DEN/rasterEnable.
