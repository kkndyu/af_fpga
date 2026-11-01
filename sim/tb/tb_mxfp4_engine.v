`timescale 1ns/1ps
module tb_mxfp4_engine;
    reg clk=0, rst_n=0, start=0;
    always #2.5 clk=~clk;
    reg we=0, ae=0, se=0;
    reg [1:0] bank=0, sbank=0;
    reg [9:0] wa=0, aa=0;
    reg [255:0] wd=0;
    reg [15:0] ad=0;
    reg [10:0] sa=0;
    reg [7:0] sd=0;
    wire busy,done;
    wire [8191:0] results;
    reg [255:0] weights[0:4095];
    reg [511:0] scales[0:127];
    reg [15:0] activation[0:1023];
    reg [31:0] reference[0:255];
    integer r,k,j,cycles,errors=0;
    mxfp4_gemv_engine #(.K_LEN(64),.K_ADDR_W(10)) dut (
        .clk(clk),.rst_n(rst_n),.start(start),.busy(busy),.done(done),
        .w_wr_en(we),.w_wr_region(bank),.w_wr_addr(wa),.w_wr_data(wd),
        .act_wr_en(ae),.act_wr_addr(aa),.act_wr_data(ad),
        .scale_wr_en(se),.scale_wr_region(sbank),.scale_wr_addr(sa),.scale_wr_data(sd),
        .rb_start(1'b0),.rb_region(2'd0),.rb_addr(10'd0),.rb_nrows(16'd0),.rb_byte_ready(1'b1),
        .rb_byte_out(),.rb_byte_valid(),.rb_done(),.acc_flat(results));
    task run_check;
        begin
            @(negedge clk); start=1;
            @(negedge clk); start=0;
            cycles=0;
            while(!done && cycles<4000) begin @(negedge clk); cycles=cycles+1; end
            if(!done) $fatal(1,"MXFP4 engine timed out");
            for(j=0;j<256;j=j+1) if(results[j*32 +: 32] !== reference[j]) begin
                if(errors<12) $display("MXFP4 FAIL lane=%0d got=%h expected=%h",j,results[j*32 +: 32],reference[j]);
                errors=errors+1;
            end
            $display("MXFP4 ENGINE: 64 inputs, 256 lanes, %0d cycles, cumulative errors=%0d",cycles,errors);
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
        repeat(4) @(negedge clk); rst_n=1;
        for(r=0;r<4;r=r+1) for(k=0;k<64;k=k+1) begin
            @(negedge clk); we=1; bank=r;wa=k;wd=weights[r*1024+k];
        end
        @(negedge clk);we=0;
        for(k=0;k<64;k=k+1) begin @(negedge clk);ae=1;aa=k;ad=activation[k];end
        @(negedge clk);ae=0;
        for(r=0;r<4;r=r+1) for(k=0;k<2;k=k+1) for(j=0;j<64;j=j+1) begin
            @(negedge clk);se=1;sbank=r;sa=k*64+j;sd=scales[r*32+k][j*8 +: 8];
        end
        @(negedge clk);se=0;
        `ifdef MOE_MXFP4_FP32
    $readmemh("build/mxfp4_vectors/ref_64_fp32.hex",reference);
`else
    $readmemh("build/mxfp4_vectors/ref_64.hex",reference);
`endif
        run_check;
        @(negedge clk);se=1;sbank=0;sa=64+9;sd=scales[1][9*8 +: 8]+3;
        @(negedge clk);se=0;
        `ifdef MOE_MXFP4_FP32
    $readmemh("build/mxfp4_vectors/ref_64_changed_fp32.hex",reference);
`else
    $readmemh("build/mxfp4_vectors/ref_64_changed.hex",reference);
`endif
        run_check;
        // Reset control while retaining loaded memories, then test +/-Inf and
        // Inf*zero/NaN propagation alongside the invalid E8M0 scale case.
        @(negedge clk);rst_n=0;
        repeat(4) @(negedge clk);rst_n=1;
        @(negedge clk);ae=1;aa=0;ad=16'h7f80;
        @(negedge clk);aa=1;ad=16'hff80;
        @(negedge clk);ae=0;
        `ifdef MOE_MXFP4_FP32
    $readmemh("build/mxfp4_vectors/ref_64_special_fp32.hex",reference);
`else
    $readmemh("build/mxfp4_vectors/ref_64_special.hex",reference);
`endif
        run_check;
        if(errors) $fatal(1,"MXFP4 engine has %0d mismatches",errors);
        $display("MXFP4 ENGINE: ALL TESTS PASSED");$finish;
    end
endmodule
