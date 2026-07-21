// ============================================================================
// relay_pulse_controller.sv  -  Bo dieu phoi chu trinh do 2 giay
//
// *** DA XAC NHAN (xem hoi thoai): mach khuech dai vi sai (Hinh 4-6,
// MCP6001/2/4) da thuc hien phep tru VIN2-VIN1 bang analog TRUOC KHI tin
// hieu den ADS1115. J23-pin1 va J30-pin1 duoc noi CHUNG VOI NHAU (cung 1
// day Vout), nen AIN2 va AIN3 luon doc ra CUNG 1 gia tri - khong phai 2
// kenh doc lap. Vi vay FPGA CHI CAN DOC 1 KENH DUY NHAT (AIN2), KHONG can
// tinh hieu so giua 2 kenh nua. ***
//
// Trinh tu:
//   1. Doc kenh do (AIN2) TRUOC khi bat relay -> Uđo1 (trung binh AVG_SAMPLES mau)
//   2. Bat relay (relay_out=1), giu trong TWO_SEC_CYCLES chu ky (~2 giay)
//   3. Cuoi khoang giu (relay VAN DANG BAT), doc lai kenh do -> Uđo2
//   4. Tat relay (relay_out=0)
//   5. Tinh Rtd (1 KET QUA DUY NHAT) tu Uđo1, Uđo2
//   6. Bao result_valid, quay lai buoc 1
//
// BO LOC: moi lan doc kenh do lay trung binh AVG_SAMPLES mau ADS1115
// lien tiep (mac dinh 8, PHAI la luy thua cua 2) de giam nhieu gon AC tu
// mang 3 pha chong len tin hieu DC.
//
// Module TU CHUA ca ads1115_driver VA rtd_calculator (day la module DUY
// NHAT trong he thong chinh can dieu khien ADS1115).
//
// AN TOAN: neu `enable` chuyen ve 0 giua chung chu trinh, module LAP TUC
// TAT RELAY va quay ve idle.
// ============================================================================
module relay_pulse_controller #(
    parameter int TWO_SEC_CYCLES = 54_000_000,   // 2 giay @ 27MHz
    parameter int AVG_SAMPLES    = 8,             // so mau loc trung binh - PHAI la luy thua cua 2
    parameter int E0_MV          = 50_000,        // *** CAN HIEU CHUAN - xem rtd_calculator.sv ***
    parameter int RLM_OHM        = 100_000,
    parameter int R0_OHM         = 1_000,
    parameter logic [6:0] I2C_ADDR = 7'h48        // dia chi ADS1115 - CAN XAC NHAN
) (
    input  logic clk,
    input  logic rst_n,
    input  logic enable,     // 1 = chay chu trinh do; 0 = tam dung, tat relay

    // ---- I2C toi ADS1115 ----
    output logic scl,
    output logic sda_oe,
    input  logic sda_in,

    output logic relay_out,

    output logic [31:0]        rtd_ohm,        // Rtd - 1 KET QUA DUY NHAT
    output logic signed [15:0] udo1_mv,        // gia tri do duoc, truoc relay
    output logic signed [15:0] udo2_mv,        // gia tri do duoc, trong luc relay bat
    output logic                result_valid,   // xung: co ket qua moi
    output logic                fault
);
    localparam logic [1:0] CH_MEASURE = 2'd0;   // AIN2 - kenh do duy nhat
                                                  // (AIN3 khong con can doc, vi
                                                  //  J23-pin1/J30-pin1 da noi
                                                  //  chung, AIN2=AIN3 luon)
    localparam int LOG2_AVG = $clog2(AVG_SAMPLES);

    // ------------------------------------------------------------------
    // ADS1115 driver (tu chua i2c_master ben trong)
    // ------------------------------------------------------------------
    logic        ads_start;
    logic [1:0]  ads_channel_sel;
    logic        ads_busy, ads_done, ads_fault;
    logic signed [15:0] ads_result;

    ads1115_driver #(
        .I2C_ADDR (I2C_ADDR)
    ) u_ads (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (ads_start),
        .channel_sel (ads_channel_sel),
        .busy        (ads_busy),
        .done        (ads_done),
        .result      (ads_result),
        .i2c_fault   (ads_fault),
        .scl         (scl),
        .sda_oe      (sda_oe),
        .sda_in      (sda_in)
    );

    // ------------------------------------------------------------------
    // rtd_calculator (1 instance, 1 ket qua duy nhat)
    // ------------------------------------------------------------------
    logic                rtd_start;
    logic signed [15:0]  rtd_udo1_mv, rtd_udo2_mv;
    logic                rtd_busy, rtd_done, rtd_fault;
    logic [31:0]         rtd_result;

    rtd_calculator #(
        .E0_MV   (E0_MV),
        .RLM_OHM (RLM_OHM),
        .R0_OHM  (R0_OHM)
    ) u_rtd (
        .clk      (clk),
        .rst_n    (rst_n),
        .udo1_mv  (rtd_udo1_mv),
        .udo2_mv  (rtd_udo2_mv),
        .start    (rtd_start),
        .busy     (rtd_busy),
        .done     (rtd_done),
        .rtd_ohm  (rtd_result),
        .fault    (rtd_fault)
    );

    // ------------------------------------------------------------------
    // FSM chinh
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,
        S_UDO1_SAMPLE, S_UDO1_AVG,
        S_WAIT_2SEC,
        S_UDO2_SAMPLE, S_UDO2_AVG,
        S_CALC_START, S_CALC_WAIT
    } state_e;
    state_e state;

    logic [31:0] timer_cnt;
    logic [$clog2(AVG_SAMPLES+1)-1:0] sample_cnt;
    logic signed [31:0] sample_sum;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            timer_cnt       <= 32'd0;
            sample_cnt      <= '0;
            sample_sum      <= 32'sd0;
            ads_start       <= 1'b0;
            ads_channel_sel <= CH_MEASURE;
            relay_out       <= 1'b0;
            rtd_start       <= 1'b0;
            rtd_udo1_mv     <= 16'sd0;
            rtd_udo2_mv     <= 16'sd0;
            udo1_mv         <= 16'sd0;
            udo2_mv         <= 16'sd0;
            rtd_ohm         <= 32'd0;
            fault           <= 1'b0;
            result_valid    <= 1'b0;
        end else begin
            ads_start    <= 1'b0;
            rtd_start    <= 1'b0;
            result_valid <= 1'b0;

            if (!enable) begin
                relay_out  <= 1'b0;
                state      <= S_IDLE;
                timer_cnt  <= 32'd0;
                sample_cnt <= '0;
                sample_sum <= 32'sd0;
            end else begin
                unique case (state)
                    S_IDLE: begin
                        ads_channel_sel <= CH_MEASURE;
                        sample_sum      <= 32'sd0;
                        sample_cnt      <= '0;
                        ads_start       <= 1'b1;
                        state           <= S_UDO1_SAMPLE;
                    end

                    // ---- Kenh do, truoc relay -> Uđo1 ----
                    S_UDO1_SAMPLE: if (ads_done) begin
                        sample_sum <= sample_sum + $signed({{16{ads_result[15]}}, ads_result});
                        if (sample_cnt == AVG_SAMPLES-1) begin
                            state <= S_UDO1_AVG;
                        end else begin
                            sample_cnt <= sample_cnt + 1'b1;
                            ads_start  <= 1'b1;
                        end
                    end
                    S_UDO1_AVG: begin
                        udo1_mv   <= (sample_sum >>> LOG2_AVG) >>> 3;  // -> mV (PGA=+-4.096V, LSB=0.125mV)
                        relay_out <= 1'b1;
                        timer_cnt <= 32'd0;
                        state     <= S_WAIT_2SEC;
                    end

                    S_WAIT_2SEC: begin
                        if (timer_cnt >= TWO_SEC_CYCLES - 1) begin
                            ads_channel_sel <= CH_MEASURE;
                            sample_sum      <= 32'sd0;
                            sample_cnt      <= '0;
                            ads_start       <= 1'b1;
                            state           <= S_UDO2_SAMPLE;
                        end else begin
                            timer_cnt <= timer_cnt + 32'd1;
                        end
                    end

                    // ---- Kenh do, trong luc relay BAT -> Uđo2 ----
                    S_UDO2_SAMPLE: if (ads_done) begin
                        sample_sum <= sample_sum + $signed({{16{ads_result[15]}}, ads_result});
                        if (sample_cnt == AVG_SAMPLES-1) begin
                            state <= S_UDO2_AVG;
                        end else begin
                            sample_cnt <= sample_cnt + 1'b1;
                            ads_start  <= 1'b1;
                        end
                    end
                    S_UDO2_AVG: begin
                        udo2_mv   <= (sample_sum >>> LOG2_AVG) >>> 3;  // -> mV
                        relay_out <= 1'b0;   // TAT relay SAU KHI da doc xong
                        state     <= S_CALC_START;
                    end

                    S_CALC_START: begin
                        rtd_udo1_mv <= udo1_mv;
                        rtd_udo2_mv <= udo2_mv;
                        rtd_start   <= 1'b1;
                        state       <= S_CALC_WAIT;
                    end
                    S_CALC_WAIT: if (rtd_done) begin
                        rtd_ohm      <= rtd_result;
                        fault        <= rtd_fault;
                        result_valid <= 1'b1;
                        state        <= S_IDLE;
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
