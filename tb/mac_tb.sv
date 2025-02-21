`define TB_DATA_CYCLES 3


module mac_tb;
localparam DATA_W = 16;
localparam KEEP_W = DATA_W/8;
localparam VLAN_TAG = 1;
localparam IS_10G = 1;
localparam LANE0_CNT_N = IS_10G & ( DATA_W == 64 )? 2 : 1;

localparam TYPE_W = 16;
//localparam [7:0] START_CHAR = 8'haa;
localparam [TYPE_W-1:0] VLAN_TYPE = 16'h8100;
localparam [TYPE_W-1:0] IPV4_TYPE = 16'h8000;

localparam HEAD_LEN = 22 + ( VLAN_TAG ? 4 : 0 );
//localparam TB_PKT_LEN = HEAD_LEN + KEEP_W*`TB_DATA_CYCLES;

reg   clk = 1'b0;
/* verilator lint_off BLKSEQ */
always clk = #5 ~clk; 
/* verilator lint_on BLKSEQ */

logic nreset;
logic                   cancel_i;
logic                   valid_i;
logic [DATA_W-1:0]      data_i;
logic                   ctrl_v_i;
logic                   idle_i;
logic [LANE0_CNT_N-1:0] start_i;
logic                   term_i;
logic [KEEP_W-1:0]      term_keep_i;
/* verilator lint_off UNUSEDSIGNAL */
logic                   cancel_o;
logic                   valid_o;
logic [DATA_W-1:0]      data_o;
logic [KEEP_W-1:0]      keep_o;
logic                   crc_err_o;
/* verilator lint_on UNUSEDSIGNAL */

function void set_default();
	cancel_i = 1'b0;
	valid_i = 1'b0;
	ctrl_v_i = 1'b0;
	idle_i = 1'b0;
	start_i = {LANE0_CNT_N{1'b0}};
	term_i = 1'b0;
	term_keep_i = {KEEP_W{1'bx}};	
	data_i = {DATA_W{1'bx}};
endfunction

task idle_cycle();
	valid_i = 1'b1;
	ctrl_v_i = 1'b1;
	idle_i = 1'b1;
	#10
	ctrl_v_i = 1'b0;
	idle_i = 1'b0;
endtask
/* set mac header function
 * ipv4_v : set type to IPV4
 * has_vtag : include vtag */
function automatic logic [HEAD_LEN*8-1:0] set_head(int ipv4_v,int has_vtag );
	logic [HEAD_LEN*8-1:0] head;
	/* preambule */
	logic [63:0] pre = {56'hAAAAAAAAAAAAAA, 8'hAB};

	/* mac addr */
	// coca cola company
	logic [6*8-1:0] dst_addr = {24'h0 ,24'hFCD4F2};
	// molex
	logic [6*8-1:0] src_addr = {24'h0 ,24'hF82F08};
	

	/* type and vlan */
	logic [TYPE_W-1:0] h_type = {TYPE_W{ipv4_v!=0}} & IPV4_TYPE | {TYPE_W{ipv4_v == 0}};;

	if ( VLAN_TAG && (has_vtag!=0)) begin
		logic [31:0] vlan_tag;
		logic [2:0]  pcp;
		logic        dei;
		logic [11:0] vid;

		/* verilator lint_off WIDTHTRUNC */
		{ vid, dei, pcp } = $random; 
		/* verilator lint_on WIDTHTRUNC */

		vlan_tag = {vid, dei, pcp, VLAN_TYPE};
		head[HEAD_LEN*8-1-:8*6] = {h_type, vlan_tag};	
	end else begin
		head[22*8-1-:16] = h_type;	
	end
	head[20*8-1:0] = {src_addr, dst_addr, pre};
	return head;
endfunction

/* Send simple random packet */
task send_packet(int l, int ipv4_v, int has_vtag); 
	int s;
	int h_l;
	logic [DATA_W-1:0] tmp;
	logic [HEAD_LEN*8-1:0] h; 
	h = {HEAD_LEN*8{1'bx}};
	
	/* head */
	h_l = (has_vtag != 0)? 26 : 22;
	h = set_head(ipv4_v, has_vtag);

	/* set head */
	set_default();
	valid_i = 1'b1;
	ctrl_v_i = 1'b1;
	start_i = 'b1;
	data_i = h[0+:DATA_W];
	#10
	for(int i=KEEP_W; i < h_l/KEEP_W; i++) begin
		ctrl_v_i = 1'b0;
		data_i = h[i*DATA_W+:DATA_W];	
		#10
		data_i = {DATA_W{1'bx}};
	end
	/* complete data if full header was not sent */
	s = h_l % KEEP_W;
	for(int i=0; i<s; i++) begin
		data_i[i*8+:8] = h[h_l-(i*8)-1-:8];
	end

	/* send packet inner */
	for(int i=s; i< l+s; i++) begin
		/* verilator lint_off WIDTHTRUNC */	
		data_i[(i%KEEP_W)*8+:8] = $random;
		/* verilator lint_on WIDTHTRUNC */	
		if((i+1)%KEEP_W == 0)begin
			#10
			data_i = {DATA_W{1'bx}};
		end	
	end	
	/* send term */
	for(int i=0; i<KEEP_W; i++)begin
		if((l+s)%KEEP_W > i) begin
			term_keep_i[i] = 1'b1;
		end else begin
			term_keep_i[i] = 1'b0;
		end
	end
	ctrl_v_i = 1'b1;
	term_i = 1'b1;
	start_i = '0;
	#10
	ctrl_v_i = 1'b0;
	valid_i = 1'b0;	
endtask

initial begin
	$dumpfile("wave/mac_tb.vcd");
	$dumpvars(0, mac_tb);
	nreset = 1'b0;
	set_default();
	#10
	nreset = 1'b1;

	/* set idle cycle */
	idle_cycle();
	idle_cycle();

	/* Test 1 
 	 * simple packet, aligned on packet end  */
	$display("test 1 %t",$time);
	send_packet(8,1,1);
	
	idle_cycle();
	idle_cycle();
	/* Test 2 
 	 * simple packet, end of packet not
 	 * aligned on payload  */
	$display("test 2 %t",$time);
	send_packet(3,1,1);
	idle_cycle();
	idle_cycle();
	/* Test 3
 	 * long simple packet */
	$display("test 3 %t",$time);
	send_packet(34,1,1);
	idle_cycle();
	#10

	/* Test 4
 	 * wrong type, testing bypass functionality */
	$display("test 4 %t",$time);
	send_packet(8,0,1);
	idle_cycle();
	#10

	$display("Test finished %t",$time);
	$finish;
end


/* uut */
mac_rx#(
	.IS_10G(IS_10G),
	.VLAN_TAG(VLAN_TAG),
	.DATA_W(DATA_W),
	.KEEP_W(KEEP_W)
)m_mac_rx(
.clk(clk),
.nreset(nreset),
.cancel_i(cancel_i),
.valid_i(valid_i),
.data_i(data_i),
.ctrl_v_i(ctrl_v_i),
.idle_i(idle_i),
.start_i(start_i),
.term_i(term_i),
.term_keep_i(term_keep_i),
.cancel_o(cancel_o),
.valid_o(valid_o),
.data_o(data_o),
.keep_o(keep_o),
.crc_err_o(crc_err_o)
);
endmodule
