
module tb_watchdog_timer;

  parameter ADDR_WIDTH = 8;
  parameter DATA_WIDTH = 32;
  parameter XLEN       = 32;

  //------------------------------------------
  // APB Signals
  //------------------------------------------
  reg                     pclk;
  reg                     presetn;
  reg                     psel;
  reg                     penable;
  reg                     pwrite;
  reg  [ADDR_WIDTH-1:0]             paddr;
  reg  [DATA_WIDTH-1:0]             pwdata;
  wire [DATA_WIDTH-1:0]             prdata;
  wire                    pready;
  wire                    pslverr;

  //------------------------------------------
  // WDT Signals
  //------------------------------------------
  reg                     wdt_clk;
  reg                     wdt_rstn;

  //------------------------------------------
  // Debug Interface
  //------------------------------------------
  reg                     cpu_dbg_halt;
  reg                     dbg_freeze;

  //------------------------------------------
  // CPU Tracking
  //------------------------------------------
  reg [XLEN-1:0]          cpu_commit_pc;
  reg                     cpu_commit_valid;

  //------------------------------------------
  // Outputs
  //------------------------------------------
  wire                    wdt_reset;
  wire                    wdt_timeout;
  wire [1:0]              reset_scope;

  //------------------------------------------
  // DUT
  //------------------------------------------
  watchdog_timer dut (
      .pclk             (pclk),
      .presetn          (presetn),
      .psel             (psel),
      .penable          (penable),
      .pwrite           (pwrite),
      .paddr            (paddr),
      .pwdata           (pwdata),
      .prdata           (prdata),
      .pready           (pready),
      .pslverr          (pslverr),

      .wdt_clk          (wdt_clk),
      .wdt_rstn         (wdt_rstn),

      .cpu_dbg_halt     (cpu_dbg_halt),
      .dbg_freeze       (dbg_freeze),

      .cpu_commit_pc    (cpu_commit_pc),
      .cpu_commit_valid (cpu_commit_valid),

      .wdt_reset        (wdt_reset),
      .wdt_timeout      (wdt_timeout),
      .reset_scope      (reset_scope)
  );

  //------------------------------------------
  // Address Map
  //------------------------------------------
  localparam WDT_CTRL_ADDR         = 32'h0000_0000;
  localparam WDT_TIMEOUT_ADDR      = 32'h0000_0004;
  localparam WDT_WINDOW_ADDR       = 32'h0000_0008;
  localparam WDT_REFRESH_ADDR      = 32'h0000_000C;
  localparam WDT_STATUS_ADDR       = 32'h0000_0010;
  localparam WDT_COUNT_ADDR        = 32'h0000_0018;
  localparam WDT_LOCK_ADDR         = 32'h0000_0014;
  localparam WDT_RESET_CAUSE_ADDR  = 32'h0000_001C;
  localparam WDT_LAST_PC_ADDR      = 32'h0000_0020;
  localparam WDT_BOOT_STATUS_ADDR  = 32'h0000_0024;
  localparam WDT_RESET_WIDTH_ADDR  = 32'h0000_0028;


  //------------------------------------------
  // Clock Generation
  //------------------------------------------
  initial begin
    pclk = 0;
    forever #5 pclk = ~pclk;     //100MHz
  end

  initial begin
    wdt_clk = 0;
    forever #20 wdt_clk = ~wdt_clk; //25MHz
  end

  reg [31:0] rd_data;

  //------------------------------------------
  // APB WRITE
  //------------------------------------------
  task apb_write(input [31:0] addr,
                 input [31:0] data);
  begin

    @(posedge pclk);

    psel    <= 1'b1;
    penable <= 1'b0;
    pwrite  <= 1'b1;
    paddr   <= addr;
    pwdata  <= data;

    @(posedge pclk);
    penable <= 1'b1;

    @(posedge pclk);

    psel    <=  1'b0;
    penable <=  1'b0;
    pwrite  <=  1'b0;
    paddr   <= 32'b0;
    pwdata  <= 32'b0;

  end
  endtask

  //------------------------------------------
  // APB READ
  //------------------------------------------
  task apb_read(input [31:0] addr,
                output [31:0] data);
  begin

    @(posedge pclk);

    psel    <= 1'b1;
    penable <= 1'b0;
    pwrite  <= 1'b0;
    paddr   <= addr;

    @(posedge pclk);
    penable <= 1'b1;

    @(posedge pclk);
    data = prdata;

    psel    <=  1'b0;
    penable <=  1'b0;
    paddr   <= 32'b0;

  end
  endtask

  //------------------------------------------
  // Refresh Task
  //------------------------------------------
  task refresh_wdt;
  begin
    apb_write(WDT_REFRESH_ADDR,32'hA5);
    apb_write(WDT_REFRESH_ADDR,32'h5A);
  end
  endtask

  //------------------------------------------
  // Monitor
  //------------------------------------------
/*  initial begin

    $display("TIME\tCOUNT\tTIMEOUT\tRESET");

    forever begin
      @(posedge wdt_clk);

      $display("%0t\t%0d\t%b\t%b",
                $time,
                dut.watchdog_counter,
                wdt_timeout,
                wdt_reset);
    end
  end */

    always @(posedge wdt_clk) begin
    if(dut.watchdog_counter < 25)
        $display("[%0t] COUNT=%0d TIMEOUT=%0b RESET=%0b",
              $time,
              dut.watchdog_counter,
              wdt_timeout,
              wdt_reset);
      end 
  //------------------------------------------
  // Test Sequence
  //------------------------------------------
  reg [31:0] rdata;

  initial begin

    //--------------------------------------
    // Initialize
    //--------------------------------------
    psel             = 0;
    penable          = 0;
    pwrite           = 0;
    paddr            = 0;
    pwdata           = 0;

    presetn          = 0;
    wdt_rstn         = 0;

    cpu_dbg_halt     = 0;
    dbg_freeze       = 0;

    cpu_commit_pc    = 0;
    cpu_commit_valid = 0;

    //--------------------------------------
    // Reset
    //--------------------------------------
    #100;

    presetn  = 1;
    wdt_rstn = 1;

    #50;

   /*  //--------------------------------------------------
    // TC1 : Reset Values
    //--------------------------------------------------
    $display("\n==========================");
    $display("TC1 : RESET VALUES");
    $display("==========================");

    apb_read(WDT_CTRL_ADDR,rdata);
    $display("CTRL    = %h",rdata);

    apb_read(WDT_TIMEOUT_ADDR,rdata);
    $display("TIMEOUT = %h",rdata);

    //--------------------------------------------------
    // TC2 : APB R/W
    //--------------------------------------------------
    $display("\n==========================");
    $display("TC2 : APB R/W");
    $display("==========================");

    apb_write(WDT_TIMEOUT_ADDR,32'd20);

    apb_read(WDT_TIMEOUT_ADDR,rdata);

    if(rdata == 20)
      $display("PASS : APB WRITE/READ");
    else
      $display("FAIL : APB WRITE/READ");

    //--------------------------------------------------
    // TC3 : Enable WDT
    //--------------------------------------------------
    $display("\n==========================");
    $display("TC3 : ENABLE WDT");
    $display("==========================");

    apb_write(WDT_CTRL_ADDR,32'h0000_0003);

   
   
    apb_write(WDT_TIMEOUT_ADDR,32'd20);
  
    apb_write(WDT_CTRL_ADDR,32'h0000_0003);
    repeat(3) @(posedge wdt_clk);

    //--------------------------------------------------
    // TC4 : VALID REFRESH
    //--------------------------------------------------
    $display("\n==========================");
    $display("TC4 : VALID REFRESH");
    $display("==========================");

    refresh_wdt();

    repeat(3) @(posedge wdt_clk);
   
   //--------------------------------------------------
    // TC5 : INVALID REFRESH
    //--------------------------------------------------
    $display("\n==========================");
    $display("TC5 : INVALID REFRESH");
    $display("==========================");

    apb_write(WDT_REFRESH_ADDR,32'hA5);
    apb_write(WDT_REFRESH_ADDR,32'hAA);

    repeat(5) @(posedge pclk);

    apb_read(WDT_STATUS_ADDR,rdata);

    $display("STATUS = %h",rdata);

     //--------------------------------------------------
    // TC6 : TIMEOUT
    //--------------------------------------------------

    $display("\n========================");
    $display("TC6 : TIMEOUT");
    $display("========================");

    apb_write(WDT_TIMEOUT_ADDR,32'd20);

    // enable=1 reset_en=1
    apb_write(WDT_CTRL_ADDR,32'h0000_0003);

    repeat(10) @(posedge wdt_clk);

    $display("TIMEOUT TEST COMPLETE");
 
    //--------------------------------------------------
    // TC7 : DEBUG FREEZE
    //--------------------------------------------------

    $display("\nTC7 : DEBUG FREEZE");

    // Program timeout
    apb_write(WDT_TIMEOUT_ADDR,32'd20);

    // Enable WDT
    apb_write(WDT_CTRL_ADDR,32'hb);
    
    repeat(5) @(posedge wdt_clk);

    // Assert debug halt
    cpu_dbg_halt = 1'b1;

    $display("[%0t] DEBUG HALT ASSERTED",$time);

    repeat(5) @(posedge wdt_clk);

    // Release debug halt
    cpu_dbg_halt = 1'b0;

    $display("[%0t] DEBUG HALT DEASSERTED",$time);

    repeat(5) @(posedge wdt_clk);

     //--------------------------------------------------
    // TC8 : LOCK PROTECTION
    //--------------------------------------------------

    $display("\n==========================");
    $display("TC8 : LOCK PROTECTION");
    $display("==========================");

    //------------------------------------
    // Step 1 : Program timeout = 20
    //------------------------------------
    apb_write(WDT_TIMEOUT_ADDR,32'd20);

    apb_read(WDT_TIMEOUT_ADDR,rdata);

    $display("Before Lock TIMEOUT = %0d",rdata);

    //------------------------------------
    // Step 2 : Lock Registers
    //------------------------------------
    apb_write(WDT_LOCK_ADDR,32'h00000000);

    repeat(2) @(posedge pclk);

    //------------------------------------
    // Step 3 : Try Protected Write
    //------------------------------------
    apb_write(WDT_TIMEOUT_ADDR,32'd100);

    repeat(2) @(posedge pclk);

    $display("[%0t] LOCKED=%0b PSLVERR=%0b",
          $time,
          dut.locked,
          pslverr);

    //------------------------------------
    // Step 4 : Read Back
    //------------------------------------
    apb_read(WDT_TIMEOUT_ADDR,rdata);

    $display("After Lock TIMEOUT = %0d",rdata);

    //------------------------------------
    // Step 5 : Unlock
    //------------------------------------
    apb_write(WDT_LOCK_ADDR,32'h1ACCE551);

    repeat(2) @(posedge pclk);

    $display("[%0t] LOCKED=%0b",
          $time,
          dut.locked);

    //------------------------------------
    // Step 6 : Write Again
    //------------------------------------
    apb_write(WDT_TIMEOUT_ADDR,32'd100);

    apb_read(WDT_TIMEOUT_ADDR,rdata);

    $display("After Unlock TIMEOUT = %0d",rdata);
    

   //--------------------------------------------------
    // TC9 : Window Violation
    //--------------------------------------------------

    $display("\nTC9 : Window Violation");

    // Clear status flags
    apb_write(WDT_STATUS_ADDR, 32'hF);

    // Timeout = 100
    apb_write(WDT_TIMEOUT_ADDR, 32'd100);

    // Window = 50
    apb_write(WDT_WINDOW_ADDR, 32'd50);

    // Enable + Reset Enable + Window Enable
    apb_write(WDT_CTRL_ADDR, 32'h0000_0007);

    repeat(10) @(posedge wdt_clk);

    // Refresh too early
    apb_write(WDT_REFRESH_ADDR, 32'h000000A5);
    apb_write(WDT_REFRESH_ADDR, 32'h0000005A);

    repeat(10) @(posedge wdt_clk);

    //--------------------------------------------------
    // TC10 : Valid Window Refresh
    //--------------------------------------------------

    $display("\nTC10 : Valid Window Refresh");

    // Clear status flags
    apb_write(WDT_STATUS_ADDR, 32'hF);

    // Timeout = 100
    apb_write(WDT_TIMEOUT_ADDR, 32'd100);

    // Window = 50
    apb_write(WDT_WINDOW_ADDR, 32'd50);

    // Enable + Reset Enable + Window Enable
    apb_write(WDT_CTRL_ADDR, 32'h0000_0007);

    repeat(10) @(posedge wdt_clk);

    // Refresh inside window
    apb_write(WDT_REFRESH_ADDR, 32'h000000A5);
    apb_write(WDT_REFRESH_ADDR, 32'h0000005A);

    repeat(10) @(posedge wdt_clk); 
    */
/*    
presetn  = 1'b0;
wdt_rstn = 1'b0;

repeat(5) @(posedge pclk);

presetn  = 1'b1;
wdt_rstn = 1'b1;

repeat(5) @(posedge pclk);
repeat(5) @(posedge wdt_clk);

apb_write(WDT_TIMEOUT_ADDR,32'd20);

repeat(5) @(posedge wdt_clk);

apb_write(WDT_CTRL_ADDR,32'h3); // enable + reset_en

repeat(30) @(posedge wdt_clk);

apb_read(WDT_BOOT_STATUS_ADDR,rdata);

apb_write(WDT_BOOT_STATUS_ADDR,32'h1);

repeat(5) @(posedge wdt_clk);

apb_read(WDT_BOOT_STATUS_ADDR,rdata);
//--------------------------------------------------
// TC14 : CLEAR ALL FLAGS
//--------------------------------------------------

$display("\nTC14 : CLEAR ALL FLAGS");

// Reset DUT
presetn = 0;
repeat(5) @(posedge pclk);
presetn = 1;
repeat(5) @(posedge pclk);

// Create timeout
apb_write(WDT_TIMEOUT_ADDR,32'd5);
apb_write(WDT_CTRL_ADDR,32'h0000_0003);

repeat(20) @(posedge wdt_clk);

// Force window violation also
apb_write(WDT_TIMEOUT_ADDR,32'd100);
apb_write(WDT_WINDOW_ADDR ,32'd50);
apb_write(WDT_CTRL_ADDR   ,32'h0000_0007);

repeat(10) @(posedge wdt_clk);

refresh_wdt();

repeat(10) @(posedge wdt_clk);


// Clear all flags
apb_write(WDT_STATUS_ADDR,32'h0000_0007);

repeat(5) @(posedge wdt_clk); 
//--------------------------------------------------
// TC12 : WINDOW_VIOLATION W1C CLEAR
//--------------------------------------------------

$display("\nTC12 : WINDOW_VIOLATION W1C CLEAR");

// Reset DUT
presetn = 0;
repeat(5) @(posedge pclk);
presetn = 1;
repeat(5) @(posedge pclk);

apb_write(WDT_TIMEOUT_ADDR,32'd100);
apb_write(WDT_WINDOW_ADDR ,32'd50);

// enable + reset_en + window_en
apb_write(WDT_CTRL_ADDR,32'h0000_0007);

// Refresh too early
repeat(10) @(posedge wdt_clk);

refresh_wdt();

repeat(10) @(posedge wdt_clk);


// Clear window violation
apb_write(WDT_STATUS_ADDR,32'h0000_0002);

repeat(5) @(posedge wdt_clk);
*/

//--------------------------------------------------
// TC15 : WDT Counter Read CDC Verification
//--------------------------------------------------

$display("\n==================================");
$display("TC15 : WDT Counter Read CDC");
$display("==================================");

// Configure timeout
apb_write(WDT_TIMEOUT_ADDR,32'd20);

// Enable WDT
apb_write(WDT_CTRL_ADDR,32'h0000_0003);

// Read counter multiple times
repeat(25) begin

    repeat(2) @(posedge pclk);

    apb_read(WDT_COUNT_ADDR, rd_data);

    //$display("[%0t] Counter Read = %0d", $time);

end

    $display("\ncompleted all test cases");


    #100;
         
    $finish;
    

  end
 
initial
begin

    $shm_open("wd_time1.shm");
    $shm_probe("ACTMF");

end



endmodule
