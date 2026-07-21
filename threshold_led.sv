// ============================================================================
// threshold_led.sv
// So sanh Rtd voi 3 muc cua nguong canh bao Rng: Rng/3, 2*Rng/3, Rng - sang
// tuong ung led1, led2, led3 (kieu "bar-graph", CAC LED DOC LAP, khong loai
// tru nhau - vd Rtd>=2Rng/3 thi CA led1 VA led2 deu sang).
//
// KHONG DUNG PHEP CHIA: thay vi tinh Rng/3 (can bo chia, VA co the lam
// tron gay sai lech nho o bien), dung PHEP NHAN CHEO tuong duong ve mat
// dai so:
//   Rtd >= Rng/3    <=>  3*Rtd >= Rng
//   Rtd >= 2*Rng/3  <=>  3*Rtd >= 2*Rng
// 3*Rtd tinh bang (Rtd<<1)+Rtd (dich trai + cong, khong can bo nhan/chia
// phan cung). Cach nay cho ket qua CHINH XAC TUYET DOI tai moi ranh gioi,
// ke ca khi Rng khong chia het cho 3 (khac voi tinh Rng/3 truoc roi so
// sanh, co the sai lech 1 don vi do lam tron so nguyen).
// ============================================================================
module threshold_led (
    input  logic [31:0] rtd_ohm,
    input  logic [31:0] rng_ohm,

    output logic led1,   // Rtd >= Rng/3
    output logic led2,   // Rtd >= 2*Rng/3
    output logic led3    // Rtd >= Rng
);
    logic [39:0] rtd_x3;   // 3*Rtd, du rong tranh tran so
    logic [39:0] rtd_x1;
    logic [39:0] rng_x1;
    logic [39:0] rng_x2;

    assign rtd_x1 = {8'b0, rtd_ohm};
    assign rtd_x3 = (rtd_x1 << 1) + rtd_x1;   // 3*Rtd
    assign rng_x1 = {8'b0, rng_ohm};
    assign rng_x2 = rng_x1 << 1;               // 2*Rng

    assign led1 = (rtd_x3 >= rng_x1);
    assign led2 = (rtd_x3 >= rng_x2);
    assign led3 = (rtd_x1 >= rng_x1);
endmodule
