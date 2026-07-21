// ============================================================================
// rng_threshold_editor.sv
// Quan ly gia tri nguong canh bao Rng, dieu chinh qua Encoder EC11:
//   - Nhan SW lan 1: vao che do chinh Rng (edit_mode=1)
//   - Xoay trai/phai trong che do chinh: tang/giam Rng theo RNG_STEP
//   - Nhan SW lan 2: thoat che do chinh (edit_mode=0), gia tri Rng hien tai
//     duoc GIU NGUYEN (da "set") cho toi lan chinh tiep theo
//
// Rng duoc GIOI HAN trong [RNG_MIN, RNG_MAX] - tranh nguoi dung vo tinh
// chinh ve 0 (mat y nghia canh bao) hoac qua lon (tran so khi tinh toan
// nguong o module threshold_led.sv).
//
// step_cw lam TANG Rng, step_ccw lam GIAM Rng - CHI CO TAC DUNG khi
// edit_mode=1 (xoay khi KHONG trong che do chinh se KHONG lam gi, tranh
// thay doi Rng ngoai y muon).
// ============================================================================
module rng_threshold_editor #(
    parameter int RNG_DEFAULT = 100_000,   // Rng mac dinh luc reset (Ohm)
    parameter int RNG_STEP    = 1_000,     // buoc tang/giam moi nac xoay (Ohm)
    parameter int RNG_MIN     = 1_000,     // gioi han duoi
    parameter int RNG_MAX     = 999_000    // gioi han tren
) (
    input  logic clk,
    input  logic rst_n,

    input  logic step_cw,          // xung: xoay 1 nac tang (tu ec11_encoder.sv)
    input  logic step_ccw,         // xung: xoay 1 nac giam
    input  logic sw_press_pulse,   // xung: SW vua duoc nhan sach

    output logic        edit_mode,  // 1 = dang trong che do chinh Rng
    output logic [31:0] rng_ohm     // gia tri nguong Rng hien tai (Ohm)
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            edit_mode <= 1'b0;
            rng_ohm   <= RNG_DEFAULT[31:0];
        end else begin
            if (sw_press_pulse) begin
                edit_mode <= ~edit_mode;   // nhan SW: vao/thoat che do chinh
            end else if (edit_mode) begin
                if (step_cw) begin
                    if (rng_ohm + RNG_STEP[31:0] > RNG_MAX[31:0]) begin
                        rng_ohm <= RNG_MAX[31:0];
                    end else begin
                        rng_ohm <= rng_ohm + RNG_STEP[31:0];
                    end
                end else if (step_ccw) begin
                    if (rng_ohm < RNG_MIN[31:0] + RNG_STEP[31:0]) begin
                        rng_ohm <= RNG_MIN[31:0];
                    end else begin
                        rng_ohm <= rng_ohm - RNG_STEP[31:0];
                    end
                end
            end
        end
    end
endmodule
