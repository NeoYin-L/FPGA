// ============================================================================
// button_debounce.sv
// Bo chong doi phim nhan da nang - dung chung cho nut bat/tat che do test
// joystick VA nut nhan cua Encoder EC11 (module sau).
//
// Dau vao tu GPIO chua qua dong bo/chua loc doi -> qua 2 tang FF dong bo
// (tranh metastability tu tin hieu ngoai khong dong bo voi clk), roi loc
// doi bang bo dem on dinh: chi khi muc tin hieu GIU NGUYEN lien tuc
// DEBOUNCE_CYCLES chu ky moi duoc coi la hop le va cap nhat level_clean.
//
// ACTIVE_LOW=1 (mac dinh, khop voi so do EC11/nut nhan: keo len 3.3V qua
// dien tro, nhan xuong GND=0) -> level_clean=1 nghia la "DANG NHAN" (da
// quy doi ve dang muc cao = nhan, bat ke phan cung active_low hay high).
// ============================================================================
module button_debounce #(
    parameter int DEBOUNCE_CYCLES = 200_000,  // vd ~7.4ms @27MHz - CAN CHINH theo do doi thuc te cua nut
    parameter bit ACTIVE_LOW      = 1'b1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic btn_raw,        // truc tiep tu chan GPIO

    output logic level_clean,    // muc da loc doi, 1=dang nhan
    output logic press_pulse     // xung 1 chu ky khi VUA chuyen sang "dang nhan"
);
    logic btn_sync1, btn_sync2;
    logic pressed_raw;
    logic [31:0] stable_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            btn_sync1 <= 1'b0;
            btn_sync2 <= 1'b0;
        end else begin
            btn_sync1 <= btn_raw;
            btn_sync2 <= btn_sync1;
        end
    end

    assign pressed_raw = ACTIVE_LOW ? ~btn_sync2 : btn_sync2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            level_clean <= 1'b0;
            stable_cnt  <= 32'd0;
            press_pulse <= 1'b0;
        end else begin
            press_pulse <= 1'b0;

            if (pressed_raw == level_clean) begin
                stable_cnt <= 32'd0;   // khong co thay doi dang cho - reset bo dem
            end else begin
                if (stable_cnt >= DEBOUNCE_CYCLES - 1) begin
                    level_clean <= pressed_raw;
                    stable_cnt  <= 32'd0;
                    if (pressed_raw) press_pulse <= 1'b1;  // chi bao xung khi CHUYEN SANG nhan
                end else begin
                    stable_cnt <= stable_cnt + 32'd1;
                end
            end
        end
    end
endmodule
