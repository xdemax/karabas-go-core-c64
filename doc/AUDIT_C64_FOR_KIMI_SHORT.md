# C64 on Karabas Mini G — short audit request

> **Обновление 2026-11-09:** проблема решена; см. `SESSION_FINDINGS_C64.md`.
> Старый SRAM-видеотракт заменён на `src/rtl/c64video.v` (4 строки BRAM,
> genlock по кадру VIC). Документ оставлен как история.

## Symptom
Uniform blue field (VIC border colour), BASIC does not appear.  HDMI/OSD/PLL/framebuffer work.
Board: XC6SLX25-2 FTG256, 4 MB SRAM IS61WV20488 (2M x 16, 10 ns), 32 MB SDRAM.

## What is already proven
* A tiny test program placed at $FF00 and the reset vector patched to $FF00 executed:
  it wrote $D020=5 (green), $D021=0, $D011=$1B.  The border turned green.
  => CPU executes from ROM, reset-vector read works, VIC register writes work.
* The test program did NOT touch RAM.  The normal KERNAL does (stack $0100, zero page $0000,
  screen RAM $0400) and does not initialise the VIC.
* Original UnoXT `rom_c64_basic/kernal/chargen` are used; vectors are standard
  ($FFFA=$FE43, $FFFC=$FCE2, $FFFE=$FF48).
* IRQ/NMI tied high, reset tied to PLL lock: no change.
* UnoXT uses BRAM for the 64 KB C64 RAM; this port uses external SRAM through
  `c64_memory.v` + `cartridge.v`.  The SRAM path is the prime suspect.

## Clocks
clk_sys = 31.25 MHz (VCO 1000/32), clk_sram = 62.5 MHz (VCO/16), clk_vid = 27.027 MHz (VCO/37).
C64/cartridge SRAM access: phase 0 of clk_sram; aux (D64/video): phase 1.

## SRAM map (one byte per 16-bit word for the C64 bus)
0x000000-0x00FFFF C64 RAM; 0x010000-0x01FFFF cart RAM;
0x200000-0x2FFFFF cart ROM -> 0x020000-0x11FFFF; D64 -> 0x120000;
video frames -> 0x160000 / 0x1A0000.

## Code: c64_memory.v
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

## Code: c64_machine.v (CPU / cartridge / memory only)
```verilog

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
```

## Code: fpga64_sid_iec.vhd CPU / IRQ / NMI / reset-enable
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

## Code: fpga64_buslogic.vhd ROM/PLA
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

## Code: cpu_6510.vhd reset / port
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

## Questions
1. Is the `c64_memory.v` read timing right?  `ramCE`/`ramAddr` are one `clk_sys` cycle;
   we latch the address at `clk_sram` phase 0 and return `c_dout` at phase 1 (next
   `clk_sys` edge).  When does `fpga64_sid_iec`/`cartridge.v` actually sample `ramDin`?
2. Does `cartridge.v` expect a registered or combinational RAM data path?  Must data
   stay stable until the next `mem_ce`?
3. Is the clk_sram phase aligned to clk_sys after reset?  Could phase 0 fall on the wrong
   clk_sys edge?
4. Is the SRAM write pulse (16 ns) / read latency (10 ns tAA) correct?  Should reads be
   sampled at phase 0 of the next clk_sys instead of phase 1?
5. Does the KERNAL crash because early stack/zero-page writes do not land?  Which RAM
   test (write/read $0000, $0100, $0400) is the best minimal discriminator?
6. Is `cartridge.v` with `cart_id=255, exrom=1, game=1` routing C64 RAM correctly?
7. Does the VIC screen fetch use the same RAM path?  Could the KERNAL run but the screen
   stay blank because VIC reads are mistimed?
8. Does the MiSTer `fpga64_sid_iec` need a longer reset (UnoXT has `resetCycles=4095`)
   after PLL lock for CIA/VIC/6510 port to settle?
9. Any known issue with the MiSTer `fpga64_buslogic.vhd` when RAM is external and faster
   than the MiSTer SDRAM?
10. Best minimal patch to distinguish CPU/ROM/VIC from RAM: write/read $0400, $0100, $0000
    and set border green on success / red on failure?

---

## Latest results (2026-11-08)

* SRAM RAM test passes (`STA $0400`/`LDA`/`CMP` -> green border).
* VIC `$D020` write and `$D011` read-back work.
* `LDA $D012; STA $D020` gave only green + one blue band, not 16 bands (raster inconclusive).
* UnoXT machine with 64 KB RAM in BRAM (`gen_ram`, exactly like `c64_zxt.vhd`) and
  our SRAM only for the frame buffer fits (47% LUT, 44/52 RAMB16) but still shows black;
  OSD works.
* Suspect either the UnoXT machine does not start or `c64_video` cannot capture the old
  UnoXT VIC (`hSync/vSync` = `hBlanking/vBlanking`, `pixel_ce` timing).
* The `dbg_vic="1111"` debug was unreliable (connection/optimization); test the video path
  with a free-running pattern independent of the VIC.
* Clean baseline restored; test `.kg` in `doc/artifacts/`.

Questions for Kimi now:

1. How to best verify that the old UnoXT VIC raster/pixel_ce is alive and that `c64_video`
   captures it (polarity of hBlanking/vBlanking, pixel enable phase)?
2. Is the `fpga64_scandoubler` output (31 kHz) a better source for our 720x576 output than
   the raw 15 kHz VIC?
3. Why could the UnoXT machine with exact BRAM still show black while the OSD works?
4. Is there a known issue with `fpga64_sid_iec` `resetCycles` / `ramCE` / `ramDataReg` when
   the RAM is in BRAM and the clock is 31.25 MHz instead of 31.94 MHz?
5. Best minimal free-running debug pattern to prove the video/frame path independent of VIC.
