module watchdog_sync (

    //apb interface
    input      pclk,
    input      presetn,


    //watchdog clk and rst
    input       wdt_clk,
    input       wdt_rstn,

    //
    input     status_toggle_sync1,
    input     status_toggle_sync2,
    input     status_toggle_sync3,
    input     timeout_flag_wdt_sync,
    input     window_violation_wdt_sync,
    input     reset_issued_wdt_sync,
    input     prev_reset_wdt_wdt_sync,
    input     wdt_reset_cause_sync,

    input    refresh_toggle_sync,   
    input    enable_sync,
    input    reset_en_sync,
    input    window_en_sync,
    input    dbg_freeze_en_sync,
    input    cfg_toggle_sync,
    input    prev_reset_wdt_pcl_sync,

    input    cpu_dbg_halt_sync,
    input    dbg_freeze_sync,



   // input          cfg_update_sync,  
    input   [31:0]   timeout_value_sync,
    input   [31:0]   window_value_sync,
    input   [15:0]   reset_cycles_sync,

    output reg   	  timeout_flag_apb_sync,                        
    output reg   	  window_violation_apb_sync, 
    output reg  	  reset_issued_apb_sync, 
    output reg   	  prev_reset_wdt_apb_sync,   
    output reg   	  wdt_reset_cause_apb_sync,

    output reg  	  enable_wdt_sync,
    output reg   	  reset_en_wdt_sync,
    output reg  	  window_en_wdt_sync,
    output reg  	  dbg_freeze_en_wdt_sync,

    output  	  refresh_valid_sync,
    output  	  prev_reset_wdt_pulse_sync,
    output  	  clr_f1_sync,
    output  	  clr_f2_sync,
    output  	  clr_f3_sync,

    output reg    cpu_dbg_halt_wdt_sync,
    output reg    dbg_freeze_wdt_sync,

    output reg   [31:0]  timeout_value_wdt_sync,
    output reg   [31:0]  window_value_wdt_sync,
    output reg   [15:0]  reset_cycles_wdt_sync
    
    );


reg [1:0] sync_f1,sync_f2,sync_f3;
reg       dly_f1, dly_f2, dly_f3;
//////////////////////////////////////
reg     timeout_flag_meta;      
reg     window_violation_meta;                  
reg     reset_issued_meta;    
reg     prev_reset_wdt_meta;                     
reg     wdt_reset_cause_meta; 
reg     cpu_dbg_halt_meta;
reg     dbg_freeze_meta;
////////////////////////////////////

reg  refresh_toggle_sync1;  
reg  refresh_toggle_sync2;  
reg  refresh_toggle_sync2_d;
                
reg  enable_meta;           
               
reg  reset_en_meta;         
                
reg  window_en_meta;        
                
reg  dbg_freeze_en_meta;    
                
reg  cfg_sync1;             
reg  cfg_sync2;             
reg  cfg_sync2_d;           
                
reg  prev_reset_wdt_sync1;  
reg  prev_reset_wdt_sync2;  
reg  prev_reset_wdt_sync2_d;
//////////////////////////////////////

wire 	cfg_update_sync;

////////////////////////////////////////////////////

always @(posedge pclk or negedge presetn) begin
    if(!presetn) begin

        timeout_flag_meta      <= 1'b0;
        timeout_flag_apb_sync       <= 1'b0;

        window_violation_meta  <= 1'b0;
        window_violation_apb_sync   <= 1'b0;

        reset_issued_meta      <= 1'b0;
        reset_issued_apb_sync       <= 1'b0;

        prev_reset_wdt_meta    <= 1'b0;
        prev_reset_wdt_apb_sync     <= 1'b0;

	wdt_reset_cause_meta   <= 1'b0;
    	wdt_reset_cause_apb_sync    <= 1'b0;
	
    end
    else begin

        timeout_flag_meta          <= timeout_flag_wdt_sync;
        timeout_flag_apb_sync      <= timeout_flag_meta;

        window_violation_meta      <= window_violation_wdt_sync;
        window_violation_apb_sync  <= window_violation_meta;

        reset_issued_meta          <= reset_issued_wdt_sync;
        reset_issued_apb_sync      <= reset_issued_meta;

        prev_reset_wdt_meta        <= prev_reset_wdt_wdt_sync;
        prev_reset_wdt_apb_sync    <= prev_reset_wdt_meta;

	wdt_reset_cause_meta       <= wdt_reset_cause_sync;
	wdt_reset_cause_apb_sync   <= wdt_reset_cause_meta;	 
	
    end
end

///////////////////////////////////////////////////////////////

