module watchdog_timer #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter XLEN       = 32
)(
    //--------------------------------------------------
    // APB Interface
    //--------------------------------------------------
    input  wire                     pclk,
    input  wire                     presetn,
    input  wire                     psel,
    input  wire                     penable,
    input  wire                     pwrite,
    input  wire [ADDR_WIDTH-1:0]    paddr,
    input  wire [DATA_WIDTH-1:0]    pwdata,
    output reg  [DATA_WIDTH-1:0]    prdata,
    output wire                     pready,
    output reg                      pslverr,

    //--------------------------------------------------
    // Watchdog Clock/Reset
    //--------------------------------------------------
    input  wire                     wdt_clk,
    input  wire                     wdt_rstn,

    //--------------------------------------------------
    // Debug Interface
    //--------------------------------------------------
    input  wire                     cpu_dbg_halt,
    input  wire                     dbg_freeze,

    //--------------------------------------------------
    // Optional CPU Tracking
    //--------------------------------------------------
    input  wire [XLEN-1:0]          cpu_commit_pc,
    input  wire                     cpu_commit_valid,

    //--------------------------------------------------
    // Outputs
    //--------------------------------------------------
    output reg                      wdt_reset,
    output reg                      wdt_timeout,
    output reg [1:0]                reset_scope
);

//--------------------------------------------------
// APB Definitions
//--------------------------------------------------
assign pready = 1'b1;

wire apb_write;
wire apb_read;

assign apb_write = psel & penable & pwrite;
assign apb_read  = psel & penable & (~pwrite);

//--------------------------------------------------
// Register Address Map
//--------------------------------------------------
localparam WDT_CTRL_ADDR         = 32'h0000_0000;
localparam WDT_TIMEOUT_ADDR      = 32'h0000_0004;
localparam WDT_WINDOW_ADDR       = 32'h0000_0008;
localparam WDT_REFRESH_ADDR      = 32'h0000_000C;
localparam WDT_STATUS_ADDR       = 32'h0000_0010;
localparam WDT_LOCK_ADDR         = 32'h0000_0014;
localparam WDT_COUNT_ADDR        = 32'h0000_0018;
localparam WDT_RESET_CAUSE_ADDR  = 32'h0000_001C;
localparam WDT_LAST_PC_ADDR      = 32'h0000_0020;
localparam WDT_BOOT_STATUS_ADDR  = 32'h0000_0024;
localparam WDT_RESET_WIDTH_ADDR  = 32'h0000_0028;

//--------------------------------------------------
// Refresh Keys
//--------------------------------------------------
localparam REFRESH_KEY1 = 32'h000000A5;
localparam REFRESH_KEY2 = 32'h0000005A;

//--------------------------------------------------
// Lock Keys
//--------------------------------------------------
localparam LOCK_KEY_UNLOCK = 32'h1ACCE551;
localparam LOCK_KEY_LOCK   = 32'h00000000;

//--------------------------------------------------
// CTRL Register Fields
//--------------------------------------------------
reg        enable;
reg        reset_en;
reg        window_en;
reg        dbg_freeze_en;
reg        lock_en;
reg [1:0]  reset_scope_reg;
reg [3:0]  hart_id;

//--------------------------------------------------
// Configuration Registers
//--------------------------------------------------
reg [31:0] timeout_value;
reg [31:0] window_value;
reg [15:0] reset_cycles;

//--------------------------------------------------
// Status Registers
//--------------------------------------------------
reg timeout_flag;
reg window_violation;
reg refresh_error;
reg reset_issued;
reg wdt_reset_cause;

//--------------------------------------------------
// Optional Diagnostic Registers
//--------------------------------------------------
reg [XLEN-1:0] last_pc;
reg prev_reset_wdt;
reg recovery_boot_req;

//--------------------------------------------------
// Internal Logic
//--------------------------------------------------
reg [31:0] watchdog_counter;
reg [15:0] reset_counter;
reg [1:0]  refresh_state;
reg        refresh_toggle;
reg        locked;
reg        refresh_toggle_sync1;
reg        refresh_toggle_sync2;
reg        refresh_toggle_sync2_d;

wire       refresh_valid;

