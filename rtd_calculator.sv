// ============================================================================
// rtd_calculator.sv
// Tinh dien tro cach dien tuong duong Rtd theo cong thuc MOI (phuong phap
// do 2 lan dien ap, thay the hoan toan phuong phap qua do RC/tau truoc day):
//
//   Rtd = E0/(Udo2 - Udo1) * Rlm - (R0 + Rlm)     (Ohm)
//
// Trong do:
//   E0   : dien ap kich thich (mV) - hang so mach
//   Rlm  : dien tro mau (Ohm) - hang so mach
//   R0   : dien tro noi tiep phu (Ohm) - hang so mach
//   Udo1 : dien ap do duoc TRUOC khi dong relay (mV, tu ADS1115)
//   Udo2 : dien ap do duoc SAU KHI dong relay giu 2 giay (mV, tu ADS1115)
//
// *** QUAN TRONG - CAN HIEU CHUAN VOI PHAN CUNG THAT ***
// E0_MV, RLM_OHM, R0_OHM la CAC HANG SO VAT LY CHUA DUOC XAC NHAN. Ngoai ra,
// mach tuong tu co bo chia ap (R23=5.1k/R25=1.3k theo so do) truoc khi vao
// ADS1115 - NEU ca E0, Udo1, VA Udo2 deu di qua CUNG 1 duong suy hao nay,
// ty so E0/(Udo2-Udo1) KHONG DOI (ty le suy hao tu trieu tieu), nen co the
// dung truc tiep gia tri mV o thang do cua ADC (nhu module nay dang lam) MA
// KHONG can "hoan tac" bo chia ap - VOI DIEU KIEN E0_MV duoc THIET LAP O
// CUNG THANG DO (tuc la gia tri E0 nhu the no cung di qua bo chia ap do,
// KHONG PHAI dien ap nguon that 50V chua suy hao). Neu gia dinh nay sai
// (vd E0 khong di qua cung duong tin hieu voi Udo1/Udo2), cong thuc se cho
// ket qua sai lech theo 1 he so co dinh - CAN HIEU CHUAN THUC TE: dat 1 dien
// tro Rtd DA BIET truoc (vd 100k), chay he thong, roi dieu chinh E0_MV cho
// den khi Rtd hien thi khop voi gia tri da biet.
//
// Udo2 <= Udo1 (diff <= 0) duoc coi la KHONG HOP LE (ve mat vat ly, dong
// relay phai LAM TANG dong qua Rlm nen Udo2 phai > Udo1) - bao fault=1,
// rtd_ohm=0, khong thuc hien phep chia (tranh chia cho 0/am).
//
// Rtd am (do luong tu hoa khi cach dien gan hong) duoc CHAN VE 0, khong
// coi la loi - giong nguyen tac da dung o r_c_calculator.sv (kien truc cu).
// ============================================================================
module rtd_calculator #(
    parameter int E0_MV     = 50_000,   // *** CAN HIEU CHUAN - xem ghi chu tren ***
    parameter int RLM_OHM   = 100_000,  // *** CAN XAC NHAN ***
    parameter int R0_OHM    = 1_000,    // *** CAN XAC NHAN - dang la gia tri du kien ***
    parameter int DIV_WIDTH = 64
) (
    input  logic clk,
    input  logic rst_n,

    input  logic signed [15:0] udo1_mv,
    input  logic signed [15:0] udo2_mv,
    input  logic                start,

    output logic         busy,
    output logic         done,
    output logic [31:0]  rtd_ohm,
    output logic         fault      // 1 = Udo2<=Udo1, khong the tinh (bo qua phep do nay)
);
    // E0*Rlm co the vuot 32-bit (vd 50000*100000=5e9) - ep longint TRUOC khi
    // nhan de tranh tran so luc elaborate.
    localparam longint unsigned NUM_CONST = longint'(E0_MV) * longint'(RLM_OHM);
    localparam int OFFSET_OHM = R0_OHM + RLM_OHM;

    logic signed [DIV_WIDTH-1:0] div_num, div_den, div_quo;
    logic                        div_start, div_busy, div_done, div_dbz;

    seq_divider #(.WIDTH(DIV_WIDTH)) u_div (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (div_start),
        .numerator   (div_num),
        .denominator (div_den),
        .busy        (div_busy),
        .done        (div_done),
        .quotient    (div_quo),
        .div_by_zero (div_dbz)
    );

    typedef enum logic [1:0] {S_IDLE, S_DIV_START, S_DIV_WAIT, S_FINISH} state_e;
    state_e state;

    logic signed [31:0] diff_mv;
    logic signed [DIV_WIDTH-1:0] rtd_raw;

    assign rtd_raw = div_quo - OFFSET_OHM;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            div_start <= 1'b0;
            div_num   <= '0;
            div_den   <= '0;
            diff_mv   <= '0;
            rtd_ohm   <= 32'd0;
            fault     <= 1'b0;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            div_start <= 1'b0;
            done      <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    if (start) begin
                        busy    <= 1'b1;
                        diff_mv <= $signed({{16{udo2_mv[15]}}, udo2_mv}) -
                                   $signed({{16{udo1_mv[15]}}, udo1_mv});
                        state   <= S_DIV_START;
                    end else begin
                        busy <= 1'b0;
                    end
                end

                S_DIV_START: begin
                    if (diff_mv <= 0) begin
                        // Khong hop le ve vat ly - bo qua phep do nay
                        fault   <= 1'b1;
                        rtd_ohm <= 32'd0;
                        state   <= S_FINISH;
                    end else begin
                        fault     <= 1'b0;
                        div_num   <= NUM_CONST[DIV_WIDTH-1:0];
                        div_den   <= diff_mv;   // signed->signed, Verilog tu mo rong dau
                        div_start <= 1'b1;
                        state     <= S_DIV_WAIT;
                    end
                end

                S_DIV_WAIT: begin
                    if (div_done) begin
                        if (rtd_raw < 0) begin
                            rtd_ohm <= 32'd0;   // ket qua am - chan ve 0
                        end else begin
                            rtd_ohm <= rtd_raw[31:0];
                        end
                        state <= S_FINISH;
                    end
                end

                S_FINISH: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
