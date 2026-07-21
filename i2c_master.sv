// ============================================================================
// i2c_master.sv
// Loi I2C master don gian, dieu khien theo LENH (command-based): START,
// WRITE (1 byte), READ (1 byte), STOP - dung giao thuc "start/done handshake"
// giong cach tiep can da dung xuyen suot du an (vd seq_divider.sv). FSM cap
// tren (ads1115_driver.sv) ghep cac lenh nguyen thuy nay thanh giao dich
// I2C day du.
//
// ADS1115 theo datasheet TI KHONG ho tro clock stretching -> SCL duoc dieu
// khien TRUC TIEP (push-pull), an toan vi chi co 1 master duy nhat tren bus.
// SDA la MO-DRAIN GIA LAP: sda_oe=1 nghia la CHU DONG KEO XUONG THAP;
// sda_oe=0 nghia la THA NOI (Hi-Z) - dien tro keo len 4.7K co san tren board
// (xem so do ADS1115) se keo len muc cao. Cap top-level anh xa sda_oe/sda_in
// thanh 1 chan IO that su bang bo dem 3 trang thai (tristate buffer).
//
// START duoc thiet ke TONG QUAT (4 pha: tha SDA -> keo SCL cao -> keo SDA
// thap -> keo SCL thap) de dung duoc CA cho START dau tien (tu bus idle
// SCL=1,SDA=1) LAN repeated-START giua chung mot giao dich (tu trang thai
// SCL=0 con lai sau byte truoc) - khong can phan biet 2 truong hop.
// ============================================================================
module i2c_master #(
    parameter int SYS_CLK_HZ         = 27_000_000,
    parameter int SCL_FREQ_HZ        = 100_000,     // I2C Standard-mode - on dinh, du dung cho ADS1115
    parameter int HALF_PERIOD_CYCLES = SYS_CLK_HZ / (2*SCL_FREQ_HZ)
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       cmd_valid,
    input  logic [1:0] cmd,        // 0=START,1=WRITE,2=READ,3=STOP
    input  logic [7:0] tx_byte,    // du lieu cho lenh WRITE
    input  logic       read_ack,   // cho lenh READ: 1=gui ACK(con byte sau),0=gui NACK(byte cuoi)

    output logic       busy,
    output logic        done,       // xung 1 chu ky khi lenh hoan tat
    output logic [7:0]  rx_byte,    // ket qua cho lenh READ
    output logic        ack_error,  // cho lenh WRITE: 1 = slave KHONG ACK (sai dia chi/loi bus)

    output logic scl,
    output logic sda_oe,
    input  logic sda_in
);
    localparam logic [1:0] CMD_START = 2'd0;
    localparam logic [1:0] CMD_WRITE = 2'd1;
    localparam logic [1:0] CMD_READ  = 2'd2;
    localparam logic [1:0] CMD_STOP  = 2'd3;

    typedef enum logic [3:0] {
        S_IDLE,
        S_START_REL, S_START_SCLHI, S_START_EDGE, S_START_SCLLO,
        S_BIT_LOW, S_BIT_HIGH,
        S_ACK_LOW, S_ACK_HIGH,
        S_RBIT_LOW, S_RBIT_HIGH,
        S_MACK_LOW, S_MACK_HIGH,
        S_STOP_SDALO, S_STOP_SCLHI, S_STOP_SDAHI
    } state_e;
    state_e state;

    logic [31:0] cnt;
    logic [2:0]  bit_idx;
    logic [7:0]  shift_out;

    wire cnt_done = (cnt == HALF_PERIOD_CYCLES - 1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            cnt       <= '0;
            bit_idx   <= 3'd0;
            shift_out <= 8'd0;
            rx_byte   <= 8'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
            ack_error <= 1'b0;
            scl       <= 1'b1;   // idle: bus tha noi, keo len muc cao
            sda_oe    <= 1'b0;   // idle: tha noi (khong keo xuong)
        end else begin
            done <= 1'b0;
            cnt  <= cnt_done ? 32'd0 : (cnt + 32'd1);

            unique case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (cmd_valid) begin
                        busy <= 1'b1;
                        cnt  <= 32'd0;
                        unique case (cmd)
                            CMD_START: state <= S_START_REL;
                            CMD_WRITE: begin
                                shift_out <= tx_byte;
                                bit_idx   <= 3'd7;
                                state     <= S_BIT_LOW;
                            end
                            CMD_READ: begin
                                bit_idx <= 3'd7;
                                state   <= S_RBIT_LOW;
                            end
                            CMD_STOP: state <= S_STOP_SDALO;
                            default:  state <= S_IDLE;
                        endcase
                    end
                end

                // ---- START / REPEATED START (4 pha, dung cho ca 2 truong hop) ----
                S_START_REL: begin       // tha SDA (huong ve muc cao)
                    sda_oe <= 1'b0;
                    if (cnt_done) state <= S_START_SCLHI;
                end
                S_START_SCLHI: begin    // dam bao SCL cao truoc khi tao canh START
                    scl <= 1'b1;
                    if (cnt_done) state <= S_START_EDGE;
                end
                S_START_EDGE: begin     // SDA 1->0 trong luc SCL=1 : day la canh START
                    sda_oe <= 1'b1;
                    if (cnt_done) state <= S_START_SCLLO;
                end
                S_START_SCLLO: begin    // dua SCL ve thap, san sang dich bit dau tien
                    scl <= 1'b0;
                    if (cnt_done) begin
                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                // ---- WRITE: 8 bit du lieu (MSB truoc) + 1 bit ACK tu slave ----
                S_BIT_LOW: begin
                    scl    <= 1'b0;
                    sda_oe <= ~shift_out[bit_idx];   // bit=1->tha(oe=0); bit=0->keo thap(oe=1)
                    if (cnt_done) state <= S_BIT_HIGH;
                end
                S_BIT_HIGH: begin
                    scl <= 1'b1;
                    if (cnt_done) begin
                        if (bit_idx == 3'd0) begin
                            state <= S_ACK_LOW;
                        end else begin
                            bit_idx <= bit_idx - 3'd1;
                            state   <= S_BIT_LOW;
                        end
                    end
                end
                S_ACK_LOW: begin
                    scl    <= 1'b0;
                    sda_oe <= 1'b0;    // tha SDA de slave dieu khien bit ACK
                    if (cnt_done) state <= S_ACK_HIGH;
                end
                S_ACK_HIGH: begin
                    scl <= 1'b1;
                    if (cnt_done) begin
                        ack_error <= sda_in;   // 0=ACK(hop le), 1=NACK(loi)
                        scl       <= 1'b0;     // dua SCL ve thap ngay (giua giao dich, KHONG ve idle-cao)
                        done      <= 1'b1;
                        busy      <= 1'b0;
                        state     <= S_IDLE;
                    end
                end

                // ---- READ: 8 bit du lieu tu slave + 1 bit ACK/NACK tu master ----
                S_RBIT_LOW: begin
                    scl    <= 1'b0;
                    sda_oe <= 1'b0;    // tha SDA de slave day du lieu
                    if (cnt_done) state <= S_RBIT_HIGH;
                end
                S_RBIT_HIGH: begin
                    scl <= 1'b1;
                    if (cnt_done) begin
                        rx_byte[bit_idx] <= sda_in;
                        if (bit_idx == 3'd0) begin
                            state <= S_MACK_LOW;
                        end else begin
                            bit_idx <= bit_idx - 3'd1;
                            state   <= S_RBIT_LOW;
                        end
                    end
                end
                S_MACK_LOW: begin
                    scl    <= 1'b0;
                    sda_oe <= read_ack ? 1'b1 : 1'b0;  // ACK(con byte sau)=keo thap; NACK(byte cuoi)=tha
                    if (cnt_done) state <= S_MACK_HIGH;
                end
                S_MACK_HIGH: begin
                    scl <= 1'b1;
                    if (cnt_done) begin
                        scl   <= 1'b0;   // ve thap, giua giao dich
                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                // ---- STOP: SDA 0->1 trong luc SCL=1 ----
                S_STOP_SDALO: begin
                    scl    <= 1'b0;
                    sda_oe <= 1'b1;    // dam bao SDA dang thap truoc
                    if (cnt_done) state <= S_STOP_SCLHI;
                end
                S_STOP_SCLHI: begin
                    scl <= 1'b1;
                    if (cnt_done) state <= S_STOP_SDAHI;
                end
                S_STOP_SDAHI: begin
                    sda_oe <= 1'b0;    // tha SDA (len muc cao) trong luc SCL=1 : canh STOP
                    if (cnt_done) begin
                        done  <= 1'b1;  // bus tro ve idle: scl=1,sda_oe=0
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
