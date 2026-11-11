// ============================================================================
// c64video.v
// C64 VIC RGB (504 px x 312 lines, 7.8125 MHz pixel_ce on clk=31.25 MHz)
//  -> 720x576@49.68 (1008 x 624, clk=31.25 MHz), Tang/C64Nano-style timing.
//
// The video clock is the same 31.25 MHz clock as the C64 core: a VIC line
// (2016 clk) is exactly two output lines (2 x 1008 clk) and a VIC frame
// (312 x 2016 = 628992 clk) is exactly 624 output lines.  There is no
// 870/871 line-length alternation and no clock-domain crossing in the
// line buffer.  The output counters are free-running; one VIC frame event
// aligns them, then the exact integer ratio keeps them locked.
//
// The C64Nano/Tang HDMI PAL timing is 720x576 visible, 1008x624 total,
// hsync 744..816, vsync 581..586.  The 4:3 C64 picture is placed inside
// the 720x576 frame by a fixed window: 396 source pixels -> 660 output
// pixels with 30 black pixels on each side (3/5 scaler), and 200 source
// lines -> 400 output lines at source line 18.
//
// BRAM: 4 rows x 512 x 16 (RGB565) = 2048x16 -> 2 x RAMB16.
// ============================================================================
module c64video #(
    // output timing (720x576 visible, 1008x624 total, 49.68 Hz)
    parameter H_ACTIVE      = 720,
    parameter H_TOTAL       = 1008,
    parameter V_ACTIVE      = 576,
    parameter V_CONTENT     = 576,             // visible content height
    parameter V_OFFSET      = 0,               // first output line of the content
    parameter V_TOTAL       = 624,
    parameter H_SYNC_START  = 720 + 24,        // 744, Tang/C64Nano PAL
    parameter H_SYNC_END    = 720 + 24 + 72,   // 816
    parameter V_SYNC_START  = 576 + 5,         // 581
    parameter V_SYNC_END    = 576 + 5 + 5,     // 586
    // source geometry
    parameter SRC_PIX       = 504,             // pixel_ce per line
    parameter SRC_LINE0     = 18,              // first source line shown (fixed)
    parameter SRC_X0        = 0,               // first source x shown (fixed)
    parameter LAG           = 2,               // output frame starts when source
                                               // line SRC_LINE0+LAG begins writing
    parameter X_LOAD        = 396,             // line-buffer x at hblank rise:
                                               // make line-buffer x = rasterX
    parameter X_DELAY       = 30,              // black output pixels on the left
    parameter H_VIEW        = 660,             // scaled source window in output px
    parameter X_STEP_NUM    = 3,               // source pixels per output pixel
    parameter X_STEP_DEN    = 5,               // numerator/denominator (3/5 or 1/2)
    parameter STALL_MAX     = 40,              // free-run if no VIC frame start
    parameter MASK_BLANK    = 1                // write black during h/v blank
)(
    input         clk_sys,
    input         clk_vid,
    input         rst,                         // active high, any domain-ish
    input         disk_act,                    // 1541 read activity, clk_vid
    input         disk_wr,                     // 1541 write activity, clk_vid
    input         tape_act,                    // tape motor/read activity, clk_vid
    input         tape_wr,                     // tape write activity, clk_vid

    // from fpga64_sid_iec (clk_sys domain)
    input  [7:0]  vic_r,
    input  [7:0]  vic_g,
    input  [7:0]  vic_b,
    input         vic_hblank,                  // active high during blanking
    input         vic_vblank,                  // active high during blanking
    input         vic_pixel_ce,                // 8 per C64 cycle

    // to HDMI / OSD (clk_vid domain), registered
    output reg [7:0] out_r,
    output reg [7:0] out_g,
    output reg [7:0] out_b,
    output reg       out_hs,
    output reg       out_vs,
    output reg       out_de
);

    // ------------------------------------------------------------------
    // Line buffer: {row[1:0], x[8:0]} x 16 bit
    // ------------------------------------------------------------------
    (* ram_style = "block" *) reg [15:0] mem [0:2047];

    // ------------------------------------------------------------------
    // WRITE SIDE  (clk_sys)
    // ------------------------------------------------------------------
    reg        hb_q, vb_q, vb_pend;
    reg [8:0]  wr_x, wr_line;
    reg        sync_tgl;
    reg [8:0]  wr_gray;

    wire hb_rise  = vic_pixel_ce & vic_hblank & ~hb_q;
    wire vb_rise  = vic_pixel_ce & vic_vblank & ~vb_q;
    wire new_zero = vb_pend | vb_rise;
    wire [8:0] line_next = new_zero ? 9'd0 : (wr_line + 9'd1);
    wire [8:0] cur_line  = hb_rise ? line_next : wr_line;
    wire [8:0] cur_x     = hb_rise ? X_LOAD[8:0] : wr_x;

    wire [10:0] wa = {cur_line[1:0], cur_x};
    wire [15:0] wd = (MASK_BLANK != 0 && (vic_hblank | vic_vblank)) ? 16'd0 :
                     {vic_r[7:3], vic_g[7:2], vic_b[7:3]};

    always @(posedge clk_sys) begin
        if (vic_pixel_ce)
            mem[wa] <= wd;
    end

    always @(posedge clk_sys) begin
        if (rst) begin
            hb_q     <= 1'b0;
            vb_q     <= 1'b0;
            vb_pend  <= 1'b0;
            wr_x     <= 9'd0;
            wr_line  <= 9'd0;
            sync_tgl <= 1'b0;
        end else if (vic_pixel_ce) begin
            hb_q <= vic_hblank;
            vb_q <= vic_vblank;
            if (vb_rise) vb_pend <= 1'b1;
            if (hb_rise) begin
                vb_pend <= 1'b0;
                wr_line <= line_next;
                // genlock event: output frame starts now
                if (line_next == (SRC_LINE0 + LAG))
                    sync_tgl <= ~sync_tgl;
            end
            wr_x <= (cur_x == SRC_PIX-1) ? 9'd0 : (cur_x + 9'd1);
        end
    end

    // gray-coded line counter for safe CDC to clk_vid (same clock here)
    always @(posedge clk_sys)
        wr_gray <= wr_line ^ {1'b0, wr_line[8:1]};

    // ------------------------------------------------------------------
    // CDC into clk_vid
    // ------------------------------------------------------------------
    reg [8:0] g1, g2;
    reg       t1, t2, t3;
    reg       r1, r2;

    always @(posedge clk_vid) begin
        g1 <= wr_gray;  g2 <= g1;
        t1 <= sync_tgl; t2 <= t1; t3 <= t2;
        r1 <= rst;      r2 <= r1;
    end

    wire sync_pulse = t2 ^ t3;

    // gray -> binary: wl = line currently being written
    wire [8:0] wl;
    assign wl[8] = g2[8];
    assign wl[7] = wl[8] ^ g2[7];
    assign wl[6] = wl[7] ^ g2[6];
    assign wl[5] = wl[6] ^ g2[5];
    assign wl[4] = wl[5] ^ g2[4];
    assign wl[3] = wl[4] ^ g2[3];
    assign wl[2] = wl[3] ^ g2[2];
    assign wl[1] = wl[2] ^ g2[1];
    assign wl[0] = wl[1] ^ g2[0];

    // ------------------------------------------------------------------
    // OUTPUT TIMING + READ SIDE (clk_vid)
    // ------------------------------------------------------------------
    reg [9:0] hc, vc;
    reg       locked;        // a VIC frame has been seen and aligned
    reg [20:0] ev_timer;     // clk_vid since the last VIC frame event
    reg [8:0] sx;
    reg [2:0] acc;
    reg [1:0] rd_row;

    wire de0 = (hc < H_ACTIVE) && (vc < V_ACTIVE);
    wire hs0 = (hc >= H_SYNC_START) && (hc < H_SYNC_END);
    wire vs0 = (vc >= V_SYNC_START) && (vc < V_SYNC_END);

    // A source frame event is expected at output line 0.  Do not re-align on
    // a one-line phase offset; only recover when the phase is clearly lost.
    wire event_bad = !locked || (vc > 10'd10);
    // ~35 ms without a VIC frame: the source is stopped (reset, ROM load).
    // Keep the syncs and the OSD, show black.
    wire event_timeout = (ev_timer > 21'd1_100_000);

    always @(posedge clk_vid) begin
        if (r2) begin
            hc <= 10'd0; vc <= 10'd0;
            locked <= 1'b0; ev_timer <= 21'd0;
        end else begin
            if (hc == H_TOTAL[9:0] - 10'd1) begin
                hc <= 10'd0;
                vc <= (vc == V_TOTAL[9:0] - 10'd1) ? 10'd0 : (vc + 10'd1);
            end else
                hc <= hc + 10'd1;

            if (sync_pulse) begin
                ev_timer <= 21'd0;
                if (event_bad) begin
                    hc <= 10'd0; vc <= 10'd0;
                end
                locked <= 1'b1;
            end else begin
                if (ev_timer != 21'h1FFFFF)
                    ev_timer <= ev_timer + 21'd1;
                if (event_timeout)
                    locked <= 1'b0;
            end
        end
    end

    // source line selection: the ring has 4 rows and the read is 2 source
    // lines behind the write.  The source and output rates are exactly
    // 2016 clk per VIC line and 2*1008 clk per output line pair, so the
    // phase never drifts.
    wire [9:0] vc_rel = vc - V_OFFSET[9:0];
    wire       vcontent = (vc >= V_OFFSET[9:0]) &&
                          (vc < (V_OFFSET[9:0] + V_CONTENT[9:0]));
    wire [8:0] nom_line = SRC_LINE0[8:0] + vc_rel[9:1];

    always @(posedge clk_vid) begin
        if (hc == 10'd0 && !vc[0])
            rd_row <= nom_line[1:0];
    end

    // x scaler: X_STEP_NUM/X_STEP_DEN source pixels per output pixel from
    // SRC_X0; 3/5 gives the 4:3 window, 1/2 gives an integer 2x picture.
    wire [3:0] acc_n = {1'b0, acc} + X_STEP_NUM[3:0];
    wire       xwin = (hc >= X_DELAY[9:0]) &&
                      (hc < (X_DELAY[9:0] + H_VIEW[9:0]));

    always @(posedge clk_vid) begin
        if (hc == X_DELAY[9:0]) begin
            sx  <= SRC_X0[8:0];
            acc <= 3'd0;
        end else if ((hc > X_DELAY[9:0]) && (hc <= X_DELAY[9:0] + H_VIEW[9:0])) begin
            if (acc_n >= X_STEP_DEN[3:0]) begin
                sx  <= sx + 9'd1;
                acc <= acc_n[2:0] - X_STEP_DEN[2:0];
            end else
                acc <= acc_n[2:0];
        end
    end

    // BRAM read (1 clk latency)
    reg [15:0] rd;
    always @(posedge clk_vid)
        rd <= mem[{rd_row, sx}];

    // control pipeline: de0/hs0/vs0 -> d1 (addr phase) -> d2 (BRAM data) -> out
    reg de_d1, hs_d1, vs_d1, de_d2, hs_d2, vs_d2;
    reg vc_d1, vc_d2;
    reg xwin_d1, xwin_d2;
    always @(posedge clk_vid) begin
        de_d1 <= de0;   hs_d1 <= hs0;   vs_d1 <= vs0;
        de_d2 <= de_d1; hs_d2 <= hs_d1; vs_d2 <= vs_d1;
        vc_d1 <= vcontent; vc_d2 <= vc_d1;
        xwin_d1 <= xwin; xwin_d2 <= xwin_d1;
    end

    // RGB565 -> RGB888 with bit replication (white -> FF)
    wire [7:0] e_r = {rd[15:11], rd[15:13]};
    wire [7:0] e_g = {rd[10:5],  rd[10:9]};
    wire [7:0] e_b = {rd[4:0],   rd[4:2]};

    // Activity square: 8 (disk) or T (tape), green = read, red = write.
    wire [9:0] mark_x = hc - 10'd13;
    wire [9:0] mark_y = vc - 10'd558;
    wire       tape_sel = tape_act | tape_wr;
    wire       ind_on   = tape_sel | disk_act | disk_wr;
    wire       ind_wr   = tape_sel ? tape_wr : disk_wr;
    wire       ind_t    = tape_sel;

    reg [5:0] digit_row8;
    reg [5:0] digit_rowt;
    always @(*) begin
        case (mark_y[2:0])
            3'd0: digit_row8 = 6'b011110;
            3'd1: digit_row8 = 6'b110011;
            3'd2: digit_row8 = 6'b110011;
            3'd3: digit_row8 = 6'b011110;
            3'd4: digit_row8 = 6'b110011;
            3'd5: digit_row8 = 6'b110011;
            3'd6: digit_row8 = 6'b011110;
            default: digit_row8 = 6'b000000;
        endcase
        case (mark_y[2:0])
            3'd0: digit_rowt = 6'b111111;
            3'd1: digit_rowt = 6'b001100;
            3'd2: digit_rowt = 6'b001100;
            3'd3: digit_rowt = 6'b001100;
            3'd4: digit_rowt = 6'b001100;
            3'd5: digit_rowt = 6'b001100;
            3'd6: digit_rowt = 6'b001100;
            default: digit_rowt = 6'b000000;
        endcase
    end
    wire [5:0] ind_row = ind_t ? digit_rowt : digit_row8;
    wire ind_glyph = (hc >= 10'd13) && (hc < 10'd19) &&
                     (vc >= 10'd558) && (vc < 10'd565) &&
                     ind_row[5 - mark_x[2:0]];
    wire ind_rect  = ind_on && (hc >= 10'd8) && (hc < 10'd24) &&
                     (vc >= 10'd556) && (vc < 10'd568);

    // Register the overlay one pixel early so the output mux has no long
    // path from the hc/vc counters and the activity inputs.
    reg ind_on_d, ind_glyph_d, ind_wr_d;
    always @(posedge clk_vid) begin
        ind_on_d    <= ind_rect;
        ind_glyph_d <= ind_glyph;
        ind_wr_d    <= ind_wr;
    end

    always @(posedge clk_vid) begin
        out_de <= de_d2;
        out_hs <= hs_d2;
        out_vs <= vs_d2;
        if (ind_on_d) begin
            if (ind_glyph_d) begin
                out_r <= 8'h00; out_g <= 8'h00; out_b <= 8'h00;
            end
            else if (ind_wr_d) begin
                out_r <= 8'hFF; out_g <= 8'h00; out_b <= 8'h00;
            end
            else begin
                out_r <= 8'h00; out_g <= 8'hFF; out_b <= 8'h00;
            end
        end
        else begin
            out_r <= (de_d2 && locked && vc_d2 && xwin_d2) ? e_r : 8'd0;
            out_g <= (de_d2 && locked && vc_d2 && xwin_d2) ? e_g : 8'd0;
            out_b <= (de_d2 && locked && vc_d2 && xwin_d2) ? e_b : 8'd0;
        end
    end

endmodule
