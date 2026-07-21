// ============================================================================
// oled_ssd1306_display.sv  -  Dieu khien man OLED 0.96" SSD1306 qua SPI
//
// Chuc nang: hien thi Uđo1, Uđo2 (mV, co dau), Rtd (Ohm) va Rng (Ohm) len 4
// dong van ban tren man 128x64. Dinh dang:
//   Dong 1: "U1=" [dau] X.XXX "V"   (vd "U1=1.523V")
//   Dong 2: "U2=" [dau] X.XXX "V"
//   Dong 3: "R="  XXXXXX "oh"        (vd "R=120002oh")
//   Dong 4: "Rng=" XXXXX "oh"        (vd "Rng=100000oh")
//            hoac "Nhap Rng=" XXX "oh" khi edit_mode=1
//
// *** GHI CHU THIET KE ***
// - Font 5x7 chi ho tro tap ky tu can thiet (xem font5x7_rom.sv).
// - Rtd/Rng hien thi CO SO 0 O DAU - don gian hoa thiet ke.
// - KHONG dung framebuffer BRAM day du: vi 4 dong van ban CO VI TRI CO DINH,
//   gia tri diem anh duoc TINH TO HOP truc tiep tu line_text + ROM font
//   ngay trong luc dang truyen SPI.
// - Chuyen doi BCD + van ban + quet SPI la TUAN TU trong CUNG 1 FSM.
// - CS giu THAP LIEN TUC (chi 1 slave SPI, ko tranh chap bus).
// - Trinh tu khoi tao la trinh tu CHUAN cua SSD1306 (datasheet).
// ============================================================================
module oled_ssd1306_display #(
    parameter int SPI_CLK_DIV       = 4,
    parameter int RESET_LOW_CYCLES  = 270,    // ~10us @27MHz
    parameter int RESET_WAIT_CYCLES = 2700,   // ~100us @27MHz
    parameter int COL_OFFSET        = 2
) (
    input  logic clk,
    input  logic rst_n,

    input  logic signed [15:0] u1_mv,
    input  logic signed [15:0] u2_mv,
    input  logic [31:0]        rtd_ohm,
    input  logic [31:0]        rng_ohm,     // *** MO RONG: nhap gia tri Rng ***
    input  logic               edit_mode,    // *** MO RONG: trang thai chinh Rng ***
    input  logic               data_valid,

    output logic spi_sclk,
    output logic spi_mosi,
    output logic spi_cs_n,
    output logic spi_dc,
    output logic spi_res_n
);
    localparam int LINE_CHARS = 16;

    // Byte lenh dat dia chi cot bat dau, da CONG BU COL_OFFSET
    localparam logic [7:0] COL_LOW_CMD  = 8'h00 | (8'(COL_OFFSET) & 8'h0F);
    localparam logic [7:0] COL_HIGH_CMD = 8'h10 | ((8'(COL_OFFSET) >> 4) & 8'h07);
    localparam int NUM_PAGES  = 8;

    // ------------------------------------------------------------------
    // Loi SPI dung chung
    // ------------------------------------------------------------------
    logic       spi_start, spi_busy, spi_done;
    logic [7:0] spi_tx_byte;

    spi_oled_tx #(.CLK_DIV(SPI_CLK_DIV)) u_spi (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (spi_start),
        .tx_byte (spi_tx_byte),
        .busy    (spi_busy),
        .done    (spi_done),
        .sclk    (spi_sclk),
        .mosi    (spi_mosi)
    );

    // ------------------------------------------------------------------
    // 4 bo chuyen doi BCD rieng (them BCD cho Rng)
    // ------------------------------------------------------------------
    logic        bcd_start;
    logic        bcd_u1_done, bcd_u2_done, bcd_rtd_done, bcd_rng_done;
    logic [39:0] bcd_u1_out, bcd_u2_out, bcd_rtd_out, bcd_rng_out;

    logic signed [15:0] u1_latched, u2_latched;
    logic               sign_u1, sign_u2;
    logic [31:0]        mag_u1_32, mag_u2_32;
    logic [31:0]        rtd_latched, rng_latched;

    assign sign_u1   = u1_latched[15];
    assign sign_u2   = u2_latched[15];
    assign mag_u1_32 = {16'b0, (sign_u1 ? (-u1_latched) : u1_latched)};
    assign mag_u2_32 = {16'b0, (sign_u2 ? (-u2_latched) : u2_latched)};

    bin2bcd #(.BIN_WIDTH(32), .NUM_DIGITS(10)) u_bcd_u1 (
        .clk(clk), .rst_n(rst_n), .start(bcd_start), .bin_in(mag_u1_32),
        .busy(), .done(bcd_u1_done), .bcd_out(bcd_u1_out)
    );
    bin2bcd #(.BIN_WIDTH(32), .NUM_DIGITS(10)) u_bcd_u2 (
        .clk(clk), .rst_n(rst_n), .start(bcd_start), .bin_in(mag_u2_32),
        .busy(), .done(bcd_u2_done), .bcd_out(bcd_u2_out)
    );
    bin2bcd #(.BIN_WIDTH(32), .NUM_DIGITS(10)) u_bcd_rtd (
        .clk(clk), .rst_n(rst_n), .start(bcd_start), .bin_in(rtd_latched),
        .busy(), .done(bcd_rtd_done), .bcd_out(bcd_rtd_out)
    );
    bin2bcd #(.BIN_WIDTH(32), .NUM_DIGITS(10)) u_bcd_rng (
        .clk(clk), .rst_n(rst_n), .start(bcd_start), .bin_in(rng_latched),
        .busy(), .done(bcd_rng_done), .bcd_out(bcd_rng_out)
    );

    wire bcd_all_done = bcd_u1_done && bcd_u2_done && bcd_rtd_done && bcd_rng_done;

    // ------------------------------------------------------------------
    // Bang van ban 4 dong (moi dong 16 ky tu = 128 bit)
    // Page mapping: page 0 -> line 0 (U1), page 2 -> line 1 (U2),
    //                page 4 -> line 2 (Rtd), page 6 -> line 3 (Rng)
    // ------------------------------------------------------------------
    logic [LINE_CHARS*8-1:0] line_text [4];

    function automatic logic [7:0] ascii_digit(input logic [3:0] d);
        ascii_digit = 8'h30 + {4'b0, d};
    endfunction

    function automatic logic [7:0] get_char(input logic [LINE_CHARS*8-1:0] line, input logic [4:0] idx);
        get_char = line[(LINE_CHARS-1-idx)*8 +: 8];
    endfunction

    // ------------------------------------------------------------------
    // ROM lenh khoi tao SSD1306 (trinh tu chuan, 25 byte, tat ca DC=0)
    // ------------------------------------------------------------------
    localparam int INIT_LEN = 25;
    logic [7:0] init_rom [INIT_LEN];
    initial begin
        init_rom[0]  = 8'hAE; init_rom[1]  = 8'hD5; init_rom[2]  = 8'h80;
        init_rom[3]  = 8'hA8; init_rom[4]  = 8'h3F; init_rom[5]  = 8'hD3;
        init_rom[6]  = 8'h00; init_rom[7]  = 8'h40; init_rom[8]  = 8'h8D;
        init_rom[9]  = 8'h14; init_rom[10] = 8'h20; init_rom[11] = 8'h02;
        init_rom[12] = 8'hA1; init_rom[13] = 8'hC8; init_rom[14] = 8'hDA;
        init_rom[15] = 8'h12; init_rom[16] = 8'h81; init_rom[17] = 8'hCF;
        init_rom[18] = 8'hD9; init_rom[19] = 8'hF1; init_rom[20] = 8'hDB;
        init_rom[21] = 8'h40; init_rom[22] = 8'hA4; init_rom[23] = 8'hA6;
        init_rom[24] = 8'hAF;
    end

    // ------------------------------------------------------------------
    // FSM chinh
    // ------------------------------------------------------------------
    typedef enum logic [4:0] {
        S_RESET_LOW, S_RESET_HIGH,
        S_INIT_SEND, S_INIT_WAIT,
        S_CONV_START, S_CONV_WAIT, S_COMPOSE,
        S_PAGE_CMD1, S_PAGE_CMD1_WAIT,
        S_PAGE_CMD2, S_PAGE_CMD2_WAIT,
        S_PAGE_CMD3, S_PAGE_CMD3_WAIT,
        S_PAGE_DATA, S_PAGE_DATA_WAIT,
        S_PAGE_TAIL, S_PAGE_TAIL_WAIT,
        S_PAGE_NEXT
    } state_e;
    state_e state;

    logic [31:0] cnt;
    logic [4:0]  init_idx;
    logic [3:0]  page_idx;
    logic [4:0]  char_idx;
    logic [2:0]  sub_col;
    logic [5:0]  tail_cnt;
    logic        pending_refresh;

    // ------------------------------------------------------------------
    // TO HOP: xac dinh dong van ban tuong ung voi trang hien tai
    // (page 0->line0, page 2->line1, page 4->line2, page 6->line3)
    // ------------------------------------------------------------------
    logic       page_has_text;
    logic [1:0] line_num;
    always_comb begin
        case (page_idx)
            4'd0:    begin page_has_text = 1'b1; line_num = 2'd0; end
            4'd2:    begin page_has_text = 1'b1; line_num = 2'd1; end
            4'd4:    begin page_has_text = 1'b1; line_num = 2'd2; end
            4'd6:    begin page_has_text = 1'b1; line_num = 2'd3; end
            default: begin page_has_text = 1'b0; line_num = 2'd0; end
        endcase
    end

    // ------------------------------------------------------------------
    // TO HOP: ROM font
    // ------------------------------------------------------------------
    logic [7:0] font_char_code;
    logic [7:0] font_col_data;

    assign font_char_code = page_has_text ? get_char(line_text[line_num], char_idx) : 8'h20;

    font5x7_rom u_font (
        .char_code(font_char_code),
        .col_idx(sub_col[2:0]),
        .col_data(font_col_data)
    );

    // ------------------------------------------------------------------
    // TO HOP: gia tri byte SPI can gui
    // ------------------------------------------------------------------
    always_comb begin
        unique case (state)
            S_INIT_WAIT:      spi_tx_byte = init_rom[init_idx];
            S_PAGE_CMD1_WAIT: spi_tx_byte = {4'hB, page_idx};
            S_PAGE_CMD2_WAIT: spi_tx_byte = COL_LOW_CMD;
            S_PAGE_CMD3_WAIT: spi_tx_byte = COL_HIGH_CMD;
            S_PAGE_DATA_WAIT: spi_tx_byte = (!page_has_text) ? 8'h00 :
                                             (sub_col == 3'd5) ? 8'h00 : font_col_data;
            S_PAGE_TAIL_WAIT: spi_tx_byte = 8'h00;
            default:          spi_tx_byte = 8'h00;
        endcase
    end

    // ------------------------------------------------------------------
    // FSM tuan tu
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_RESET_LOW;
            cnt             <= 32'd0;
            init_idx        <= 5'd0;
            page_idx        <= 4'd0;
            char_idx        <= 5'd0;
            sub_col         <= 3'd0;
            tail_cnt        <= 6'd0;
            spi_res_n       <= 1'b0;
            spi_cs_n        <= 1'b1;
            spi_dc          <= 1'b0;
            spi_start       <= 1'b0;
            bcd_start       <= 1'b0;
            u1_latched      <= 16'sd0;
            u2_latched      <= 16'sd0;
            rtd_latched     <= 32'd0;
            rng_latched     <= 32'd0;      // *** MO RONG: latch Rng ***
            line_text[0]    <= '0;
            line_text[1]    <= '0;
            line_text[2]    <= '0;
            line_text[3]    <= '0;         // *** MO RONG: dong thu 4 ***
            pending_refresh <= 1'b0;
        end else begin
            spi_start <= 1'b0;
            bcd_start <= 1'b0;

            if (data_valid) begin
                u1_latched      <= u1_mv;
                u2_latched      <= u2_mv;
                rtd_latched     <= rtd_ohm;
                rng_latched     <= rng_ohm;    // *** MO RONG: latch Rng ***
                pending_refresh <= 1'b1;
            end

            unique case (state)
                S_RESET_LOW: begin
                    spi_res_n <= 1'b0;
                    if (cnt >= RESET_LOW_CYCLES - 1) begin
                        cnt   <= 32'd0;
                        state <= S_RESET_HIGH;
                    end else cnt <= cnt + 32'd1;
                end
                S_RESET_HIGH: begin
                    spi_res_n <= 1'b1;
                    if (cnt >= RESET_WAIT_CYCLES - 1) begin
                        cnt      <= 32'd0;
                        init_idx <= 5'd0;
                        spi_cs_n <= 1'b0;
                        spi_dc   <= 1'b0;
                        state    <= S_INIT_SEND;
                    end else cnt <= cnt + 32'd1;
                end

                S_INIT_SEND: begin
                    spi_dc    <= 1'b0;
                    spi_start <= 1'b1;
                    state     <= S_INIT_WAIT;
                end
                S_INIT_WAIT: begin
                    if (spi_done) begin
                        if (init_idx == INIT_LEN - 1) begin
                            state <= S_CONV_START;
                        end else begin
                            init_idx <= init_idx + 5'd1;
                            state    <= S_INIT_SEND;
                        end
                    end
                end

                S_CONV_START: begin
                    bcd_start       <= 1'b1;
                    pending_refresh <= 1'b0;
                    state           <= S_CONV_WAIT;
                end
                S_CONV_WAIT: if (bcd_all_done) state <= S_COMPOSE;

                // ------------------------------------------------------------------
                // COMPOSE: to hop noi dung 4 dong van ban
                // ------------------------------------------------------------------
                S_COMPOSE: begin
                    // --- Line 0: U1=X.XXXV ---
                    line_text[0] <= {8'h55, 8'h31, 8'h3D,
                                      (sign_u1 ? 8'h2D : 8'h20),
                                      ascii_digit(bcd_u1_out[15:12]), 8'h2E,
                                      ascii_digit(bcd_u1_out[11:8]),
                                      ascii_digit(bcd_u1_out[7:4]),
                                      ascii_digit(bcd_u1_out[3:0]),
                                      8'h56,
                                      8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20};

                    // --- Line 1: U2=X.XXXV ---
                    line_text[1] <= {8'h55, 8'h32, 8'h3D,
                                      (sign_u2 ? 8'h2D : 8'h20),
                                      ascii_digit(bcd_u2_out[15:12]), 8'h2E,
                                      ascii_digit(bcd_u2_out[11:8]),
                                      ascii_digit(bcd_u2_out[7:4]),
                                      ascii_digit(bcd_u2_out[3:0]),
                                      8'h56,
                                      8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20};

                    // --- Line 2: R=XXXXXXoh ---
                    line_text[2] <= {8'h52, 8'h3D,
                                      ascii_digit(bcd_rtd_out[23:20]),
                                      ascii_digit(bcd_rtd_out[19:16]),
                                      ascii_digit(bcd_rtd_out[15:12]),
                                      ascii_digit(bcd_rtd_out[11:8]),
                                      ascii_digit(bcd_rtd_out[7:4]),
                                      ascii_digit(bcd_rtd_out[3:0]),
                                      8'h6F, 8'h68,
                                      8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20};

                    // --- Line 3: Rng=XXXXXoh (edit_mode=0) hoac Nhap Rng=XXXoh (edit_mode=1) ---
                    if (edit_mode) begin
                        // "Nhập Rng=XXX______" = 16 ky tu
                        // N  h  a  p     R  n  g  =  XX X  _  _  _  _  _
                        line_text[3] <= {8'h4E, 8'h68, 8'h61, 8'h70, 8'h20,
                                         8'h52, 8'h6E, 8'h67, 8'h3D,
                                         ascii_digit(bcd_rng_out[23:20]),
                                         ascii_digit(bcd_rng_out[19:16]),
                                         ascii_digit(bcd_rng_out[15:12]),
                                         8'h20, 8'h20, 8'h20, 8'h20};
                    end else begin
                        // "Rng=XXXXXoh___" = 16 ky tu
                        // R  n  g  =  XX XX X  o  h  _  _  _  _  _  _
                        line_text[3] <= {8'h52, 8'h6E, 8'h67, 8'h3D,
                                         ascii_digit(bcd_rng_out[23:20]),
                                         ascii_digit(bcd_rng_out[19:16]),
                                         ascii_digit(bcd_rng_out[15:12]),
                                         ascii_digit(bcd_rng_out[11:8]),
                                         ascii_digit(bcd_rng_out[7:4]),
                                         ascii_digit(bcd_rng_out[3:0]),
                                         8'h6F, 8'h68,
                                         8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20};
                    end

                    page_idx  <= 4'd0;
                    state     <= S_PAGE_CMD1;
                end

                S_PAGE_CMD1: begin
                    spi_dc    <= 1'b0;
                    spi_start <= 1'b1;
                    state     <= S_PAGE_CMD1_WAIT;
                end
                S_PAGE_CMD1_WAIT: if (spi_done) state <= S_PAGE_CMD2;

                S_PAGE_CMD2: begin
                    spi_dc    <= 1'b0;
                    spi_start <= 1'b1;
                    state     <= S_PAGE_CMD2_WAIT;
                end
                S_PAGE_CMD2_WAIT: if (spi_done) state <= S_PAGE_CMD3;

                S_PAGE_CMD3: begin
                    spi_dc    <= 1'b0;
                    spi_start <= 1'b1;
                    char_idx  <= 5'd0;
                    sub_col   <= 3'd0;
                    state     <= S_PAGE_CMD3_WAIT;
                end
                S_PAGE_CMD3_WAIT: if (spi_done) state <= S_PAGE_DATA;

                S_PAGE_DATA: begin
                    spi_dc    <= 1'b1;
                    spi_start <= 1'b1;
                    state     <= S_PAGE_DATA_WAIT;
                end
                S_PAGE_DATA_WAIT: begin
                    if (spi_done) begin
                        if (sub_col == 3'd5) begin
                            sub_col <= 3'd0;
                            if (char_idx == LINE_CHARS - 1) begin
                                tail_cnt <= 6'd0;
                                state    <= S_PAGE_TAIL;
                            end else begin
                                char_idx <= char_idx + 5'd1;
                                state    <= S_PAGE_DATA;
                            end
                        end else begin
                            sub_col <= sub_col + 3'd1;
                            state   <= S_PAGE_DATA;
                        end
                    end
                end

                S_PAGE_TAIL: begin
                    spi_dc    <= 1'b1;
                    spi_start <= 1'b1;
                    state     <= S_PAGE_TAIL_WAIT;
                end
                S_PAGE_TAIL_WAIT: begin
                    if (spi_done) begin
                        if (tail_cnt == 6'd31) begin
                            state <= S_PAGE_NEXT;
                        end else begin
                            tail_cnt <= tail_cnt + 6'd1;
                            state    <= S_PAGE_TAIL;
                        end
                    end
                end

                S_PAGE_NEXT: begin
                    if (page_idx == NUM_PAGES - 1) begin
                        page_idx <= 4'd0;
                        state    <= pending_refresh ? S_CONV_START : S_PAGE_CMD1;
                    end else begin
                        page_idx <= page_idx + 4'd1;
                        state    <= S_PAGE_CMD1;
                    end
                end

                default: state <= S_RESET_LOW;
            endcase
        end
    end
endmodule
