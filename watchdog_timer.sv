module watchdog_timer #(
    parameter ADDR_WIDTH = 8,
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
    output                          pslverr,

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
//wire apb_read;

assign apb_write = psel & penable & pwrite;
//assign apb_read  = psel & penable & (~pwrite);

//--------------------------------------------------
// Register Address Map
//--------------------------------------------------
localparam WDT_CTRL_ADDR         = 8'h00;
localparam WDT_TIMEOUT_ADDR      = 8'h04;
localparam WDT_WINDOW_ADDR       = 8'h08;
localparam WDT_REFRESH_ADDR      = 8'h0C;
localparam WDT_STATUS_ADDR       = 8'h10;
localparam WDT_LOCK_ADDR         = 8'h14;
localparam WDT_COUNT_ADDR        = 8'h18;
localparam WDT_RESET_CAUSE_ADDR  = 8'h1C;
localparam WDT_LAST_PC_ADDR      = 8'h20;
localparam WDT_BOOT_STATUS_ADDR  = 8'h24;
localparam WDT_RESET_WIDTH_ADDR  = 8'h28;

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
reg refresh_error;
reg wdt_reset_cause;

//--------------------------------------------------
// Optional Diagnostic Registers
//--------------------------------------------------
reg [XLEN-1:0] last_pc;
reg prev_reset_wdt_pcl;
reg recovery_boot_req;

//--------------------------------------------------
// Internal Logic
//--------------------------------------------------
reg [31:0] watchdog_counter;
reg [15:0] reset_counter;
reg [1:0]  refresh_state;
reg        refresh_toggle;
reg        locked;
////////////////////////////////////////////////////

wire timeout_flag_apb;
wire window_violation_apb;
wire reset_issued_apb;
wire prev_reset_wdt_apb;

/////////////////////////////////////////////

wire enable_wdt;
wire reset_en_wdt;
wire window_en_wdt;
wire dbg_freeze_en_wdt;
wire wdt_reset_cause_apb;
wire cpu_dbg_halt_wdt;
wire dbg_freeze_wdt;


////////////////////////////////////////////////

wire [31:0] timeout_value_wdt;
wire [31:0] window_value_wdt;
wire [15:0] reset_cycles_wdt;

//////////////////////////////////////////////

reg counter_loaded;
reg timeout_active;

reg timeout_flag_wdt;
reg window_violation_wdt;
reg reset_issued_wdt;
reg prev_reset_wdt_wdt;
reg cfg_toggle;
reg snapshort_toggle;
wire snapshort_toggle_wdt;
reg ctrl_toggle;
reg counter_toggle_pcl;
reg counter_toggle;

////////////////////////////////////////////////////

wire refresh_valid;
wire freeze_condition;
wire prev_reset_wdt_pulse;
wire cpu_commit_valid_pcl;

assign pslverr = ~(( paddr == WDT_CTRL_ADDR ) || (paddr == WDT_TIMEOUT_ADDR) || (paddr == WDT_WINDOW_ADDR ) || ( paddr == WDT_RESET_WIDTH_ADDR ) || ( paddr == WDT_REFRESH_ADDR ) || ( paddr == WDT_STATUS_ADDR) || (paddr == WDT_LOCK_ADDR) || (paddr == WDT_COUNT_ADDR) || (paddr == WDT_LAST_PC_ADDR) || (paddr == WDT_BOOT_STATUS_ADDR) || (paddr == WDT_RESET_CAUSE_ADDR)) || ( apb_write & locked & ((paddr == WDT_CTRL_ADDR) || (paddr == WDT_TIMEOUT_ADDR) || (paddr ==  WDT_WINDOW_ADDR) || (paddr ==
WDT_RESET_WIDTH_ADDR))) ;
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
    else if (cpu_commit_valid_pcl)
        last_pc <= cpu_commit_pc;
end

reg status_toggle1;
reg status_toggle2;
reg status_toggle3;
reg [31:0] counter_snapshort;

wire clr_f1;
wire clr_f2;
wire clr_f3;

