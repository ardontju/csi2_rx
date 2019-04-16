/*
  CSI2 Receiver IP-Core
  Consists of three logical parts
  DPHY Receiving -> CSI2 Packet Handling -> AXI4 Video Stream
  Conversion
  After it has been converted into AXI4-Stream packet it passes CDC
  to pixel frequency clock domain
*/

module csi2_rx #(
  parameter int DATA_LANES = 2
)(
  // DPHY inputs
  input                       dphy_clk_p_i,
  input                       dphy_clk_n_i,
  input  [DATA_LANES - 1 : 0] dphy_data_p_i,
  input  [DATA_LANES - 1 : 0] dphy_data_n_i,
  input  [DATA_LANES - 1 : 0] lp_data_p_i,
  input  [DATA_LANES - 1 : 0] lp_data_n_i,
  // 200 MHz refernce clock
  input                       ref_clk_i,
  input                       ref_rst_i,
  // 74.25 MHz pixel clock
  input                       px_clk_i,
  input                       px_rst_i,
  // Disables synchronizing of DPHY
  input                       enable_i,
  // IDELAYE2 delay values
  input                       delay_act_i,
  input  [DATA_LANES - 1 : 0] lane_delay_i,
  // Error signals
  output                      header_err_o,
  output                      corr_header_err_o,
  output                      crc_err_o,
  // AXI4 Video Stream
  axi4_stream_if.master       video_o
);

// Structure to pass over CDC
typedef struct packed {
  bit [31 : 0] tdata;
  bit [3 : 0]  tstrb;
  bit          tlast;
} axi4_word_t;

// Clock from DPHY
logic          rx_clk;
// Asserted when clock from DPHY stops
logic          clk_loss_rst;
// DPHY synchronization reset
// Asserted if header error appears or long
// packet has ended. Also asserted when enable
// is deasserted
logic          phy_rst;
// Output from DPHY
logic [31 : 0] phy_data;
logic          phy_data_valid;
// First word of long packet or short packet
logic          header_valid;
// Bit error in header detected
logic          header_error;
// Bit error in header corrected
logic          header_error_corrected;
// Header error uncorrected (i.e. we can't be sure how many words
// are in packet)
logic          pkt_error;
// Long packet payload CRC check
logic          crc_passed;
logic          crc_failed;
// Data after header corrector module
logic [31 : 0] corrected_phy_data;
logic          corrected_phy_data_valid;
// Signalize that there is no data in DC FIFO
// i.e. !valid
logic          rx_px_cdc_empty;
// Shor packet with frame start information detected
logic          frame_start_pkt;

// rx_clk CDC data
axi4_word_t    pkt_word_rx_clk;
axi4_stream_if #(
  .DATA_WIDTH ( 32             )
) csi2_pkt_rx_clk_if (
  .aclk       ( rx_clk         ),
  .aresetn    ( !clk_loss_rst  )
);

// px_clk CDC data
axi4_word_t    pkt_word_px_clk;
axi4_stream_if #(
  .DATA_WIDTH ( 32        )
) csi2_pkt_px_clk_if (
  .aclk       ( px_clk_i  ),
  .aresetn    ( !px_rst_i )
);

// 32 bit payload without header and CRC
axi4_stream_if #(
  .DATA_WIDTH ( 32        )
) payload_if (
  .aclk       ( px_clk_i  ),
  .aresetn    ( !px_rst_i )
);

// 40 bit payload
axi4_stream_if #(
  .DATA_WIDTH ( 40        )
) payload_40b_if (
  .aclk       ( px_clk_i  ),
  .aresetn    ( !px_rst_i )
);

assign pkt_error         = header_error && !header_error_corrected;
assign header_err_o      = header_valid && header_error;
assign corr_header_err_o = header_valid && header_error &&
                           header_error_corrected;
assign crc_err_o         = crc_failed;

dphy_slave #(
  .DATA_LANES       ( DATA_LANES     )
) phy (
  .dphy_clk_p_i     ( dphy_clk_p_i   ),
  .dphy_clk_n_i     ( dphy_clk_n_i   ),
  .dphy_data_p_i    ( dphy_data_p_i  ),
  .dphy_data_n_i    ( dphy_data_n_i  ),
  .lp_data_p_i      ( lp_data_p_i    ),
  .lp_data_n_i      ( lp_data_n_i    ),
  .delay_act_i      ( delay_act_i    ),
  .lane_delay_i     ( lane_delay_i   ),
  .ref_clk_i        ( ref_clk_i      ),
  .px_clk_i         ( px_clk_i       ),
  .phy_rst_i        ( phy_rst        ),
  .clk_loss_rst_o   ( clk_loss_rst   ),
  .data_o           ( phy_data       ),
  .clk_o            ( rx_clk         ),
  .valid_o          ( phy_data_valid )
);

