// ============================================================================
// insulation_monitor_top_v2.sv  -  TOP-LEVEL kien truc MOI (thay the
// insulation_monitor_top.sv cu - kien truc do quang do RC/tau da bi loai bo
// hoan toan, thay bang phuong phap do 2 lan dien ap qua ADS1115)
//
// Ghep noi:
//   relay_pulse_controller  - tu chua ads1115_driver + rtd_calculator,
//                              dieu phoi chu trinh do 2 giay, xuat Rtd
//   ec11_encoder             - giai ma xoay + nut nhan Encoder EC11
//   rng_threshold_editor      - logic chinh nguong canh bao Rng
//   threshold_led             - so sanh Rtd voi Rng, xuat 3 den canh bao
//   oled_ssd1306_display      - hien thi Uđo1, Uđo2, Rtd, Rng len OLED
//
// *** NOI DUNG HIEN THI OLED (4 dong): ***
//   edit_mode=0 (Normal):
//     Dong 1: "U1=X.XXXV"
//     Dong 2: "U2=X.XXXV"
//     Dong 3: "R=XXXXXXoh"
//     Dong 4: "Rng=XXXXXoh"
//   edit_mode=1 (Adjust Rng):
//     Dong 1: "U1=X.XXXV"  (giữ nguyên - freeze)
//     Dong 2: "U2=X.XXXV"  (giữ nguyên - freeze)
//     Dong 3: "R=XXXXXXoh" (giữ nguyên - freeze)
//     Dong 4: "Nhap Rng=XXXoh" (hien thi Rng dang chinh, co label "Nhập")
//
// *** KHI EDIT_MODE=1: relay_pulse_controller.enable=~edit_mode=0 ->
//     pause measurement, tat relay, freeze gia tri hien thi.
//     Khi thoat edit_mode: resume measurement, chu trinh moi bat dau.
// ***
// ============================================================================
module insulation_monitor_top_v2 #(
    // ---- relay_pulse_controller ----
    parameter int TWO_SEC_CYCLES     = 54_000_000,  // 2 giay @ 27MHz
    parameter int AVG_SAMPLES        = 8,
    parameter int E0_MV              = 50_000,       // *** CAN HIEU CHUAN ***
    parameter int RLM_OHM            = 100_000,
    parameter int R0_OHM             = 1_000,
    parameter logic [6:0] I2C_ADDR   = 7'h48,

    // ---- ec11_encoder ----
    parameter int DEBOUNCE_CYCLES_AB = 50_000,
    parameter int DEBOUNCE_CYCLES_SW = 200_000,

    // ---- rng_threshold_editor ----
    parameter int RNG_DEFAULT        = 100_000,
    parameter int RNG_STEP           = 1_000,
    parameter int RNG_MIN            = 1_000,
    parameter int RNG_MAX             = 999_000,

    // ---- oled_ssd1306_display ----
    parameter int SPI_CLK_DIV        = 4,
    parameter int RESET_LOW_CYCLES   = 270,
    parameter int RESET_WAIT_CYCLES  = 2700,
    parameter int COL_OFFSET         = 2
) (
    input  logic clk,       // 27MHz tu thach anh onboard Tang Nano 9K
    input  logic rst_n,     // active-low, co the noi truc tiep nut nhan

    // ---- I2C toi ADS1115 ----
    output logic scl,
    inout  wire  sda,

    // ---- Dieu khien relay ----
    output logic relay_out,

    // ---- Encoder EC11 ----
    input  logic enc_a_raw,
    input  logic enc_b_raw,
    input  logic enc_sw_raw,

    // ---- SPI toi OLED SSD1306 ----
    output logic spi_sclk,
    output logic spi_mosi,
    output logic spi_cs_n,
    output logic spi_dc,
    output logic spi_res_n,

    // ---- Den canh bao nguong (bar-graph 3 muc) ----
    output logic led1,
    output logic led2,
    output logic led3,

    // ---- Debug ----
    output logic led_heartbeat,   // nhap nhay = he thong dang chay
    output logic led_fault        // sang = phep do gan nhat bi loi (Uđo2<=Uđo1)
);
    // ------------------------------------------------------------------
    // Dong bo hoa reset (2 tang FF, tranh metastability tu nut nhan ngoai)
    // ------------------------------------------------------------------
    logic rst_sync_ff1, rst_n_sync;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_sync_ff1 <= 1'b0;
            rst_n_sync   <= 1'b0;
        end else begin
            rst_sync_ff1 <= 1'b1;
            rst_n_sync   <= rst_sync_ff1;
        end
    end

    // ------------------------------------------------------------------
    // Tri-state SDA (I2C mo-drain that su tai chan IO)
    // ------------------------------------------------------------------
    logic sda_oe, sda_in;
    assign sda    = sda_oe ? 1'b0 : 1'bz;
    assign sda_in = sda;

    // ------------------------------------------------------------------
    // Module 1: relay_pulse_controller (tu chua ADS1115 + Rtd calculator)
    // ------------------------------------------------------------------
    logic [31:0]        rtd_ohm;
    logic signed [15:0] udo1_mv, udo2_mv;
    logic                result_valid;
    logic                measure_fault;

    relay_pulse_controller #(
        .TWO_SEC_CYCLES (TWO_SEC_CYCLES),
        .AVG_SAMPLES    (AVG_SAMPLES),
        .E0_MV          (E0_MV),
        .RLM_OHM        (RLM_OHM),
        .R0_OHM         (R0_OHM),
        .I2C_ADDR       (I2C_ADDR)
    ) u_relay (
        .clk          (clk),
        .rst_n        (rst_n_sync),
        .enable       (~edit_mode),       // *** SUA: pause measurement khi edit Rng ***
        .scl          (scl),
        .sda_oe       (sda_oe),
        .sda_in       (sda_in),
        .relay_out    (relay_out),
        .rtd_ohm      (rtd_ohm),
        .udo1_mv      (udo1_mv),
        .udo2_mv      (udo2_mv),
        .result_valid (result_valid),
        .fault        (measure_fault)
    );

    // ------------------------------------------------------------------
    // Module 2: EC11 Encoder
    // ------------------------------------------------------------------
    logic step_cw, step_ccw, sw_press_pulse;

    ec11_encoder #(
        .DEBOUNCE_CYCLES_AB (DEBOUNCE_CYCLES_AB),
        .DEBOUNCE_CYCLES_SW (DEBOUNCE_CYCLES_SW)
    ) u_encoder (
        .clk            (clk),
        .rst_n          (rst_n_sync),
        .a_raw          (enc_a_raw),
        .b_raw          (enc_b_raw),
        .sw_raw         (enc_sw_raw),
        .step_cw        (step_cw),
        .step_ccw       (step_ccw),
        .sw_press_pulse (sw_press_pulse)
    );

    // ------------------------------------------------------------------
    // Module 3: Rng Threshold Editor
    // ------------------------------------------------------------------
    logic        edit_mode;
    logic [31:0] rng_ohm;

    rng_threshold_editor #(
        .RNG_DEFAULT (RNG_DEFAULT),
        .RNG_STEP    (RNG_STEP),
        .RNG_MIN     (RNG_MIN),
        .RNG_MAX     (RNG_MAX)
    ) u_rng_editor (
        .clk            (clk),
        .rst_n          (rst_n_sync),
        .step_cw        (step_cw),
        .step_ccw       (step_ccw),
        .sw_press_pulse (sw_press_pulse),
        .edit_mode      (edit_mode),
        .rng_ohm        (rng_ohm)
    );

    // ------------------------------------------------------------------
    // Module 4: Threshold LED (1 instance - chi 1 Rtd duy nhat)
    // ------------------------------------------------------------------
    threshold_led u_led (
        .rtd_ohm (rtd_ohm),
        .rng_ohm (rng_ohm),
        .led1    (led1),
        .led2    (led2),
        .led3    (led3)
    );

    // ------------------------------------------------------------------
    // Module 5: OLED SSD1306 Display
    // ------------------------------------------------------------------
    oled_ssd1306_display #(
        .SPI_CLK_DIV       (SPI_CLK_DIV),
        .RESET_LOW_CYCLES  (RESET_LOW_CYCLES),
        .RESET_WAIT_CYCLES (RESET_WAIT_CYCLES),
        .COL_OFFSET        (COL_OFFSET)
    ) u_oled (
        .clk        (clk),
        .rst_n      (rst_n_sync),
        .u1_mv      (udo1_mv),
        .u2_mv      (udo2_mv),
        .rtd_ohm    (rtd_ohm),
        .rng_ohm    (rng_ohm),       // *** MO RONG: gui Rng cho OLED ***
        .edit_mode  (edit_mode),     // *** MO RONG: gui trang thai edit ***
        .data_valid (result_valid),
        .spi_sclk   (spi_sclk),
        .spi_mosi   (spi_mosi),
        .spi_cs_n   (spi_cs_n),
        .spi_dc     (spi_dc),
        .spi_res_n  (spi_res_n)
    );

    // ------------------------------------------------------------------
    // Debug LED
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) led_heartbeat <= 1'b0;
        else if (result_valid) led_heartbeat <= ~led_heartbeat;
    end

    always_ff @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)        led_fault <= 1'b0;
        else if (result_valid)  led_fault <= measure_fault;
    end

endmodule