always @(posedge wdt_clk or negedge wdt_rstn) begin
 if(!wdt_rstn) begin
	sync_f1 <= 2'b00;
	sync_f2 <= 2'b00;
	sync_f3 <= 2'b00;

	dly_f1 <= 1'b0;
	dly_f2 <= 1'b0;
	dly_f3 <= 1'b0;

end
else begin
	sync_f1 <= {sync_f1[0], status_toggle_sync1};
	sync_f2 <= {sync_f2[0], status_toggle_sync2};
	sync_f3 <= {sync_f3[0], status_toggle_sync3};

	dly_f1 <= sync_f1[1];
	dly_f2 <= sync_f2[1];
	dly_f3 <= sync_f3[1];
end
end

////////////////////////////////////////////////////////////////

always@(posedge wdt_clk or negedge wdt_rstn) begin
if(!wdt_rstn) begin
            refresh_toggle_sync1   <= 1'b0;
            refresh_toggle_sync2   <= 1'b0;
            refresh_toggle_sync2_d <= 1'b0;

            enable_meta            <= 1'b0;
            enable_wdt_sync        <= 1'b0;

            reset_en_meta          <= 1'b0;
            reset_en_wdt_sync      <= 1'b0;

            window_en_meta         <= 1'b0;
            window_en_wdt_sync     <= 1'b0;

            dbg_freeze_en_meta     <= 1'b0;
            dbg_freeze_en_wdt_sync <= 1'b0;

            cfg_sync1              <= 1'b0;
            cfg_sync2              <= 1'b0;
            cfg_sync2_d            <= 1'b0;

	        prev_reset_wdt_sync1   <= 1'b0;
	        prev_reset_wdt_sync2   <= 1'b0; 
	        prev_reset_wdt_sync2_d <= 1'b0; 
            

            cpu_dbg_halt_meta      <= 1'b0;
            cpu_dbg_halt_wdt_sync  <= 1'b0;

            dbg_freeze_meta        <= 1'b0;
            dbg_freeze_wdt_sync    <= 1'b0;
	
    end
    else begin

           refresh_toggle_sync1   <= refresh_toggle_sync;
           refresh_toggle_sync2   <= refresh_toggle_sync1;
           refresh_toggle_sync2_d <= refresh_toggle_sync2;

           enable_meta            <= enable_sync;
           enable_wdt_sync        <= enable_meta;

           reset_en_meta          <= reset_en_sync;
           reset_en_wdt_sync      <= reset_en_meta;

           window_en_meta         <= window_en_sync;
           window_en_wdt_sync     <= window_en_meta;

           dbg_freeze_en_meta     <= dbg_freeze_en_sync;
           dbg_freeze_en_wdt_sync <= dbg_freeze_en_meta;

           cfg_sync1              <= cfg_toggle_sync;
           cfg_sync2              <= cfg_sync1;
           cfg_sync2_d            <= cfg_sync2;


           prev_reset_wdt_sync1   <= prev_reset_wdt_pcl_sync;
	       prev_reset_wdt_sync2   <= prev_reset_wdt_sync1;
           prev_reset_wdt_sync2_d <= prev_reset_wdt_sync2;

           cpu_dbg_halt_meta      <= cpu_dbg_halt_sync;
           cpu_dbg_halt_wdt_sync  <= cpu_dbg_halt_meta;

           dbg_freeze_meta        <= dbg_freeze_sync;
           dbg_freeze_wdt_sync    <= dbg_freeze_meta;
    
        end   
end

///////////////////////////////////////////////////////////////////////////////

always@(posedge wdt_clk or negedge wdt_rstn) begin
    if(!wdt_rstn) begin
            timeout_value_wdt_sync       <= 32'h0000FFFF;
            window_value_wdt_sync        <= 32'h00000000;
            reset_cycles_wdt_sync        <= 16'd32;

        end

        else begin
            if(cfg_update_sync) begin
                timeout_value_wdt_sync   <= timeout_value_sync;
                window_value_wdt_sync    <= window_value_sync;
                reset_cycles_wdt_sync    <= reset_cycles_sync;
                end

            end
end

////////////////////////////////////////////////////////////////////////////

assign refresh_valid_sync = refresh_toggle_sync2 ^ refresh_toggle_sync2_d;

assign cfg_update_sync = cfg_sync2 ^ cfg_sync2_d;

assign prev_reset_wdt_pulse_sync = prev_reset_wdt_sync2 ^ prev_reset_wdt_sync2_d;

assign clr_f1_sync = dly_f1 ^ sync_f1[1];

assign clr_f2_sync = dly_f2 ^ sync_f2[1];

assign clr_f3_sync = dly_f3 ^ sync_f3[1];


endmodule
