// ============================================================================
// spi_oled_tx.sv
// Bo dich SPI don gian, CHI GHI (khong doc ve) danh cho man OLED SSD1306:
// SPI Mode 0 (CPOL=0,CPHA=0), MSB truoc. Module nay CHI dieu khien SCLK+MOSI
// cho 1 byte; chan CS va DC (Data/Command#) duoc DIEU KHIEN BEN NGOAI boi
// FSM cap tren (oled_ssd1306_display.sv) vi CS thuong can giu thap xuyen
// suot ca chuoi nhieu byte (vd 128 byte du lieu 1 trang), khong phai bat/tat
// tung byte rieng le - tach biet nay giup FSM cap tren linh hoat hon.
// ============================================================================
module spi_oled_tx #(
    parameter int CLK_DIV = 4   // 1 nua chu ky SCLK = CLK_DIV chu ky he thong
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       start,
    input  logic [7:0] tx_byte,

    output logic       busy,
    output logic        done,   // xung 1 chu ky khi gui xong 1 byte
    output logic        sclk,
    output logic        mosi
);
    typedef enum logic [1:0] {S_IDLE, S_BIT_LOW, S_BIT_HIGH, S_DONE} state_e;
    state_e state;

    logic [31:0] cnt;
    logic [2:0]  bit_idx;
    logic [7:0]  shift_reg;

    wire cnt_done = (cnt == CLK_DIV - 1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            cnt       <= 32'd0;
            bit_idx   <= 3'd0;
            shift_reg <= 8'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
            sclk      <= 1'b0;
            mosi      <= 1'b0;
        end else begin
            done <= 1'b0;
            cnt  <= cnt_done ? 32'd0 : (cnt + 32'd1);

            unique case (state)
                S_IDLE: begin
                    sclk <= 1'b0;
                    if (start) begin
                        shift_reg <= tx_byte;
                        bit_idx   <= 3'd7;
                        busy      <= 1'b1;
                        cnt       <= 32'd0;
                        state     <= S_BIT_LOW;
                    end else begin
                        busy <= 1'b0;
                    end
                end

                S_BIT_LOW: begin
                    sclk <= 1'b0;
                    mosi <= shift_reg[bit_idx];   // thay doi du lieu trong luc SCLK thap
                    if (cnt_done) state <= S_BIT_HIGH;
                end

                S_BIT_HIGH: begin
                    sclk <= 1'b1;                 // slave chot du lieu tren canh len
                    if (cnt_done) begin
                        if (bit_idx == 3'd0) begin
                            state <= S_DONE;
                        end else begin
                            bit_idx <= bit_idx - 3'd1;
                            state   <= S_BIT_LOW;
                        end
                    end
                end

                S_DONE: begin
                    sclk  <= 1'b0;
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