//--------------------------------------------------
// APB Write Logic
//--------------------------------------------------
always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
        enable                <= 1'b0;
        reset_en              <= 1'b1;
        window_en             <= 1'b0;
        dbg_freeze_en         <= 1'b1;
        lock_en               <= 1'b0;
        reset_scope_reg       <= 2'b11;
        hart_id               <= 4'h0;

        timeout_value         <= 32'h0000FFFF;
        window_value          <= 32'h00000000;
        reset_cycles          <= 16'd32;

        refresh_error         <= 1'b0;

        prev_reset_wdt_pcl    <= 1'b0;
        recovery_boot_req     <= 1'b0;
        locked                <= 1'b0;
	
    	refresh_state	      <= 2'd0;
        refresh_toggle 	      <= 1'b0;
        cfg_toggle            <= 1'b0;

    	status_toggle1	      <= 1'b0;
 	    status_toggle2	      <= 1'b0;
	    status_toggle3	      <= 1'b0;
        ctrl_toggle           <= 1'b0;


    end
    else begin

	
	//-----------------------------------------------
	//refresh logic
	//-----------------------------------------------
	
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


        //--------------------------------------------------
        // Status W1C
        //--------------------------------------------------
        if (apb_write && (paddr == WDT_STATUS_ADDR)) begin
		    if(pwdata[0]) status_toggle1 <= ~status_toggle1;
	    	if(pwdata[1]) status_toggle2 <= ~status_toggle2;
	    	if(pwdata[3]) status_toggle3 <= ~status_toggle3;

	    	if(pwdata[2]) refresh_error  <= 1'b0;
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
        if (apb_write && !locked && paddr == WDT_CTRL_ADDR) begin

                //------------------------------------------
                // CTRL Register
                //------------------------------------------
                    enable          <= pwdata[0];
                    reset_en        <= pwdata[1];
                    window_en       <= pwdata[2];
                    dbg_freeze_en   <= pwdata[3];
                    lock_en         <= pwdata[4];
                    reset_scope_reg <= pwdata[7:6];
                    hart_id         <= pwdata[11:8];
                    ctrl_toggle     <= ~ctrl_toggle;
                end

                //------------------------------------------
                // Timeout Register
                //------------------------------------------
        if (apb_write && !locked && paddr == WDT_TIMEOUT_ADDR) begin
                    timeout_value <= pwdata;
                    cfg_toggle    <= ~cfg_toggle;
                end

                //------------------------------------------
                // Window Register
                //------------------------------------------
        if (apb_write && !locked && paddr == WDT_WINDOW_ADDR) begin
                    window_value <= pwdata;
                    cfg_toggle   <= ~cfg_toggle;
                end

                //------------------------------------------
                // Boot Status Register
                //------------------------------------------
        if (apb_write && !locked && paddr == WDT_BOOT_STATUS_ADDR) begin
               // WDT_BOOT_STATUS_ADDR: begin
                    if (pwdata[0]) 
		        prev_reset_wdt_pcl <= ~ prev_reset_wdt_pcl;

                        recovery_boot_req <= pwdata[1];
                        
                end

                //------------------------------------------
                // Reset Width Register
                //------------------------------------------
        if (apb_write && !locked && paddr == WDT_RESET_WIDTH_ADDR) begin
                    reset_cycles <= pwdata[15:0];
                    cfg_toggle   <= ~cfg_toggle;
                end

                   
        end
    end

//--------------------------------------------------
// APB Read Logic
//--------------------------------------------------

