//////////////////////////////////////////////////////////////////////////////////////
//Module Name : mac_top
//Description :
//
//////////////////////////////////////////////////////////////////////////////////////
`timescale 1 ns/1 ns
module mac_top
       (
         input                gmii_tx_clk  ,
         input                gmii_rx_clk  ,
         input                rst_n     ,
         
         input  [47:0]        source_mac_addr ,       //source mac address
         input  [7:0]         TTL,
         input  [31:0]        source_ip_addr,
         input  [31:0]        destination_ip_addr,
         input  [15:0]        udp_send_source_port,
         input  [15:0]        udp_send_destination_port,
         
         
         input  [7:0]         ram_wr_data,
         input                ram_wr_en,
         output               udp_ram_data_req,
         input  [15:0]        udp_send_data_length,
         output               udp_tx_end,
         output               almost_full,
         
         input                udp_tx_req,
         input                arp_request_req,
         output               mac_data_valid,
         output               mac_send_end,
         output [7:0]         mac_tx_data,
         
         input                rx_dv,
         input  [7:0]         mac_rx_datain,
         output [7:0]         udp_rec_ram_rdata ,
         input  [10:0]        udp_rec_ram_read_addr,
    output     [15:0]       udp_rec_data_length ,
    output                  dbg_ram_wr_en,
    output     [10:0]       dbg_ram_wr_addr,
    output     [7:0]        dbg_ram_wr_data,
         output               udp_rec_data_valid,
         
         output               arp_found,
         output               mac_not_exist,

    // ---- diagnostics added for bring-up (not part of the vendor original) ----
    // icmp_rev_error is the vendor's own "this frame was rejected" aggregate:
    //     mac_rec_error | ip_checksum_error | ip_addr_check_error
    // where mac_rec_error covers the preamble check, the ethertype filter and the
    // FCS comparison.  Counting it is the difference between "frames arrive" and
    // "frames arrive and are accepted".
    output               dbg_rec_error,
    output               dbg_mac_err,
    output               dbg_ip_csum_err,
    output               dbg_ip_addr_err
    ) ;
       
       
wire                  arp_reply_ack ;
wire                  arp_reply_req ;
wire  [31:0]          arp_rec_source_ip_addr ;
wire  [47:0]          arp_rec_source_mac_addr ;
wire   [47:0]         destination_mac_addr ;

wire [7:0]            mac_rx_dataout ;
wire [15:0]           upper_layer_data_length ;
wire                  icmp_rx_req ;
wire                  icmp_rev_error ;
    assign dbg_rec_error = icmp_rev_error;
wire                  upper_data_req ;
wire                  icmp_tx_ready ;
wire  [7:0]           icmp_tx_data ;
wire                  icmp_tx_end ;
wire                  icmp_tx_req ;
wire                  icmp_tx_ack ;
wire [15:0]           icmp_send_data_length ;

mac_tx_top mac_tx0
           (
            .clk                         (gmii_tx_clk)                  ,
            .rst_n                       (rst_n)  ,
            
            .destination_mac_addr        (destination_mac_addr)   , //destination mac address
            .source_mac_addr             (source_mac_addr)   ,       //source mac address
            .TTL                         (TTL),
            .source_ip_addr              (source_ip_addr),
            .destination_ip_addr         (destination_ip_addr),
            
            .udp_send_source_port        (udp_send_source_port),
            .udp_send_destination_port   (udp_send_destination_port),
            
            .arp_reply_ack               (arp_reply_ack ),
            .arp_reply_req               (arp_reply_req ),
            .arp_rec_source_ip_addr      (arp_rec_source_ip_addr ),
            .arp_rec_source_mac_addr     (arp_rec_source_mac_addr ),
            .arp_request_req             (arp_request_req ),
            
            
            .ram_wr_data                 (ram_wr_data) ,
            .ram_wr_en                   (ram_wr_en),
            .udp_tx_req                  (udp_tx_req),
            .udp_send_data_length        (udp_send_data_length       ),
            .udp_ram_data_req            (udp_ram_data_req           ),
            .udp_tx_end                  (udp_tx_end                 ),
            .almost_full                 (almost_full                ),  
            
            .upper_data_req              (upper_data_req ),
            .icmp_tx_ready               (icmp_tx_ready ),
            .icmp_tx_data                (icmp_tx_data  ),
            .icmp_tx_end                 (icmp_tx_end  ),
            .icmp_tx_req                 (icmp_tx_req  ),
            .icmp_tx_ack                 (icmp_tx_ack  ),
            .icmp_send_data_length       (icmp_send_data_length),
            
            .mac_data_valid              (mac_data_valid),
            .mac_send_end                (mac_send_end),
            .mac_tx_data                 (mac_tx_data)
           ) ;
           
           
           
           
           
           
mac_rx_top mac_rx0
           (
            .clk                      (gmii_rx_clk)                  ,
            .rst_n                    (rst_n)  ,
            
            .rx_dv                    (rx_dv   ),
            .mac_rx_datain            (mac_rx_datain ),
            
            .local_ip_addr            (source_ip_addr ),
            .local_mac_addr           (source_mac_addr),
            .arp_reply_ack            (arp_reply_ack ),
            .arp_reply_req            (arp_reply_req ),
            .arp_rec_source_ip_addr   (arp_rec_source_ip_addr ),
            .arp_rec_source_mac_addr  (arp_rec_source_mac_addr ),
            
            .udp_rec_ram_rdata        (udp_rec_ram_rdata),
            .udp_rec_ram_read_addr    (udp_rec_ram_read_addr),
    .udp_rec_data_length      (udp_rec_data_length ),
    .dbg_ram_wr_en            (dbg_ram_wr_en),
    .dbg_ram_wr_addr          (dbg_ram_wr_addr),
    .dbg_ram_wr_data          (dbg_ram_wr_data),
            .udp_rec_data_valid       (udp_rec_data_valid),
            
            .mac_rx_dataout           (mac_rx_dataout ),
            .upper_layer_data_length  (upper_layer_data_length  ),
            .ip_total_data_length     (icmp_send_data_length),
            .icmp_rx_req              (icmp_rx_req ),
            .icmp_rev_error           (icmp_rev_error ),
            
            .arp_found                (arp_found  ),
            .dbg_mac_err              (dbg_mac_err),
            .dbg_ip_csum_err          (dbg_ip_csum_err),
            .dbg_ip_addr_err          (dbg_ip_addr_err)
           ) ;
           
           
icmp_reply icmp0
           (
              .clk                      (gmii_rx_clk)                  ,
              .rst_n                    (rst_n)  ,
              .mac_send_end             (mac_send_end   ),
              .icmp_rx_data             (mac_rx_dataout ),
              .icmp_rx_req              (icmp_rx_req ),
              .icmp_rev_error           (icmp_rev_error ),
              
              .upper_layer_data_length  (upper_layer_data_length  ),
              
              .icmp_data_req            (upper_data_req  ),
              .icmp_tx_ready            (icmp_tx_ready ),
              .icmp_tx_data             (icmp_tx_data  ),
              .icmp_tx_end              (icmp_tx_end  ),
              .ip_tx_ack              (icmp_tx_ack  ),
              .icmp_tx_req              (icmp_tx_req  )
             
             
           );
           
           
arp_cache cache0
(
 .clk                         (gmii_tx_clk),
 .rst_n                       (rst_n),
 .arp_found                   (arp_found  ),
 .arp_rec_source_ip_addr      (arp_rec_source_ip_addr ),
 .arp_rec_source_mac_addr     (arp_rec_source_mac_addr ),
 .destination_ip_addr         (destination_ip_addr),
 .destination_mac_addr        (destination_mac_addr)   ,
 .mac_not_exist               (mac_not_exist )
);
endmodule
