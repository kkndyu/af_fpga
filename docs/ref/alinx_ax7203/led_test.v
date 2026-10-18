//===========================================================================
// Module name: led_test.v
//===========================================================================
`timescale 1ns / 1ps
module led_test 
(  
sys_clk_p,          //system clock positive
sys_clk_n,          //system clock negative
rst_n,              // reset ,low active            
led                 // LED,use for control the LED signal on board
);            
//===========================================================================
// PORT declarations
//===========================================================================
input           sys_clk_p;
input           sys_clk_n;
input           rst_n;
output [3:0]    led;

//define the time counter
reg [31:0]      timer;                  
reg [3:0]       led;
wire            sys_clk;          

IBUFDS sys_clk_ibufgds
(
.O              (sys_clk                  ),
.I              (sys_clk_p                ),
.IB             (sys_clk_n                )
);
//===========================================================================
// cycle counter:from 0 to 1sec
//===========================================================================
always @(posedge sys_clk or negedge rst_n)    
begin
  if (~rst_n)                           
      timer <= 32'd0;                     // when the reset signal valid,time counter clearing
  else if (timer == 32'd199_999_999)    //4 seconds count(200M-1=199999999)
      timer <= 32'd0;                       //count done,clearing the time counter
  else
      timer <= timer + 1'b1;            //timer counter = timer counter + 1
end
//===========================================================================
// LED control
//===========================================================================
always @(posedge sys_clk or negedge rst_n)   
begin
  if (~rst_n)                      
      led <= 4'b0000;                  //when the reset signal active         
  else if (timer == 32'd49_999_999)    //time counter count to 0.25 sec,LED1 lighten 
      led <= 4'b1110;                 
  else if (timer == 32'd99_999_999)    //time counter count to 0.5 sec,LED2lighten
  begin
      led <= 4'b1101;                  
    end
  else if (timer == 32'd149_999_999)   //time counter count to 0.75 sec,LED3 lighten
      led <= 4'b1011;                                          
  else if (timer == 32'd199_999_999)   //time counter count to 1 sec,LED4 lighten
      led <= 4'b0111;                         
end   
endmodule