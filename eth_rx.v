/* MAC + IPv4 network stacks */
module eth_rx #(
	parameter IS_10G = 1,
	/* configuration */
	parameter VLAN_TAG = 1,
	parameter UDP = 1, /* 1 : UDP, 0 : TCP */
	
	parameter DATA_W = 16,
	parameter KEEP_W = DATA_W/8,
	parameter LEN_W  = $clog2(KEEP_W+1),
	parameter LANE0_CNT_N = IS_10G & ( DATA_W == 64 )? 2 : 1,
	/* IP */
	parameter IP_ADDR_W = 32,
	parameter MATCH_IP_SRC_ADDR = 1, 
	parameter MATCH_IP_DST_ADDR = 1, 
	parameter [IP_ADDR_W-1:0] IP_SRC_ADDR = {8'd206, 8'd200, 8'd127, 8'd128},
	parameter [IP_ADDR_W-1:0] IP_DST_ADDR = {8'd206, 8'd200, 8'd127, 8'd128},
	/* Transport protocol */
	parameter PROT_W = 8,
	parameter [PROT_W-1:0] PROT_UDP = 8'd17,
	parameter [PROT_W-1:0] PROT_TCP = 8'd6,
	parameter [PROT_W-1:0] PROTOCOL = UDP ? PROT_UDP : PROT_TCP,
	/* Port */
	parameter PORT_W   = 16,
	parameter [PORT_W-1:0] SRC_PORT = 16'd18070,
	parameter [PORT_W-1:0] DST_PORT = 16'd18070
)(
	input clk,
	input nreset,

	/* from physical layer */
	input                   mac_cancel_i,
	input                   mac_valid_i,
	input [DATA_W-1:0]      mac_data_i,
	input                   mac_ctrl_v_i,
	input                   mac_idle_i,
	input [LANE0_CNT_N-1:0] mac_start_i,
	input                   mac_term_i,
	input [KEEP_W-1:0]      mac_term_keep_i,
	
	/* to application */
	output                  app_valid_o,
	output                  app_cancel_o,
	output [DATA_W-1:0]     app_data_o,
	output [LEN_W-1:0]      app_len_o
);
/* MAC */
// mac -> ip
logic              ip_valid;
logic [DATA_W-1:0] ip_data;
logic [KEEP_W-1:0] ip_keep;
logic [LEN_W-1:0]  ip_len;
// frame check error
/* verilator lint_off UNUSEDSIGNAL */
logic mac_crc_err_v;
/* verilator lint_on UNUSEDSIGNAL */

/* MAC */
mac_rx #(
	.IS_10G(IS_10G),
	.VLAN_TAG(VLAN_TAG),
	.DATA_W(DATA_W),
	.KEEP_W(KEEP_W),
	.LANE0_CNT_N(LANE0_CNT_N)
)m_mac_rx(
	.clk   (clk),
	.nreset(nreset),
	.cancel_i   (mac_cancel_i),
	.valid_i    (mac_valid_i),
	.data_i     (mac_data_i),
	.ctrl_v_i   (mac_ctrl_v_i),
	.idle_i     (mac_idle_i),
	.start_i    (mac_start_i),
	.term_i     (mac_term_i),
	.term_keep_i(mac_term_keep_i),
	.crc_err_o  (mac_crc_err_v),
	.valid_o    (ip_valid),
	.data_o     (ip_data),
	.keep_o     (ip_keep)
);
/* translate ip keep to ip len */
thermo_to_len #(.KEEP_W(KEEP_W),.LEN_W(LEN_W)
)m_thermo_to_len(
	.keep_i(ip_keep),
	.len_o(ip_len)
);
 
/* IPv4 */

logic              t_valid;
logic [DATA_W-1:0] t_data;
logic [LEN_W-1:0]  t_len;
logic              ip_cs_err;

ipv4_rx #(
	.DATA_W(DATA_W),
	.LEN_W(LEN_W),
	.ADDR_W(IP_ADDR_W),
	.MATCH_SRC_ADDR(MATCH_IP_SRC_ADDR),
	.MATCH_DST_ADDR(MATCH_IP_DST_ADDR),
	.SRC_ADDR(IP_SRC_ADDR),
	.DST_ADDR(IP_DST_ADDR),
	.PROT_W(PROT_W),
	.PROTOCOL(PROTOCOL)
)m_ipv4_rx(
	.clk   (clk),
	.nreset(nreset),
	.cancel_i(mac_cancel_i),
	.valid_i (ip_valid),
	.data_i  (ip_data),
	.len_i   (ip_len),
	.cs_err_o(ip_cs_err),
	.valid_o (t_valid),
	.data_o  (t_data),
	.len_o   (t_len)
);

/* Transport */
if ( UDP ) begin : transport_layer
/* UDP */
udp_rx #(
	.DATA_W(DATA_W),
	.LEN_W(LEN_W),
	.PORT_W(PORT_W),
	.SRC_PORT(SRC_PORT),
	.DST_PORT(DST_PORT)
)m_udp_rx(
	.clk   (clk),
	.nreset(nreset),
	.cancel_i   (mac_cancel_i),
	.valid_i    (t_valid),
	.data_i     (t_data),
	.len_i      (t_len),
	.ip_cs_err_i(ip_cs_err),
	.valid_o    (app_valid_o),
	.data_o     (app_data_o), 
	.len_o      (app_len_o)
);
	assign app_cancel_o = mac_cancel_i;
end else begin
/* TCP */
/* TODO */
end

endmodule