// Checks ECC in packet header
csi2_hamming_dec header_corrector (
  .clk_i             ( rx_clk                   ),
  .rst_i             ( clk_loss_rst             ),
  .valid_i           ( phy_data_valid           ),
  .data_i            ( phy_data                 ),
  .pkt_done_i        ( phy_rst                  ),
  .error_o           ( header_error             ),
  .error_corrected_o ( header_error_corrected   ),
  .header_valid_o    ( header_valid             ),
  .data_o            ( corrected_phy_data       ),
  .valid_o           ( corrected_phy_data_valid )
);

// Also generate reset PHY signal
csi2_to_axi4_stream axi4_conv (
  .clk_i     ( rx_clk                   ),
  .rst_i     ( clk_loss_rst             ),
  .enable_i  ( enable_i                 ),
  .data_i    ( corrected_phy_data       ),
  .valid_i   ( corrected_phy_data_valid ),
  .error_i   ( pkt_error                ),
  .phy_rst_o ( phy_rst                  ),
  .pkt_o     ( csi2_pkt_rx_clk_if       )
);

assign pkt_word_rx_clk.tdata     = csi2_pkt_rx_clk_if.tdata;
assign pkt_word_rx_clk.tstrb     = csi2_pkt_rx_clk_if.tstrb;
assign pkt_word_rx_clk.tlast     = csi2_pkt_rx_clk_if.tlast;

// Long packet payload crc calculation
csi2_crc_calc crc_calc (
  .clk_i        ( rx_clk             ),
  .rst_i        ( clk_loss_rst       ),
  .csi2_pkt_i   ( csi2_pkt_rx_clk_if ),
  .crc_passed_o ( crc_passed         ),
  .crc_failed_o ( crc_failed         )
);

// CDC from rx_clk to px_clk
dc_fifo #(
  .DATA_WIDTH      ( 37                        ),
  .WORDS_AMOUNT    ( 256                       )
) dphy_int_cdc (
  .wr_clk_i        ( rx_clk                    ),
  .wr_data_i       ( pkt_word_rx_clk           ),
  .wr_i            ( csi2_pkt_rx_clk_if.tvalid ),
  .wr_used_words_o (                           ),
  .wr_full_o       (                           ),
  .wr_empty_o      (                           ),
  .rd_clk_i        ( px_clk_i                  ),
  .rd_data_o       ( pkt_word_px_clk           ),
  .rd_i            ( csi2_pkt_px_clk_if.tready ),
  .rd_used_words_o (                           ),
  .rd_full_o       (                           ),
  .rd_empty_o      ( rx_px_cdc_empty           ),
  .rst_i           ( px_rst_i                  )
);

assign csi2_pkt_px_clk_if.tdata  = pkt_word_px_clk.tdata;
assign csi2_pkt_px_clk_if.tstrb  = pkt_word_px_clk.tstrb;
assign csi2_pkt_px_clk_if.tlast  = pkt_word_px_clk.tlast;
assign csi2_pkt_px_clk_if.tvalid = !rx_px_cdc_empty;

// Module let only long packets through and
// detects frame start short packets
csi2_pkt_handler payload_extractor
(
  .clk_i         ( px_clk_i           ),
  .rst_i         ( px_rst_i           ),
  .pkt_i         ( csi2_pkt_px_clk_if ),
  .frame_start_o ( frame_start_pkt    ),
  .frame_end_o   (                    ),
  .pkt_o         ( payload_if         )
);

// Mapper from 32b to 42b
csi2_raw10_32b_40b_gbx gbx
(
  .clk_i ( px_clk_i       ),
  .rst_i ( px_rst_i       ),
  .pkt_i ( payload_if     ),
  .pkt_o ( payload_40b_if )
);

// 40b to 10b serializer
csi2_px_serializer px_ser
(
  .clk_i         ( px_clk_i        ),
  .rst_i         ( px_rst_i        ),
  .frame_start_i ( frame_start_pkt ),
  .pkt_i         ( payload_40b_if  ),
  .pkt_o         ( video_o         )
);

endmodule
