// ============================================================================
// ads1115_driver.sv
// Dieu phoi giao dich I2C (qua i2c_master.sv) de doc 1 kenh don-cuc
// (single-ended) tu ADS1115: ghi thanh ghi CONFIG chon kenh + kich hoat 1
// lan chuyen doi (single-shot), polling co bit OS (bit 15 cua CONFIG, 1 =
// da xong) cho den khi san sang, roi doc thanh ghi CONVERSION (16-bit, bu 2).
//
// Dia chi I2C mac dinh 0x48 (chan ADDR noi GND) - *** CAN XAC NHAN VOI SO DO
// PHAN CUNG THAT (chan ADDR noi dau) ***. PGA mac dinh +-4.096V (phu hop dai
// dien ap sau bo chia/dem op-amp trong so do); *** CAN XAC NHAN dai dien ap
// thuc te dua vao AIN de chon PGA phu hop, tranh bao hoa hoac mat do phan
// giai ***.
//
// channel_sel: 0=AIN0, 1=AIN1, 2=AIN2, 3=AIN3 (theo so do: AIN0/1=joystick
// X/Y qua mux chuyen mach A1..B3; AIN2=J23/U7A kenh do that 1; AIN3=J30/U7B
// kenh do that 2).
// ============================================================================
module ads1115_driver #(
    parameter logic [6:0] I2C_ADDR       = 7'h48,
    parameter int         PGA_CODE       = 3'b001,     // +-4.096V - CAN XAC NHAN
    parameter int         DATA_RATE_CODE = 3'b100,     // 128 SPS
    parameter int         POLL_WAIT_CYCLES = 27_000    // ~1ms @27MHz giua cac lan poll
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,          // xung 1 chu ky: bat dau doc 1 kenh
    input  logic [1:0]  channel_sel,    // 0..3 = AIN0..AIN3

    output logic        busy,
    output logic        done,           // xung 1 chu ky khi co ket qua
    output logic signed [15:0] result,  // ket qua bu-2, 16-bit
    output logic        i2c_fault,      // 1 = co giao dich bi NACK (loi bus/dia chi)

    // ---- Ket noi toi i2c_master (dung chung 1 instance ben ngoai module nay
    //      hoac instantiate ngay ben trong - o day INSTANTIATE BEN TRONG de
    //      module nay "tu chua", giong cach three_point_core tu chua
    //      seq_divider rieng) ----
    output logic scl,
    output logic sda_oe,
    input  logic sda_in
);
    // ------------------------------------------------------------------
    // i2c_master dung chung noi bo (time-multiplexed qua nhieu lenh)
    // ------------------------------------------------------------------
    logic       m_cmd_valid;
    logic [1:0] m_cmd;
    logic [7:0] m_tx_byte;
    logic       m_read_ack;
    logic       m_busy, m_done, m_ack_error;
    logic [7:0] m_rx_byte;

    localparam logic [1:0] CMD_START = 2'd0;
    localparam logic [1:0] CMD_WRITE = 2'd1;
    localparam logic [1:0] CMD_READ  = 2'd2;
    localparam logic [1:0] CMD_STOP  = 2'd3;

    i2c_master u_i2c (
        .clk        (clk),
        .rst_n      (rst_n),
        .cmd_valid  (m_cmd_valid),
        .cmd        (m_cmd),
        .tx_byte    (m_tx_byte),
        .read_ack   (m_read_ack),
        .busy       (m_busy),
        .done       (m_done),
        .rx_byte    (m_rx_byte),
        .ack_error  (m_ack_error),
        .scl        (scl),
        .sda_oe     (sda_oe),
        .sda_in     (sda_in)
    );

    // ------------------------------------------------------------------
    // Thanh ghi con tro ADS1115
    // ------------------------------------------------------------------
    localparam logic [7:0] REG_CONVERSION = 8'h00;
    localparam logic [7:0] REG_CONFIG     = 8'h01;

    // Byte cau hinh cho 1 lan chuyen doi single-shot tren kenh channel_sel:
    // MSB = OS(1) MUX(3) PGA(3) MODE(1) ; LSB = DR(3) COMP_MODE COMP_POL COMP_LAT COMP_QUE(2)
    logic [2:0] mux_code;
    assign mux_code = 3'b100 + {1'b0, channel_sel};  // AIN0..3 don-cuc = 100..111

    wire [7:0] config_msb = {1'b1, mux_code, PGA_CODE[2:0], 1'b1};       // OS=1(bat dau), MODE=1(single-shot)
    wire [7:0] config_lsb = {DATA_RATE_CODE[2:0], 1'b0, 1'b0, 1'b0, 2'b11}; // comparator disable (QUE=11)

    logic [15:0] result_reg;
    logic [1:0]  chan_latched;

    // ------------------------------------------------------------------
    // FSM chinh: tuan tu cac buoc giao dich I2C day du
    // ------------------------------------------------------------------
    typedef enum logic [4:0] {
        S_IDLE,
        // -- Ghi CONFIG (chon kenh + kich hoat chuyen doi) --
        S_WCFG_START, S_WCFG_ADDRW, S_WCFG_PTR, S_WCFG_MSB, S_WCFG_LSB, S_WCFG_STOP,
        // -- Poll: doc lai CONFIG (con tro da tro san vao CONFIG tu buoc
        //    ghi truoc - CHI can doc lai, KHONG can ghi lai dia chi/con tro) --
        S_POLL_WAIT,
        S_POLL_START, S_POLL_ADDRR, S_POLL_MSB, S_POLL_LSB, S_POLL_STOP,
        // -- Doc CONVERSION --
        S_RCONV_START, S_RCONV_ADDRW, S_RCONV_PTR, S_RCONV_RSTART, S_RCONV_ADDRR,
        S_RCONV_MSB, S_RCONV_LSB, S_RCONV_STOP,
        S_DONE
    } state_e;
    state_e state;

    logic [31:0] poll_cnt;
    logic [7:0]  msb_latch;

    // Tien ich: phat 1 lenh toi i2c_master va cho done (dung trong always_ff
    // bang cach chi set m_cmd_valid trong 1 chu ky roi cho m_done)
    // -> trien khai truc tiep bang FSM (khong dung task, giu phong cach dong
    // bo hoan toan nhu cac module truoc).

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            m_cmd_valid  <= 1'b0;
            m_cmd        <= CMD_START;
            m_tx_byte    <= 8'd0;
            m_read_ack   <= 1'b0;
            busy         <= 1'b0;
            done         <= 1'b0;
            result       <= 16'sd0;
            i2c_fault    <= 1'b0;
            result_reg   <= 16'd0;
            chan_latched <= 2'd0;
            poll_cnt     <= 32'd0;
            msb_latch    <= 8'd0;
        end else begin
            m_cmd_valid <= 1'b0;
            done        <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy         <= 1'b1;
                        chan_latched <= channel_sel;
                        i2c_fault    <= 1'b0;
                        m_cmd        <= CMD_START;
                        m_cmd_valid  <= 1'b1;
                        state        <= S_WCFG_START;
                    end
                end

                // ============ GHI CONFIG: chon kenh + OS=1 (bat dau chuyen doi) ============
                S_WCFG_START: if (m_done) begin
                    m_cmd       <= CMD_WRITE;
                    m_tx_byte   <= {I2C_ADDR, 1'b0};  // dia chi + W
                    m_cmd_valid <= 1'b1;
                    state       <= S_WCFG_ADDRW;
                end
                S_WCFG_ADDRW: if (m_done) begin
                    if (m_ack_error) begin
                        i2c_fault <= 1'b1; state <= S_DONE;
                    end else begin
                        m_cmd       <= CMD_WRITE;
                        m_tx_byte   <= REG_CONFIG;
                        m_cmd_valid <= 1'b1;
                        state       <= S_WCFG_PTR;
                    end
                end
                S_WCFG_PTR: if (m_done) begin
                    if (m_ack_error) begin
                        i2c_fault <= 1'b1; state <= S_DONE;
                    end else begin
                        m_cmd       <= CMD_WRITE;
                        m_tx_byte   <= config_msb;
                        m_cmd_valid <= 1'b1;
                        state       <= S_WCFG_MSB;
                    end
                end
                S_WCFG_MSB: if (m_done) begin
                    if (m_ack_error) begin
                        i2c_fault <= 1'b1; state <= S_DONE;
                    end else begin
                        m_cmd       <= CMD_WRITE;
                        m_tx_byte   <= config_lsb;
                        m_cmd_valid <= 1'b1;
                        state       <= S_WCFG_LSB;
                    end
                end
                S_WCFG_LSB: if (m_done) begin
                    if (m_ack_error) begin
                        i2c_fault <= 1'b1; state <= S_DONE;
                    end else begin
                        m_cmd       <= CMD_STOP;
                        m_cmd_valid <= 1'b1;
                        state       <= S_WCFG_STOP;
                    end
                end
                S_WCFG_STOP: if (m_done) begin
                    poll_cnt <= 32'd0;
                    state    <= S_POLL_WAIT;
                end

                // ============ POLL: doi 1 khoang, doc lai CONFIG, kiem OS ============
                S_POLL_WAIT: begin
                    if (poll_cnt >= POLL_WAIT_CYCLES - 1) begin
                        poll_cnt    <= 32'd0;
                        m_cmd       <= CMD_START;
                        m_cmd_valid <= 1'b1;
                        state       <= S_POLL_START;
                    end else begin
                        poll_cnt <= poll_cnt + 32'd1;
                    end
                end
                S_POLL_START: if (m_done) begin
                    m_cmd       <= CMD_WRITE;
                    m_tx_byte   <= {I2C_ADDR, 1'b1};  // dia chi + R (con tro da o CONFIG)
                    m_cmd_valid <= 1'b1;
                    state       <= S_POLL_ADDRR;
                end
                S_POLL_ADDRR: if (m_done) begin
                    if (m_ack_error) begin
                        i2c_fault <= 1'b1; state <= S_DONE;
                    end else begin
                        m_cmd       <= CMD_READ;
                        m_read_ack  <= 1'b1;   // con byte LSB sau
                        m_cmd_valid <= 1'b1;
                        state       <= S_POLL_MSB;
                    end
                end
                S_POLL_MSB: if (m_done) begin
                    msb_latch   <= m_rx_byte;
                    m_cmd       <= CMD_READ;
                    m_read_ack  <= 1'b0;   // byte cuoi
                    m_cmd_valid <= 1'b1;
                    state       <= S_POLL_LSB;
                end
                S_POLL_LSB: if (m_done) begin
                    // (LSB cua CONFIG khong can dung, chi can bit OS trong MSB)
                    m_cmd       <= CMD_STOP;
                    m_cmd_valid <= 1'b1;
                    state       <= S_POLL_STOP;
                end
                S_POLL_STOP: if (m_done) begin
                    if (msb_latch[7]) begin
                        // OS=1: da chuyen doi xong -> doc CONVERSION
                        m_cmd       <= CMD_START;
                        m_cmd_valid <= 1'b1;
                        state       <= S_RCONV_START;
                    end else begin
                        // Chua xong - doi them 1 khoang roi poll lai
                        poll_cnt <= 32'd0;
                        state    <= S_POLL_WAIT;
                    end
                end

                // ============ DOC CONVERSION (chuyen con tro sang 0x00 truoc) ============
                S_RCONV_START: if (m_done) begin
                    m_cmd       <= CMD_WRITE;
                    m_tx_byte   <= {I2C_ADDR, 1'b0};
                    m_cmd_valid <= 1'b1;
                    state       <= S_RCONV_ADDRW;
                end
                S_RCONV_ADDRW: if (m_done) begin
                    if (m_ack_error) begin
                        i2c_fault <= 1'b1; state <= S_DONE;
                    end else begin
                        m_cmd       <= CMD_WRITE;
                        m_tx_byte   <= REG_CONVERSION;
                        m_cmd_valid <= 1'b1;
                        state       <= S_RCONV_PTR;
                    end
                end
                S_RCONV_PTR: if (m_done) begin
                    if (m_ack_error) begin
                        i2c_fault <= 1'b1; state <= S_DONE;
                    end else begin
                        m_cmd       <= CMD_START;
                        m_cmd_valid <= 1'b1;
                        state       <= S_RCONV_RSTART;
                    end
                end
                S_RCONV_RSTART: if (m_done) begin
                    m_cmd       <= CMD_WRITE;
                    m_tx_byte   <= {I2C_ADDR, 1'b1};
                    m_cmd_valid <= 1'b1;
                    state       <= S_RCONV_ADDRR;
                end
                S_RCONV_ADDRR: if (m_done) begin
                    if (m_ack_error) begin
                        i2c_fault <= 1'b1; state <= S_DONE;
                    end else begin
                        m_cmd       <= CMD_READ;
                        m_read_ack  <= 1'b1;
                        m_cmd_valid <= 1'b1;
                        state       <= S_RCONV_MSB;
                    end
                end
                S_RCONV_MSB: if (m_done) begin
                    msb_latch   <= m_rx_byte;
                    m_cmd       <= CMD_READ;
                    m_read_ack  <= 1'b0;
                    m_cmd_valid <= 1'b1;
                    state       <= S_RCONV_LSB;
                end
                S_RCONV_LSB: if (m_done) begin
                    result_reg  <= {msb_latch, m_rx_byte};
                    m_cmd       <= CMD_STOP;
                    m_cmd_valid <= 1'b1;
                    state       <= S_RCONV_STOP;
                end
                S_RCONV_STOP: if (m_done) begin
                    state <= S_DONE;
                end

                S_DONE: begin
                    result <= i2c_fault ? 16'sd0 : $signed(result_reg);
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    state  <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
