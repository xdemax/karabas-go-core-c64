// TAP image loader for the Karabas "F" tape item (slot 6).
//
// The F image stream comes from c64_img_file_loader (512-byte sector buffer)
// and is written into the free SRAM window 0x160000..0x1DFFFF (512 KB), the
// area that used to hold external video frames.  The tape player reads it
// through the SRAM tape-read port.
//
// A small 16-byte queue decouples the paced file stream from the SRAM write
// handshake.  TAP version is byte 12 of the header (bits 1:0).
`timescale 1ns / 1ps
`default_nettype none

module c64_tap_loader (
	input wire        clk,                 // clk_host
	input wire        reset,               // power-on only

	input wire        file_reset,
	input wire        file_active,
	input wire        file_wr,
	input wire [31:0] file_size,
	input wire [31:0] file_addr,
	input wire [7:0]  file_data,
	input wire [7:0]  file_slot,
	input wire        eject,

	// SRAM write port
	output reg        tap_wr_req,
	output reg [18:0] tap_wr_addr,
	output reg [7:0]  tap_wr_data,
	input wire        tap_wr_ack,

	// status to the tape player
	output reg        tap_loaded,
	output reg [19:0] tap_size,
	output reg [1:0]  tap_version,
	output reg        busy,
	output reg        error
);

localparam [7:0] TAP_SLOT = 8'd6;

reg        slot_ok;
reg        seen_active;
reg        file_done;
reg        pending_finish;

reg [7:0] q_data [0:15];
reg [3:0]  q_wp, q_rp;
reg [4:0]  q_cnt;
wire       q_full  = (q_cnt == 5'd16);
wire       q_empty = (q_cnt == 5'd0);

reg [19:0] data_count;   // bytes accepted from the file
reg [19:0] wr_count;     // bytes handed to the SRAM writer
reg        wr_busy;

reg [1:0]  ack_s;
wire       ack = ack_s[1];

always @(posedge clk)
	ack_s <= {ack_s[0], tap_wr_ack};

always @(posedge clk) begin
	tap_wr_req <= 1'b0;

	if (reset) begin
		slot_ok <= 1'b0;
		seen_active <= 1'b0;
		file_done <= 1'b0;
		pending_finish <= 1'b0;
		q_wp <= 4'd0;
		q_rp <= 4'd0;
		q_cnt <= 5'd0;
		data_count <= 20'd0;
		wr_count <= 20'd0;
		wr_busy <= 1'b0;
		tap_wr_addr <= 19'd0;
		tap_wr_data <= 8'd0;
		tap_loaded <= 1'b0;
		tap_size <= 20'd0;
		tap_version <= 2'd0;
		busy <= 1'b0;
		error <= 1'b0;
	end
	else begin
		if (eject) begin
			slot_ok <= 1'b0;
			seen_active <= 1'b0;
			file_done <= 1'b0;
			pending_finish <= 1'b0;
			q_wp <= 4'd0;
			q_rp <= 4'd0;
			q_cnt <= 5'd0;
			wr_busy <= 1'b0;
			tap_loaded <= 1'b0;
			tap_size <= 20'd0;
			busy <= 1'b0;
		end

		if (file_reset) begin
			if (file_slot == TAP_SLOT) begin
				slot_ok <= 1'b1;
				seen_active <= 1'b0;
				file_done <= 1'b0;
				pending_finish <= 1'b0;
				q_wp <= 4'd0;
				q_rp <= 4'd0;
				q_cnt <= 5'd0;
				data_count <= 20'd0;
				wr_count <= 20'd0;
				wr_busy <= 1'b0;
				tap_loaded <= 1'b0;
				tap_size <= 20'd0;
				tap_version <= 2'd0;
				busy <= 1'b1;
				error <= 1'b0;
			end
			else begin
				// another F item starts while a TAP image is loading:
				// the single file stream moves away, so abort and release
				// the C64 instead of holding it forever.
				if (busy) begin
					busy <= 1'b0;
					tap_loaded <= 1'b0;
					error <= 1'b1;
				end
				slot_ok <= 1'b0;
				seen_active <= 1'b0;
				file_done <= 1'b0;
				pending_finish <= 1'b0;
			end
		end
		else if (slot_ok) begin
			if (file_active)
				seen_active <= 1'b1;

			// accept a file byte into the queue
			if (file_wr) begin
				if (file_addr == 32'd12)
					tap_version <= file_data[1:0];

				if (!q_full && (data_count < 20'h80000)) begin
					q_data[q_wp] <= file_data;
					q_wp <= q_wp + 4'd1;
					q_cnt <= q_cnt + 5'd1;
					data_count <= data_count + 20'd1;
				end
				else
					error <= 1'b1;
			end

			// drain one queued byte to SRAM
			if (wr_busy) begin
				tap_wr_req <= 1'b1; // hold until acknowledged
				if (ack) begin
					wr_busy <= 1'b0;
					tap_wr_req <= 1'b0;
					wr_count <= wr_count + 20'd1;
				end
			end
			else if (!q_empty && !ack) begin
				tap_wr_req <= 1'b1;
				tap_wr_addr <= wr_count[18:0];
				tap_wr_data <= q_data[q_rp][7:0];
				q_rp <= q_rp + 4'd1;
				q_cnt <= q_cnt - 5'd1;
				wr_busy <= 1'b1;
			end

			if (seen_active && !file_active && !file_done) begin
				file_done <= 1'b1;
				pending_finish <= 1'b1;
			end

			if (pending_finish && q_empty && !wr_busy && !ack) begin
				pending_finish <= 1'b0;
				tap_loaded <= !error;
				tap_size <= data_count;
				busy <= 1'b0;
			end
		end
	end
end

endmodule
`default_nettype wire
