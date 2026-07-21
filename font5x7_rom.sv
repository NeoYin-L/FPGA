// ============================================================================
// font5x7_rom.sv
// Bang font dang diem 5x7 (5 cot x 7 hang), chi bao gom tap ky tu CAN THIET
// cho man hinh (chu so 0-9, dau cham, dau bang, chu U/V/R/o/h/n/g/a/p/N,
// dau gach ngang, khoang trang) - khong phai bang ASCII day du, de tiet kiem
// tai nguyen va don gian hoa.
//
// Quy uoc: moi ky tu = 5 byte (5 cot, tu trai qua phai). Trong 1 byte, bit0
// = hang tren cung cua ky tu, bit6 = hang duoi cung (7 hang su dung), bit7
// luon = 0 (tao khoang cach 1 diem anh voi dong ben duoi trong cung 1 trang
// SSD1306 8-hang).
//
// Ky tu khong co trong bang duoc tra ve la khoang trang (blank) - an toan,
// khong gay loi hien thi neu vo tinh dua vao ky tu chua ho tro.
// ============================================================================
module font5x7_rom (
    input  logic [7:0] char_code,   // ma ASCII cua ky tu
    input  logic [2:0] col_idx,     // cot 0..4 trong ky tu (5 cot)
    output logic [7:0] col_data     // gia tri 1 cot (bit0=hang tren, bit6=hang duoi)
);
    logic [39:0] glyph;

    always_comb begin
        unique case (char_code)
            8'h20: glyph = {8'h00, 8'h00, 8'h00, 8'h00, 8'h00};  // ' '
            8'h2D: glyph = {8'h08, 8'h08, 8'h08, 8'h08, 8'h08};  // '-'
            8'h2E: glyph = {8'h00, 8'h60, 8'h60, 8'h00, 8'h00};  // '.'
            8'h30: glyph = {8'h3E, 8'h51, 8'h49, 8'h45, 8'h3E};  // '0'
            8'h31: glyph = {8'h00, 8'h42, 8'h7F, 8'h40, 8'h00};  // '1'
            8'h32: glyph = {8'h42, 8'h61, 8'h51, 8'h49, 8'h46};  // '2'
            8'h33: glyph = {8'h22, 8'h41, 8'h49, 8'h49, 8'h36};  // '3'
            8'h34: glyph = {8'h18, 8'h14, 8'h12, 8'h7F, 8'h10};  // '4'
            8'h35: glyph = {8'h27, 8'h45, 8'h45, 8'h45, 8'h39};  // '5'
            8'h36: glyph = {8'h3C, 8'h4A, 8'h49, 8'h49, 8'h30};  // '6'
            8'h37: glyph = {8'h01, 8'h01, 8'h79, 8'h05, 8'h03};  // '7'
            8'h38: glyph = {8'h36, 8'h49, 8'h49, 8'h49, 8'h36};  // '8'
            8'h39: glyph = {8'h06, 8'h49, 8'h49, 8'h29, 8'h1E};  // '9'
            8'h3D: glyph = {8'h14, 8'h14, 8'h14, 8'h14, 8'h14};  // '='
            8'h4E: glyph = {8'h7C, 8'h12, 8'h11, 8'h12, 8'h7C};  // 'N'
            8'h52: glyph = {8'h7F, 8'h09, 8'h19, 8'h29, 8'h46};  // 'R'
            8'h55: glyph = {8'h3F, 8'h40, 8'h40, 8'h40, 8'h3F};  // 'U'
            8'h56: glyph = {8'h1F, 8'h20, 8'h40, 8'h20, 8'h1F};  // 'V'
            8'h61: glyph = {8'h3E, 8'h48, 8'h58, 8'h48, 8'h48};  // 'a' (thap hon)
            8'h67: glyph = {8'h30, 8'h48, 8'h58, 8'h48, 8'h38};  // 'g' (thap hon)
            8'h68: glyph = {8'h7F, 8'h04, 8'h04, 8'h04, 8'h78};  // 'h'
            8'h6E: glyph = {8'h3E, 8'h48, 8'h48, 8'h48, 8'h30};  // 'n'
            8'h6F: glyph = {8'h38, 8'h44, 8'h44, 8'h44, 8'h38};  // 'o'
            8'h70: glyph = {8'h3E, 8'h48, 8'h58, 8'h48, 8'h48};  // 'p' (thap hon)
            default: glyph = {8'h00, 8'h00, 8'h00, 8'h00, 8'h00}; // khong ho tro -> khoang trang
        endcase
    end

    function automatic logic [7:0] get_col(input logic [39:0] g, input logic [2:0] idx);
        get_col = g[(4-idx)*8 +: 8];
    endfunction

    assign col_data = get_col(glyph, col_idx);
endmodule
