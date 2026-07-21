// ============================================================================
// ec11_encoder.sv
// Giao dien Encoder EC11: giai ma huong xoay tu 2 kenh A/B (quadrature) va
// phat hien nhan nut SW (nhan sach, da chong doi) - dung lai module
// button_debounce.sv cho CA 3 chan (A, B, SW) de dam bao chong doi dong
// nhat va tan dung code da kiem thu.
//
// GIAI MA HUONG QUAY: dung phuong phap don gian pho bien cho encoder co
// nac (detent) - moi nac xoay tao 1 canh xuong DUY NHAT tren kenh A (tu
// muc nghi cao ve thap); tai dung thoi diem do, MUC cua kenh B cho biet
// chieu xoay:
//   - B con o muc nghi (chua tich cuc) luc A xuong -> 1 chieu (goi la CW)
//   - B da o muc tich cuc luc A xuong               -> chieu con lai (CCW)
//
// *** LUU Y: chieu CW/CCW o day chi la QUY UOC dat ten - chieu THAT TREN
//     PHAN CUNG phu thuoc cach dau day A/B vao PMOD, co the nguoc lai so
//     voi ky vong. Neu xoay nguoc chieu mong muon khi thu tren board that,
//     CHI CAN DOI CHO 2 gan step_cw/step_ccw o cuoi file nay, khong can
//     sua lai logic giai ma. ***
// ============================================================================
module ec11_encoder #(
    parameter int DEBOUNCE_CYCLES_AB = 50_000,   // chong doi co khi cho A/B
    parameter int DEBOUNCE_CYCLES_SW = 200_000   // chong doi cho nut nhan SW
) (
    input  logic clk,
    input  logic rst_n,

    input  logic a_raw,    // tu GPIO, active-low (keo len 3.3V qua R52)
    input  logic b_raw,    // tu GPIO, active-low (keo len 3.3V qua R55)
    input  logic sw_raw,   // tu GPIO, active-low (keo len 3.3V qua R45)

    output logic step_cw,        // xung 1 chu ky: xoay 1 nac - chieu tang (quy uoc)
    output logic step_ccw,       // xung 1 chu ky: xoay 1 nac - chieu giam (quy uoc)
    output logic sw_press_pulse  // xung 1 chu ky: SW vua duoc nhan sach
);
    logic a_clean, b_clean;
    logic sw_press_internal;

    button_debounce #(
        .DEBOUNCE_CYCLES (DEBOUNCE_CYCLES_AB),
        .ACTIVE_LOW      (1'b1)
    ) u_debounce_a (
        .clk         (clk),
        .rst_n       (rst_n),
        .btn_raw     (a_raw),
        .level_clean (a_clean),
        .press_pulse ()   // khong dung - chi can muc on dinh cho giai ma huong
    );

    button_debounce #(
        .DEBOUNCE_CYCLES (DEBOUNCE_CYCLES_AB),
        .ACTIVE_LOW      (1'b1)
    ) u_debounce_b (
        .clk         (clk),
        .rst_n       (rst_n),
        .btn_raw     (b_raw),
        .level_clean (b_clean),
        .press_pulse ()
    );

    button_debounce #(
        .DEBOUNCE_CYCLES (DEBOUNCE_CYCLES_SW),
        .ACTIVE_LOW      (1'b1)
    ) u_debounce_sw (
        .clk         (clk),
        .rst_n       (rst_n),
        .btn_raw     (sw_raw),
        .level_clean (),
        .press_pulse (sw_press_internal)
    );

    assign sw_press_pulse = sw_press_internal;

    // ------------------------------------------------------------------
    // Phat hien canh len cua a_clean (= canh XUONG cua tin hieu A vat ly,
    // vi button_debounce da quy doi active-low -> "1"=tich cuc)
    // ------------------------------------------------------------------
    logic a_clean_prev;
    logic a_falling_physical;   // = a_clean vua chuyen 0->1

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_clean_prev <= 1'b0;
            step_cw      <= 1'b0;
            step_ccw     <= 1'b0;
        end else begin
            step_cw  <= 1'b0;
            step_ccw <= 1'b0;

            a_clean_prev <= a_clean;
            if (a_clean && !a_clean_prev) begin
                // A vua "xuong" (active) - doc B TAI THOI DIEM NAY de xac dinh chieu
                if (!b_clean) begin
                    step_cw <= 1'b1;    // B con nghi -> quy uoc chieu tang
                end else begin
                    step_ccw <= 1'b1;   // B da tich cuc -> quy uoc chieu giam
                end
            end
        end
    end

endmodule