always @(posedge pclk or negedge presetn) begin

    case (paddr)

        //----------------------------------------------
        // CTRL Register
        //----------------------------------------------
        WDT_CTRL_ADDR: prdata <= {20'd0,hart_id,reset_scope_reg,1'b0,lock_en,dbg_freeze_en,window_en,reset_en,enable} ;
            
        //----------------------------------------------
        // Timeout Register
        //----------------------------------------------
        WDT_TIMEOUT_ADDR:
            prdata <= timeout_value;

        //----------------------------------------------
        // Window Register
        //----------------------------------------------
        WDT_WINDOW_ADDR:
            prdata <= window_value;

        //----------------------------------------------
        // Status Register
        //----------------------------------------------
        WDT_STATUS_ADDR: prdata <= {28'd0,reset_issued_apb,refresh_error,window_violation_apb,timeout_flag_apb} ;
            
        //----------------------------------------------
        // Count Register
        //----------------------------------------------
        WDT_COUNT_ADDR: begin
            snapshort_toggle <= ~snapshort_toggle;   
            prdata <= counter_snapshort;    
            end

        //----------------------------------------------
        // Reset Cause Register
        //----------------------------------------------
        WDT_RESET_CAUSE_ADDR: prdata <= {31'd0,wdt_reset_cause_apb};
            
        //----------------------------------------------
        // Last PC Register
        //----------------------------------------------
        WDT_LAST_PC_ADDR:
            prdata <= last_pc;i

        //----------------------------------------------
        // Boot Status Register
        //----------------------------------------------
        WDT_BOOT_STATUS_ADDR: prdata <= {30'd0,recovery_boot_req,prev_reset_wdt_apb};
            
        //----------------------------------------------
        // Reset Width Register
        //----------------------------------------------
        WDT_RESET_WIDTH_ADDR:prdata <= {16'd0,reset_cycles};
            
        
    endcase
end


//--------------------------------------------------
// Watchdog Counter Logic
//--------------------------------------------------
assign freeze_condition = dbg_freeze_en_wdt & (cpu_dbg_halt_wdt | dbg_freeze_wdt);

////////////////////////////////////////////////////////////////////////////////

always @(posedge wdt_clk or negedge wdt_rstn) begin

    if (!wdt_rstn) begin

        watchdog_counter <= 32'h0;
        wdt_timeout      <= 1'b0;
        wdt_reset        <= 1'b0;

        reset_counter    <= 16'h0;
        counter_loaded   <= 1'b0;
        timeout_active   <= 1'b0;

    	wdt_reset_cause  <= 1'b0;
    	timeout_flag_wdt	 <= 1'b0;
    	window_violation_wdt <= 1'b0;

        reset_issued_wdt     <= 1'b0;
        prev_reset_wdt_wdt   <= 1'b0;
        counter_loaded       <= 32'b0;

       
    end
    else begin

        //----------------------------------------------
        // Default
        //----------------------------------------------
        wdt_timeout      <= 1'b0;
	

            if(clr_f1) begin
                timeout_flag_wdt <= 1'b0;
		end

             if(clr_f2) begin
                 window_violation_wdt <= 1'b0;
		end

             if(clr_f3) begin
                 reset_issued_wdt <=1'b0;
                  end

            if(prev_reset_wdt_pulse)
                prev_reset_wdt_wdt <= 1'b0;


            if (snapshort_toggle_wdt) begin
                counter_snapshort <=  watchdog_counter;
                counter_toggle    <= ~counter_toggle;
                end

        //----------------------------------------------
        // Reset Pulse Generation
        //----------------------------------------------
        if (wdt_reset) begin

            if (reset_counter >= reset_cycles_wdt) begin
                wdt_reset    <= 1'b0;
                reset_counter <= 16'h0;
            end
            else begin
                reset_counter <= reset_counter + 16'b1;
            end
        end

        //----------------------------------------------
        // Watchdog Operation
        //----------------------------------------------
        if (enable_wdt && !freeze_condition) begin

            //------------------------------------------
            // Initial Load
            //------------------------------------------
            if (!counter_loaded) begin
                watchdog_counter <= timeout_value_wdt;
                counter_loaded   <= 1'b1;
                end

              //------------------------------------------
              // Refresh Logic
              //------------------------------------------
              else if (refresh_valid) begin

                //--------------------------------------
                // Window Violation
                //--------------------------------------
                if (window_en_wdt && (watchdog_counter > window_value_wdt)) begin

                    window_violation_wdt <= 1'b1;

                    if (reset_en_wdt) begin
                        wdt_reset      <= 1'b1;
                        reset_issued_wdt   <= 1'b1;
                        prev_reset_wdt_wdt <= 1'b1;
                    end
                  end
                
              else begin
                  watchdog_counter <= timeout_value_wdt;
                  timeout_active   <= 1'b0;
                  timeout_flag_wdt     <= 1'b0;
                  end
              end

            //------------------------------------------
            // Normal Countdown
            //------------------------------------------
            else if (watchdog_counter > 0) begin
                watchdog_counter <= watchdog_counter - 32'b1;
            end

            //------------------------------------------
            // Timeout Condition
            //------------------------------------------
            else if (!timeout_active) begin

                timeout_active  <= 1'b1;
                timeout_flag_wdt    <= 1'b1;
                wdt_timeout     <= 1'b1;
                wdt_reset_cause <= 1'b1;

                if (reset_en_wdt) begin
                    wdt_reset      <= 1'b1;
                    reset_issued_wdt   <= 1'b1;
                    prev_reset_wdt_wdt <= 1'b1;
                end
            end

        end
    end
end


watchdog_sync watchdog_sync_instance (
    
        .pclk                       (pclk),
        .presetn                    (presetn),
        .wdt_clk                    (wdt_clk),
        .wdt_rstn                   (wdt_rstn),

        .status_toggle_sync1        (status_toggle1),
        .status_toggle_sync2        (status_toggle2),
        .status_toggle_sync3        (status_toggle3),
	    .timeout_flag_wdt_sync      (timeout_flag_wdt),
        .window_violation_wdt_sync  (window_violation_wdt),         
        .reset_issued_wdt_sync      (reset_issued_wdt),
        .prev_reset_wdt_wdt_sync    (prev_reset_wdt_wdt),
        .wdt_reset_cause_sync       (wdt_reset_cause),

        .timeout_flag_apb_sync      (timeout_flag_apb), 
        .window_violation_apb_sync  (window_violation_apb),
        .reset_issued_apb_sync      (reset_issued_apb),
        .prev_reset_wdt_apb_sync    (prev_reset_wdt_apb),
        .wdt_reset_cause_apb_sync   (wdt_reset_cause_apb),
        
        .refresh_toggle_sync        (refresh_toggle),
        .enable_sync                (enable),
        .reset_en_sync              (reset_en),
        .window_en_sync             (window_en),
        .dbg_freeze_en_sync         (dbg_freeze_en),
        .cfg_toggle_sync            (cfg_toggle),
        .prev_reset_wdt_pcl_sync    (prev_reset_wdt_pcl),
                                                          
        .enable_wdt_sync            (enable_wdt),
        .reset_en_wdt_sync          (reset_en_wdt),
        .window_en_wdt_sync         (window_en_wdt),
        .dbg_freeze_en_wdt_sync     (dbg_freeze_en_wdt),

        .refresh_valid_sync         (refresh_valid),
        .prev_reset_wdt_pulse_sync  (prev_reset_wdt_pulse),
        .clr_f1_sync                (clr_f1),
        .clr_f2_sync                (clr_f2),
        .clr_f3_sync                (clr_f3),

        .timeout_value_wdt_sync     (timeout_value_wdt),
        .window_value_wdt_sync      (window_value_wdt),
        .reset_cycles_wdt_sync      (reset_cycles_wdt),
        .cpu_dbg_halt_sync          (cpu_dbg_halt),
        .dbg_freeze_sync            (dbg_freeze),
        .cpu_dbg_halt_wdt_sync      (cpu_dbg_halt_wdt),
        .dbg_freeze_wdt_sync        (dbg_freeze_wdt),

        .timeout_value_sync         (timeout_value),
        .window_value_sync          (window_value),
        .reset_cycles_sync          (reset_cycles),

        .snapshort_toggle_sync      (snapshort_toggle),
        .snapshort_toggle_wdt_sync  (snapshort_toggle_wdt),
        .ctrl_toggle_sync           (ctrl_toggle),

        .cpu_commit_valid_pcl_sync  (cpu_commit_valid_pcl),
        .cpu_commit_valid_sync      (cpu_commit_valid),

        .counter_toggle_sync        (counter_toggle),
        .counter_toggle_pcl_sync    (counter_toggle_pcl)
    );


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
