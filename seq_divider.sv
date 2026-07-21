// ============================================================================
// seq_divider.sv  -  Signed sequential (restoring) divider
// Chia hai so co dau: numerator / denominator, ket qua lay phan nguyen.
// Div-by-zero: div_dbz=1 khi denominator==0, quotient=0.
// ============================================================================
module seq_divider #(
    parameter int WIDTH = 64
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                start,
    input  logic signed [WIDTH-1:0] numerator,
    input  logic signed [WIDTH-1:0] denominator,
    output logic                busy,
    output logic                done,
    output logic signed [WIDTH-1:0] quotient,
    output logic                div_by_zero
);
    localparam int SHIFT_REG_W = 2 * WIDTH;

    typedef enum logic [1:0] {S_IDLE, S_DIVIDE, S_FINISH} state_e;
    state_e state;

    logic [$clog2(WIDTH+1)-1:0] iter_cnt;
    logic [SHIFT_REG_W-1:0] shift_reg;
    logic [WIDTH-1:0]         abs_num, abs_den;
    logic                     sign_out;
    logic [WIDTH-1:0]         q_abs;

    wire cmp_ge = (shift_reg[SHIFT_REG_W-1:WIDTH] >= abs_den);

    assign abs_num     = numerator[WIDTH-1] ? (-numerator) : numerator;
    assign abs_den     = denominator[WIDTH-1] ? (-denominator) : denominator;
    assign sign_out    = numerator[WIDTH-1] ^ denominator[WIDTH-1];
    assign div_by_zero = (denominator == 0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            iter_cnt  <= '0;
            shift_reg <= '0;
            busy      <= 1'b0;
            done      <= 1'b0;
            quotient  <= '0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        if (div_by_zero) begin
                            quotient <= '0;
                            state    <= S_FINISH;
                        end else begin
                            shift_reg <= {{WIDTH{1'b0}}, abs_num}; // Sửa cú pháp tại đây
                            iter_cnt  <= '0;
                            busy      <= 1'b1;
                            state     <= S_DIVIDE;
                        end
                    end
                end

                S_DIVIDE: begin
                    if (cmp_ge) begin
                        shift_reg <= {shift_reg[SHIFT_REG_W-2:WIDTH-1], 1'b0}
                                     - {{(WIDTH-1){1'b0}}, abs_den};
                        shift_reg[0] <= 1'b1;
                    end else begin
                        shift_reg <= {shift_reg[SHIFT_REG_W-2:WIDTH-1], 1'b0};
                    end
                    if (iter_cnt == WIDTH - 1) begin
                        state <= S_FINISH;
                    end else begin
                        iter_cnt <= iter_cnt + 1'b1;
                    end
                end

                S_FINISH: begin
                    if (div_by_zero) begin
                        quotient <= '0;
                    end else begin
                        q_abs = shift_reg[SHIFT_REG_W-1:WIDTH];
                        if (sign_out) begin
                            quotient <= -q_abs;
                        end else begin
                            quotient <= q_abs;
                        end
                    end
                    done <= 1'b1;
                    busy <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule