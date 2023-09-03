module mac_rx #(
	parameter IS_10G = 1,
	/* mac supports vlan tagging */
	parameter VLAN_TAG = 1,
	parameter DATA_W = 16,
	parameter KEEP_W = DATA_W/8,
	parameter LANE0_CNT_N = IS_10G & ( DATA_W == 64 )? 2 : 1
)(
	input clk,
	input nreset,

	// from physical layer
	input              valid_i,
	input              cancel_i,
	input [DATA_W-1:0] data_i,
	input                   ctrl_v_i,
	input                   idle_i,
	input [LANE0_CNT_N-1:0] start_i,
	input                   term_i,
	input [KEEP_W-1:0]      term_keep_i,

	// to IP layer
	output              valid_o,// data valid
	output [DATA_W-1:0] data_o,
	output [KEEP_W-1:0] keep_o,

	// frame check error
	output crc_err_o
);
localparam PRE_N  = 1;
localparam PRE_W  = PRE_N*8;;
localparam ADDR_N = 6;
localparam ADDR_W = ADDR_N*8;
localparam TYPE_N = 2;
localparam TYPE_W = TYPE_N*8;
localparam VLAN_N = ( VLAN_TAG )? 4 : 0; 
localparam HEAD_N = PRE_N + 2*ADDR_N + TYPE_N;
localparam HEAD_VTAG_N = HEAD_N + VLAN_N;
localparam CNT_W = $clog2(HEAD_VTAG_N); 
/* header index */
localparam TYPE_IDX = PRE_W + 2*ADDR_W;
/* type : IPv4 */
localparam IPV4 = 16'h0800; 
/* vlan tag protocol identifier */
localparam TPIC = 16'h8100;
/* fsm */
reg   fsm_invalid_q;
logic fsm_invalid_next;
reg   fsm_head_q;
logic fsm_head_next;
reg   fsm_data_q;
logic fsm_data_next;
reg   fsm_crc_q;
logic fsm_crc_next;


/* start of a new packet */
logic start_v;
assign start_v = fsm_invalid_q & (valid_i & ctrl_v_i & |start_i);

/* handle header : ignore all information
 * without vtag :
 * [ premable 8B | dst @ 6B | src @ 6B | type 2B ]

 * [ premable 8B | dst @ 6B | src @ 6B | vtag 4B | type 2B ] 
 *
 * count the number of bytes received since the start of the
 * packet.
 * If we are vlan aware check if we have a vlan tag.*/
reg   [CNT_W-1:0] cnt_q;
logic [CNT_W-1:0] cnt_next; 
logic [CNT_W-1:0] cnt_add;
logic             unused_cnt_add_of;
logic             cnt_rst; 
logic [CNT_W-1:0] data_cnt;


/* cnt the number of bytes received from the PCS */
if ((DATA_W == 64) && (IS_10G == 1)) begin
	/* first packet can have 4 or 8 bytes of data */
	assign data_cnt = start_v ? (start_i[1] ? 'd4 : 'd8): 8;
end else begin
	assign data_cnt = (DATA_W/8);
end

