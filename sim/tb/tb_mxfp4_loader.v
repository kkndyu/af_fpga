`timescale 1ns/1ps
`include "moe_params.vh"
module tb_mxfp4_loader;
    reg clk=0,rst_n=0;
    always #2.5 clk=~clk;
    reg [7:0] tx_data=0;
    reg tx_valid=0;
    wire tx_ready;
    wire [7:0] rx_data;
    wire rx_valid,rx_last;
    reg rx_ready=1,slow=0;
    reg [3:0] divider=0;
    wire we,ae,se,start,engine_busy,engine_done;
    wire [1:0] wb,sb;
    wire [9:0] wa,aa;
    wire [255:0] wd;
    wire [15:0] ad;
    wire [10:0] sa;
    wire [7:0] sd;
    wire rd_start,rd_pause,rd_valid,rd_busy,rb_start,rb_ready,rb_valid,rb_done;
    wire [7:0] rd_lane,rd_data,rb_data;
    wire [7:0] rd_lane_start;
    wire [1:0] rd_byte,rb_region;
    wire [9:0] rb_addr;
    wire [15:0] rb_nrows;
    wire weights_ready,act_valid,busy;
    wire [7:0] err;
    reg [255:0] weights[0:4095];
    reg [511:0] scales[0:127];
    reg [15:0] activation[0:1023];
    reg [31:0] reference[0:255];
    reg [7:0] received[0:8191];
    reg [7:0] crc;
    integer rx_count=0,last_count=0,last_index=-1,errors=0;
    integer bank,row,lane,octet,cycles,run;
    reg [31:0] actual;
    moe_loader loader(.clk(clk),.rst_n(rst_n),.s_axis_tdata(tx_data),.s_axis_tvalid(tx_valid),.s_axis_tready(tx_ready),.s_axis_tlast(1'b0),
        .m_axis_tdata(rx_data),.m_axis_tvalid(rx_valid),.m_axis_tready(rx_ready),.m_axis_tlast(rx_last),
        .w_wr_en(we),.w_wr_region(wb),.w_wr_addr(wa),.w_wr_data(wd),.a_wr_en(ae),.a_wr_addr(aa),.a_wr_data(ad),
        .scale_wr_en(se),.scale_wr_region(sb),.scale_wr_addr(sa),.scale_wr_data(sd),
        .gemv_start(start),.gemv_busy(engine_busy),.gemv_done(engine_done),
        .rd_start(rd_start),.rd_start_lane(rd_lane_start),.rd_pause(rd_pause),.rd_valid(rd_valid),.rd_lane(rd_lane),.rd_byte(rd_byte),.rd_data(rd_data),.rd_busy(rd_busy),
        .rb_start(rb_start),.rb_region(rb_region),.rb_addr(rb_addr),.rb_nrows(rb_nrows),.rb_byte_ready(rb_ready),.rb_byte_out(rb_data),.rb_byte_valid(rb_valid),.rb_done(rb_done),
        .weights_ready(weights_ready),.act_valid(act_valid),.busy(busy),.eth_dbg(32'd0),.err_code(err));
    moe_proto_top top(.clk(clk),.rst_n(rst_n),.start(start),.busy(engine_busy),.done(engine_done),
        .w_wr_en(we),.w_wr_region(wb),.w_wr_addr(wa),.w_wr_data(wd),.act_wr_en(ae),.act_wr_addr(aa),.act_wr_data(ad),
        .scale_wr_en(se),.scale_wr_region(sb),.scale_wr_addr(sa),.scale_wr_data(sd),
        .rb_start(rb_start),.rb_region(rb_region),.rb_addr(rb_addr),.rb_nrows(rb_nrows),.rb_byte_ready(rb_ready),.rb_byte_out(rb_data),.rb_byte_valid(rb_valid),.rb_done(rb_done),
        .rd_start(rd_start),.rd_start_lane(rd_lane_start),.rd_pause(rd_pause),.rd_valid(rd_valid),.rd_lane(rd_lane),.rd_byte(rd_byte),.rd_data(rd_data),.rd_busy(rd_busy),.result_checksum());
    always @(posedge clk) begin
        divider<=divider+1'b1;
        rx_ready<=!slow || divider==0;
        if(rx_valid && rx_ready) begin
            if(rx_count<8192) received[rx_count]=rx_data;
            if(rx_last) begin last_count=last_count+1;last_index=rx_count;end
            rx_count=rx_count+1;
        end
    end
    function [7:0] crc8;
        input [7:0] c,d;
        integer n;reg [7:0] v;
        begin v=c^d;for(n=0;n<8;n=n+1) v=v[7]?((v<<1)^8'h07):(v<<1);crc8=v;end
    endfunction
    task put(input [7:0] value);
        begin @(negedge clk);tx_data=value;tx_valid=1;@(posedge clk);while(!tx_ready) @(posedge clk);@(negedge clk);tx_valid=0;end
    endtask
    task putc(input [7:0] value);
        begin put(value);crc=crc8(crc,value);end
    endtask
    task frame(input [7:0] command,input [15:0] length);
        begin rx_count=0;last_count=0;last_index=-1;put(8'ha5);crc=0;putc(command);putc(length[15:8]);putc(length[7:0]);end
    endtask
    task end_frame(input corrupt);
        begin put(crc ^ (corrupt ? 8'h01:8'h00));repeat(10) @(negedge clk);end
    endtask
    task wait_reply(input integer count);
        integer n;
        begin n=0;while(rx_count<count && n<60000) begin @(negedge clk);n=n+1;end
            repeat(10) @(negedge clk);
            if(rx_count!=count || last_count!=1 || last_index!=count-1)
                $fatal(1,"Reply length/last failure count=%0d expected=%0d last_count=%0d last_index=%0d",rx_count,count,last_count,last_index);
        end
    endtask
    task status(input [7:0] expected_error,input expected_ready);
        begin frame(4,0);end_frame(0);wait_reply(8);
            if(received[0] !== {7'd0,expected_ready} || received[2] !== expected_error)
                $fatal(1,"STATUS ready=%h err=%h expected ready=%b err=%h",received[0],received[2],expected_ready,expected_error);
        end
    endtask
    task scale_frame(input integer region,input integer block,input corrupt,input integer length,input change);
        integer n;
        reg [7:0] value;
        begin frame(8,length);putc(region);putc(0);putc(block);
            for(n=0;n<length-3;n=n+1) begin
                value=scales[region*32+(block%32)][n*8 +: 8];
                if(change && n==11) value=value+1'b1;
                putc(value);
            end
            end_frame(corrupt);
        end
    endtask
    initial begin
        $readmemh("build/mxfp4_vectors/activation.mem",activation);
        $readmemh("build/mxfp4_vectors/weight_r0.mem",weights,0,1023);
        $readmemh("build/mxfp4_vectors/weight_r1.mem",weights,1024,2047);
        $readmemh("build/mxfp4_vectors/weight_r2.mem",weights,2048,3071);
        $readmemh("build/mxfp4_vectors/weight_r3.mem",weights,3072,4095);
        $readmemh("build/mxfp4_vectors/scale_r0.mem",scales,0,31);
        $readmemh("build/mxfp4_vectors/scale_r1.mem",scales,32,63);
        $readmemh("build/mxfp4_vectors/scale_r2.mem",scales,64,95);
        $readmemh("build/mxfp4_vectors/scale_r3.mem",scales,96,127);
        repeat(6) @(negedge clk);rst_n=1;
        status(0,0);frame(7,0);end_frame(0);status(5,0);
        for(bank=0;bank<4;bank=bank+1) begin
            frame(1,32771);putc(bank);putc(0);putc(0);
            for(row=0;row<1024;row=row+1) for(octet=0;octet<32;octet=octet+1) putc(weights[bank*1024+row][255-octet*8 -: 8]);
            end_frame(0);status(0,0);
        end
        frame(7,0);end_frame(0);status(5,0);
        scale_frame(0,0,0,66,0);status(4,0);
        scale_frame(0,32,0,67,0);status(4,0);
        for(bank=0;bank<4;bank=bank+1) for(row=0;row<32;row=row+1) scale_frame(bank,row,0,67,0);
        frame(7,0);end_frame(0);status(0,1);
        scale_frame(3,31,1,67,0);status(1,0);
        frame(7,0);end_frame(0);status(5,0);
        scale_frame(3,31,0,67,0);frame(7,0);end_frame(0);status(0,1);
        $display("MXFP4 LOADER: scale completeness, bounds, CRC invalidation and COMMIT passed");
        frame(2,2050);putc(0);putc(0);
        for(row=0;row<1024;row=row+1) begin putc(activation[row][15:8]);putc(activation[row][7:0]);end
        end_frame(0);status(0,1);
        for(run=0;run<2;run=run+1) begin
            if(run==0) $readmemh("build/mxfp4_vectors/ref_1024.hex",reference);
            else begin
                scale_frame(0,0,0,67,1);status(0,0);
                frame(7,0);end_frame(0);status(0,1);
                $readmemh("build/mxfp4_vectors/ref_1024_changed.hex",reference);
            end
            frame(3,0);end_frame(0);
            cycles=0;
            while(engine_busy && cycles<60000) begin @(negedge clk);cycles=cycles+1;end
            if(engine_busy) $fatal(1,"Full MXFP4 GEMV timeout");
            $display("MXFP4 LOADER: GEMV run %0d completed after %0d observed cycles",run,cycles);
            slow=1;frame(5,2);putc(0);putc(255);end_frame(0);wait_reply(1024);slow=0;
            for(lane=0;lane<256;lane=lane+1) begin
                actual={received[lane*4+3],received[lane*4+2],received[lane*4+1],received[lane*4]};
                if(actual !== reference[lane]) begin
                    if(errors<10) $display("MXFP4 LOADER FAIL lane=%0d got=%h expected=%h",lane,actual,reference[lane]);
                    errors=errors+1;
                end
            end
            $display("MXFP4 LOADER: run %0d compared all 256 FP32 outputs; errors=%0d",run,errors);
        end
        frame(6,4);putc(2);putc(0);putc(0);putc(31);end_frame(0);wait_reply(1024);
        for(octet=0;octet<1024;octet=octet+1)
            if(received[octet] !== weights[2048+octet/32][255-(octet%32)*8 -: 8]) errors=errors+1;
        if(errors) $fatal(1,"MXFP4 loader regression has %0d mismatches",errors);
        $display("MXFP4 LOADER: ALL TESTS PASSED");$finish;
    end
endmodule
