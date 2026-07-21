// ============================================================================
// bin2bcd.sv
// Chuyen nhi phan sang BCD bang giai thuat "double dabble" (shift-add-3):
// moi chu ky dich trai 1 bit, TRUOC do neu nibble BCD nao >=5 thi cong them
// 3 (de "trang thai" 4-bit luon nam dung trong dai 0-9 sau khi dich). Sau
// BIN_WIDTH chu ky, cac nibble BCD chua ket qua dung.
//
// BIN_WIDTH=32, NUM_DIGITS=10 (toi da 9,999,999,999) - PHU cho toan bo dai
// gia tri unsigned 32-bit (max 4,294,967,295), khong can bat ky logic gioi
// han/clamp nao truoc khi dua vao - dung 1 THIET KE DUY NHAT cho ca 3 gia
// tri can hien thi (Uđo1, Uđo2 dang mV; Rtd dang Ohm), don gian hoa thiet ke
// vi Tang Nano 9K du tai nguyen LUT (moi gia tri dung 1 instance rieng thay
// vi dung chung 1 instance time-multiplexed - don gian hoa dieu khien, doi
// lay vai tram LUT4 khong dang ke).
// ============================================================================
module bin2bcd #(
    parameter int BIN_WIDTH  = 32,
    parameter int NUM_DIGITS = 10
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        start,
    input  logic [BIN_WIDTH-1:0]        bin_in,

    output logic                        busy,
    output logic                        done,
    output logic [NUM_DIGITS*4-1:0]     bcd_out   // moi nibble 1 chu so, LSD o bit [3:0]
);
    typedef enum logic [1:0] {S_IDLE, S_SHIFT, S_DONE} state_e;
    state_e state;

    logic [NUM_DIGITS*4-1:0] bcd_reg;
    logic [BIN_WIDTH-1:0]    bin_reg;
    logic [$clog2(BIN_WIDTH+1)-1:0] iter_cnt;

    logic [NUM_DIGITS*4-1:0] bcd_adj;

    // Dieu chinh "cong 3 neu >=5" cho TUNG nibble, TRUOC khi dich - thuc hien
    // to hop, ap dung dong thoi cho tat ca NUM_DIGITS nibble.
    always_comb begin
        for (int i = 0; i < NUM_DIGITS; i++) begin
            logic [3:0] nib;
            nib = bcd_reg[i*4 +: 4];
            bcd_adj[i*4 +: 4] = (nib >= 4'd5) ? (nib + 4'd3) : nib;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            bcd_reg  <= '0;
            bin_reg  <= '0;
            iter_cnt <= '0;
            busy     <= 1'b0;
            done     <= 1'b0;
            bcd_out  <= '0;
        end else begin
            done <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    if (start) begin
                        bcd_reg  <= '0;
                        bin_reg  <= bin_in;
                        iter_cnt <= '0;
                        busy     <= 1'b1;
                        state    <= S_SHIFT;
                    end else begin
                        busy <= 1'b0;
                    end
                end

                S_SHIFT: begin
                    // Dich trai ca cap {bcd_adj, bin_reg} 1 bit (bit MSB cua
                    // bin_reg day vao LSB cua bcd_adj)
                    bcd_reg <= {bcd_adj[NUM_DIGITS*4-2:0], bin_reg[BIN_WIDTH-1]};
                    bin_reg <= {bin_reg[BIN_WIDTH-2:0], 1'b0};
                    if (iter_cnt == BIN_WIDTH - 1) begin
                        state <= S_DONE;
                    end else begin
                        iter_cnt <= iter_cnt + 1'b1;
                    end
                end

                S_DONE: begin
                    bcd_out <= bcd_reg;
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    state   <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