assign cnt_rst = fsm_invalid_q & ~start_v; 
assign {unused_cnt_add_of, cnt_add} = cnt_q + ({CNT_W{valid_i}} & data_cnt);
assign cnt_next = cnt_rst ? {CNT_W{1'b0}} : cnt_add;

always @(posedge clk) begin
	cnt_q <= cnt_next;
end

/* type and vlan */
logic [TYPE_W-1:0] type_id;
logic              type_v;// type index valid
logic              type_err_v;// type content matches accepted packet expectations, eg : IPv4

if ((DATA_W == 64) && (IS_10G))begin
	/* vlan tag and type index or type starts at 20 bytes, so the type field may
	 * not fall on the first indexes of the data depending on if
	 * start was received on the first or second lane0.
	 * If start was received on the second lane0, vlan_id will be
	 * received on the lsb bytes of data bus, else it will start at
	 * the 4th byte.
	 * type/vlan will be valid after 16 ( middle ) or 20 bytes */
	logic [TYPE_W-1:0] lite_type_id[1:0];

	assign lite_type_id[0] = data_i[TYPE_W-1:0];
	assign lite_type_id[1] = data_i[4*8+TYPE_W-1:4*8];

	if ( VLAN_TAG ) begin
		/* vlan and type may be received in the same packet
 		 * or in 2 consecutive packets */ 
		logic [TYPE_W-1:0] vlan_id;
		logic              vlan_idx_v;
		logic              vlan_v;
		logic              tpic_v;

		assign vlan_idx_v = cnt_q[4] & ~cnt_q[3] & &(~cnt_q[1:0]); 
		assign vlan_id = cnt_q[2] ? lite_type_id[0] : lite_type_id[1];
		assign tpic_v = vlan_id == TPIC;
		assign vlan_v = vlan_idx_v & tpic_v;
		
		/* get type */
		reg   type_lsb_v_q;	
		logic type_lsb_v_next;

		assign type_lsb_v_next = vlan_v & ~cnt_q[2];
		always @(posedge clk) begin
			type_lsb_v_q <= type_lsb_v_next;
		end	
		assign type_v  = vlan_idx_v & ( cnt_q[2] | ~cnt_q[2] &(~vlan_v | type_lsb_v_q));
		assign type_id = {TYPE_W{ cnt_q[2] & ~vlan_v}} &  lite_type_id[0]
					   | {TYPE_W{ cnt_q[2] &  vlan_v}} &  lite_type_id[1]
					   | {TYPE_W{~cnt_q[2] & ~type_lsb_v_q}} &  lite_type_id[1]  
					   | {TYPE_W{~cnt_q[2] &  type_lsb_v_q}} &  lite_type_id[0];  
	end else begin

		assign type_v  = cnt_q[4] & ~cnt_q[3] & &(~cnt_q[1:0]); 
		assign type_id = cnt_q[2] ? lite_type_id[0] : lite_type_id[1];	

	end // vlan tag
end else begin
	// DATA_W {16, 32}
	assign type_id = data_i[TYPE_W-1:0];

	if ( VLAN_TAG) begin
		logic [TYPE_W-1:0] vlan_id;
		logic              vlan_idx_v;
		logic              vlan_v;
		logic              tpic_v;
		
		assign vlan_idx_v = cnt_q == TYPE_IDX;
		assign vlan_id = data_i[TYPE_W-1:0];
		assign tpic_v = vlan_id == TPIC;
		assign vlan_v = vlan_idx_v & tpic_v;
	
		/* get type, delay for 1 or 2 cycles depending on
 		 * data size, vlan tag is 4 bytes long */
		localparam TYPE_CNT_W = DATA_W == 32 ? 1 : 2;
		reg   [TYPE_CNT_W-1:0] type_lsb_v_q;	
		logic [TYPE_CNT_W-1:0] type_lsb_v_next;

		assign type_lsb_v_next[TYPE_CNT_W-1] = vlan_v & ~cnt_q[2];
		if ( DATA_W == 16 ) begin
		assign type_lsb_v_next[0] = vlan_v ? 1'b0 : type_lsb_v_q[1];
		end
		always @(posedge clk) begin
			type_lsb_v_q <= type_lsb_v_next;
		end	

		assign type_v = ( vlan_idx_v & ~vlan_v ) | type_lsb_v_q[0];

	end else begin
		assign type_v = cnt_q == TYPE_IDX;
	end // vlan_tag
end
assign type_err_v = type_v & (type_id == IPV4);
 
/* data validity
 * controls if data will be sent to the upper layers.
 * We can invalidate data if packet is of the wrong type of there are
 * errors */
reg   data_v_q;
logic data_v_next;	
logic data_v_rst;

/* reasons to invalidate data */
assign data_v_rst  = fsm_invalid_q;
assign data_v_next = data_v_rst ? 1'b1 : data_v_q & ~type_err_v; 

always @(posedge clk) begin
	data_v_q <= data_v_next;
end

/* data shift and keep */
logic [KEEP_W-1:0] data_keep;
logic              term_lite_v;
logic [KEEP_W-1:0] term_data_keep;

assign term_lite_v    = ctrl_v_i & term_i;

if ( DATA_W == 16 ) begin
	assign data_keep = term_lite_v ? term_keep_i : {KEEP_W{1'b1}};
end else 
	/* if DATA_W > 16 need to shift data because of header */
	logic [KEEP_W-1:0] head_data_keep;
	logic [KEEP_W-1:0] head_data_shifted;
	logic              head_data_lite_v;

	assign data_keep = {KEEP_W{head_data_lite_v}} & head_data_keep
					 | {KEEP_W{term_keep_i}} & term_keep_i
					 | {KEEP_W{~head_data_keep & ~term_keep_i}}; // '1
					 
	if ( DATA_W == 32 ) begin
		/* with or whitout vtag data will be on the 2 msb bytes after the type */
		assign head_data_keep = {2'b0, 2'b11};
		assign head_data_shifted = data_i[31:16];
	end else if ( DATA_W == 64 ) begin
		/* cnt_q[2] = 20, start 2nd lane0 
 		 * no vtag :
 		 * [X | pre 4B] [pre 4B | @dst 4B] [@dst 2B | @src 6B] [type 2B| data 6B]
 		 * vtag : 
		 * [X | pre 4B] [pre 4B | @dst 4B] [@dst 2B | @src 6B] [vtag 4B| type 2B | data 2B]
 		 * 
 		 * ~cnt_q[2] = 16, start 1st lane0 
 		 * no vtag:
		 * [pre 8B] [@dst 6B | @scr 2B] [@src 4B | type 2B | data 2B]
		 * vtag:
		 * [pre 8B] [@dst 6B | @scr 2B] [@src 4B | vtag 4B] [type 2B | data 6B]
		 */
		logic head_data_shift2;
		if (IS_10G) begin
			if ( VLAN_TAG ) begin
				assign head_data_shift2 = cnt_q[2] ^ vlan_v;
			end else begin
				assign head_data_shift2 = ~cnt_q[2];	
			end
		end else // !10G
			if ( VLAN_TAG ) begin
				assign head_data_shift2 = ~vlan_v;
			end else begin // !VTAG
				assign head_data_shift2 = 1'b1;
			end
		end
		assign head_data_shifter = head_data_shift2
								 ? {data_i[DATA_W-:TYPE_W], {DATA_W-TYPE_W{1'bx}}}
								 : {data_i[DATA_W-:DATA_W-TYPE_W],{TYPE_W{1'bx}};
		assign head_data_keep = {2'b0, {4{~head_data_shift2}}, 2'b11};  
								  
end 
/* crc */

/* fsm */
logic term_v;
assign term_v = valid_i & term_lite_v;

assign fsm_invalid_next = cancel_i 
						| term_v;
assign fsm_head_next = ~cancel_i 
					 & (start_v 
					 | fsm_head_q & ~type_v);
assign fsm_data_next = ~cancel_i 
					 & (fsm_head_q & type_v
					 | fsm_data_q & term_v); 
always @(posedge clk) begin
	if ( ~nreset ) begin
		fsm_invalid_q <= 1'b1;
		fsm_head_q <= 1'b0;
		fsm_data_q <= 1'b0;
		fsm_crc_q <= 1'b0;
	end else begin
		fsm_invalid_q <= fsm_invalid_next;
		fsm_head_q <= fsm_head_next;
		fsm_data_q <= fsm_data_next;
		fsm_crc_q <= fsm_crc_next;
	end
end
endmodule