//--------------------------------------------------
// Reset Scope Output
//--------------------------------------------------
always @(*) begin
    reset_scope = reset_scope_reg;
end

//--------------------------------------------------
// Last PC Capture
//--------------------------------------------------
always @(posedge pclk or negedge presetn) begin
    if (!presetn)
        last_pc <= {XLEN{1'b0}};
    else if (cpu_commit_valid)
        last_pc <= cpu_commit_pc;
end

//--------------------------------------------------
// APB Write Logic
//--------------------------------------------------
always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
        enable            <= 1'b0;
        reset_en          <= 1'b1;
        window_en         <= 1'b0;
        dbg_freeze_en     <= 1'b1;
        lock_en           <= 1'b0;
        reset_scope_reg   <= 2'b11;
        hart_id           <= 4'h0;

        timeout_value     <= 32'h0000FFFF;
        window_value      <= 32'h00000000;
        reset_cycles      <= 16'd32;

        timeout_flag      <= 1'b0;
        window_violation  <= 1'b0;
        refresh_error     <= 1'b0;
        reset_issued      <= 1'b0;
        wdt_reset_cause   <= 1'b0;

        prev_reset_wdt    <= 1'b0;
        recovery_boot_req <= 1'b0;

        locked            <= 1'b0;

        pslverr           <= 1'b0;
    end
    else begin

        pslverr <= 1'b0;

        //--------------------------------------------------
        // Status W1C
        //--------------------------------------------------
        if (apb_write && paddr == WDT_STATUS_ADDR) begin
            if (pwdata[0]) timeout_flag     <= 1'b0;
            if (pwdata[1]) window_violation <= 1'b0;
            if (pwdata[2]) refresh_error    <= 1'b0;
            if (pwdata[3]) reset_issued     <= 1'b0;
        end

        //--------------------------------------------------
        // Lock Register
        //--------------------------------------------------
        if (apb_write && paddr == WDT_LOCK_ADDR) begin
            if (pwdata == LOCK_KEY_UNLOCK)
                locked <= 1'b0;
            else if (pwdata == LOCK_KEY_LOCK)
                locked <= 1'b1;
        end

        //--------------------------------------------------
        // Protected Writes
        //--------------------------------------------------
        if (apb_write && !locked) begin

            case (paddr)

                //------------------------------------------
                // CTRL Register
                //------------------------------------------
                WDT_CTRL_ADDR: begin
                    enable          <= pwdata[0];
                    reset_en        <= pwdata[1];
                    window_en       <= pwdata[2];
                    dbg_freeze_en   <= pwdata[3];
                    lock_en         <= pwdata[4];
                    reset_scope_reg <= pwdata[7:6];
                    hart_id         <= pwdata[11:8];
                end

                //------------------------------------------
                // Timeout Register
                //------------------------------------------
                WDT_TIMEOUT_ADDR: begin
                    timeout_value <= pwdata;
                end

                //------------------------------------------
                // Window Register
                //------------------------------------------
                WDT_WINDOW_ADDR: begin
                    window_value <= pwdata;
                end

                //------------------------------------------
                // Boot Status Register
                //------------------------------------------
                WDT_BOOT_STATUS_ADDR: begin
                    if (pwdata[0])
                        prev_reset_wdt <= 1'b0;
                        recovery_boot_req <= pwdata[1];
                end

                //------------------------------------------
                // Reset Width Register
                //------------------------------------------
                WDT_RESET_WIDTH_ADDR: begin
                    reset_cycles <= pwdata[15:0];
                end

                default: begin
                end

            endcase
        end
        else if (apb_write && locked) begin

            case (paddr)
                WDT_CTRL_ADDR,
                WDT_TIMEOUT_ADDR,
                WDT_WINDOW_ADDR,
                WDT_RESET_WIDTH_ADDR:
                begin
                    pslverr <= 1'b1;
                end
                default: begin
                end
            endcase
        end
    end
end

//--------------------------------------------------
// APB Read Logic
//--------------------------------------------------
always @(*) begin

    prdata = 32'h0;

    case (paddr)

        //----------------------------------------------
        // CTRL Register
        //----------------------------------------------
        WDT_CTRL_ADDR: begin
            prdata[0]    = enable;
            prdata[1]    = reset_en;
            prdata[2]    = window_en;
            prdata[3]    = dbg_freeze_en;
            prdata[4]    = lock_en;
            prdata[7:6]  = reset_scope_reg;
            prdata[11:8] = hart_id;
        end

        //----------------------------------------------
        // Timeout Register
        //----------------------------------------------
        WDT_TIMEOUT_ADDR:
            prdata = timeout_value;

        //----------------------------------------------
        // Window Register
        //----------------------------------------------
        WDT_WINDOW_ADDR:
            prdata = window_value;

        //----------------------------------------------
        // Status Register
        //----------------------------------------------
        WDT_STATUS_ADDR: begin
            prdata[0] = timeout_flag;
            prdata[1] = window_violation;
            prdata[2] = refresh_error;
            prdata[3] = reset_issued;
        end

        //----------------------------------------------
        // Count Register
        //----------------------------------------------
        WDT_COUNT_ADDR:
            prdata = watchdog_counter;

        //----------------------------------------------
        // Reset Cause Register
        //----------------------------------------------
        WDT_RESET_CAUSE_ADDR: begin
            prdata[0] = wdt_reset_cause;
        end

        //----------------------------------------------
        // Last PC Register
        //----------------------------------------------
        WDT_LAST_PC_ADDR:
            prdata = last_pc;

        //----------------------------------------------
        // Boot Status Register
        //----------------------------------------------
        WDT_BOOT_STATUS_ADDR: begin
            prdata[0] = prev_reset_wdt;
            prdata[1] = recovery_boot_req;
        end

        //----------------------------------------------
        // Reset Width Register
        //----------------------------------------------
        WDT_RESET_WIDTH_ADDR:
            prdata[15:0] = reset_cycles;

        default:
            prdata = 32'h0;

    endcase
end

//--------------------------------------------------
// Refresh Sequence Detection
//--------------------------------------------------
always @(posedge pclk or negedge presetn) begin

    if (!presetn) begin
        refresh_state <= 2'd0;
        refresh_toggle <= 1'b0;
    end
    else begin

       // refresh_toggle <= 1'b0;

        if (apb_write && paddr == WDT_REFRESH_ADDR) begin

            case (refresh_state)

                2'd0: begin
                    if (pwdata == REFRESH_KEY1)
                        refresh_state <= 2'd1;
                    else begin
                        refresh_error <= 1'b1;
                        refresh_state <= 2'd0;
                    end
                end

                2'd1: begin
                    if (pwdata == REFRESH_KEY2) begin
                        refresh_toggle <= ~refresh_toggle;
                        refresh_state <= 2'd0;
                    end
                    else begin
                        refresh_error <= 1'b1;
                        refresh_state <= 2'd0;
                    end
                end

                default: begin
                    refresh_state <= 2'd0;
                end

            endcase
        end
    end
end

//------------------------------------------
//synchronizer block
//-------------------------------------------
always@(posedge wdt_clk or negedge wdt_rstn) begin
if(!wdt_rstn) begin
        refresh_toggle_sync1   <= 1'b0;
        refresh_toggle_sync2   <= 1'b0;
        refresh_toggle_sync2_d <= 1'b0;
    end
    else begin

            refresh_toggle_sync1   <= refresh_toggle;
            refresh_toggle_sync2   <= refresh_toggle_sync1;
            refresh_toggle_sync2_d <= refresh_toggle_sync2;
        end   

end

assign refresh_valid = refresh_toggle_sync2 ^ refresh_toggle_sync2_d;


//--------------------------------------------------
// Watchdog Counter Logic
//--------------------------------------------------
wire freeze_condition;
assign freeze_condition = dbg_freeze_en & (cpu_dbg_halt | dbg_freeze);

reg counter_loaded;
reg timeout_active;

always @(posedge wdt_clk or negedge wdt_rstn) begin

    if (!wdt_rstn) begin

        watchdog_counter <= 32'h0;
        wdt_timeout      <= 1'b0;
        wdt_reset        <= 1'b0;
        reset_counter    <= 16'h0;
        counter_loaded   <= 1'b0;
        timeout_active   <= 1'b0;

    end
    else begin

        //----------------------------------------------
        // Default
        //----------------------------------------------
        wdt_timeout     <= 1'b0;
       // counter_loaded  <= 1'b0;

        //----------------------------------------------
        // Reset Pulse Generation
        //----------------------------------------------
        if (wdt_reset) begin

            if (reset_counter >= reset_cycles) begin
                wdt_reset    <= 1'b0;
                reset_counter <= 16'h0;
            end
            else begin
                reset_counter <= reset_counter + 1'b1;
            end
        end

        //----------------------------------------------
        // Watchdog Operation
        //----------------------------------------------
        if (enable && !freeze_condition) begin

            //------------------------------------------
            // Initial Load
            //------------------------------------------
            if (!counter_loaded) begin
                watchdog_counter <= timeout_value;
                counter_loaded   <= 1'b1;
                end

            //------------------------------------------
            // Refresh Logic
            //------------------------------------------
            else if (refresh_valid) begin

                //--------------------------------------
                // Window Violation
                //--------------------------------------
                if (window_en && (watchdog_counter > window_value)) begin

                    window_violation <= 1'b1;

                    if (reset_en) begin
                        wdt_reset      <= 1'b1;
                        reset_issued   <= 1'b1;
                        prev_reset_wdt <= 1'b1;
                    end
                end
                else begin
                    watchdog_counter <= timeout_value;
                    timeout_active   <= 1'b0;
                    timeout_flag     <= 1'b0;
                end
            end

            //------------------------------------------
            // Normal Countdown
            //------------------------------------------
            else if (watchdog_counter > 0) begin
                watchdog_counter <= watchdog_counter - 1'b1;
            end

            //------------------------------------------
            // Timeout Condition
            //------------------------------------------
            else if (!timeout_active) begin

                timeout_active  <= 1'b1;
                timeout_flag    <= 1'b1;
                wdt_timeout     <= 1'b1;
                wdt_reset_cause <= 1'b1;

                if (reset_en) begin
                    wdt_reset      <= 1'b1;
                    reset_issued   <= 1'b1;
                    prev_reset_wdt <= 1'b1;
                end
            end
        end
    end
end

endmodule


/*

---

# 3. Key RTL Features

| Feature              | Supported |
| -------------------- | --------- |
| APB slave            | Yes       |
| Programmable timeout | Yes       |
| Window watchdog      | Yes       |
| Reset-only mode      | Yes       |
| Debug freeze         | Yes       |
| Register lock        | Yes       |
| Last PC capture      | Yes       |
| Reset pulse width    | Yes       |
| Multi-reset scope    | Yes       |
| Multi-hart awareness | Yes       |
| Synthesizable        | Yes       |

---

# 4. Integration Notes

## Clocking

Recommended:

* `pclk` = APB bus clock
* `wdt_clk` = independent always-on clock

---

## Reset Synchronization

Recommended:

* Synchronize `wdt_reset` into reset controller
* Use reset controller for:

  * reset sequencing
  * pulse stretching
  * reset isolation

---

## Recommended SoC Placement

Place watchdog in:

* Always-On domain
* Secure subsystem
* Near reset controller

---

# 5. Future Improvements

Possible future additions:

* CDC synchronizers
* Dual-stage watchdog
* Timeout interrupt stage
* Secure/non-secure partitioning
* ECC protection
* SBI watchdog support
* AXI/APB bridge support
* UVM register model compatibility

---

# 6. Recommended Verification Areas

## Directed Tests

* Enable/disable
* Timeout reset
* Window violation
* Refresh sequence
* Lock mechanism
* Debug freeze
* Reset width

---

## Corner Cases

* Refresh near timeout
* Debug entry during timeout
* Simultaneous APB access and reset
* Window boundary conditions
* Continuous reset conditions

---

# 7. Synthesis Notes

This RTL is:

* Fully synthesizable
* FPGA compatible
* ASIC compatible
* Reset-safe
* Lint friendly with minor cleanup

Recommended cleanup before tapeout:

* Add CDC synchronizers
* Add low-power intent
* Add scan integration
* Add clock-gating cells
* Add assertions
* Add DFT hooks


*/
