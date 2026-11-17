`timescale 1ns/1ps
module tb;
  logic clk = 0; always #5 clk = ~clk;
  logic [1:0][63:0] raddr_n, raddr; logic [1:0][63:0] rdata;
  logic [1:0] we = 0; logic [1:0][63:0] waddr = '0, wdata = '0; logic [1:0][7:0] wmask = '0;
  logic host_we = 0; logic [63:0] host_waddr = 0; logic [31:0] host_wdata = 0; logic [3:0] host_wmask = 0;
  int errs = 0;
  glbl glbl();
  mm_dmem dut(.clk, .\raddr_n[1] (raddr_n[1]), .\raddr_n[0] (raddr_n[0]), .\raddr[1] (raddr[1]), .\raddr[0] (raddr[0]),
    .\rdata[1] (rdata[1]), .\rdata[0] (rdata[0]), .we, .\waddr[1] (waddr[1]), .\waddr[0] (waddr[0]),
    .\wdata[1] (wdata[1]), .\wdata[0] (wdata[0]), .\wmask[1] (wmask[1]), .\wmask[0] (wmask[0]),
    .host_we, .host_waddr, .host_wdata, .host_wmask);
  task automatic hw(input [63:0] a, input [31:0] d);
    @(negedge clk); host_we = 1; host_waddr = a; host_wdata = d; host_wmask = 4'hF;
    @(negedge clk); host_we = 0;
  endtask
  task automatic cw(input [63:0] a, input [63:0] d, input [7:0] m);   // core write on port a[3]
    @(negedge clk); we = 0; we[0] = 1; waddr[0] = a; wdata[0] = d; wmask[0] = m;
    @(negedge clk); we = 0;
  endtask
  task automatic rd(input int p, input [63:0] a, input [63:0] exp, input string what);
    @(negedge clk); raddr_n[p] = a;
    @(negedge clk); raddr[p] = a;
    #1;
    if (rdata[p] !== exp) begin errs++; $display("FAIL %s port%0d addr %h: got %h want %h", what, p, a, rdata[p], exp); end
    else $display("ok   %s port%0d addr %h: %h", what, p, a, rdata[p]);
  endtask
  initial begin
    raddr_n = '0; raddr = '0;
    #300;   // GSR
    hw(64'h00, 32'hCAFEBABE); hw(64'h04, 32'h11223344);       // word 0 (bank 0), lo+hi
    hw(64'h08, 32'hDEADBEEF);                                  // word 1 (bank 1) lo
    hw(64'h108, 32'h0BADF00D);                                 // word 0x21 (bank 1) lo
    cw(64'h40, 64'h0123456789ABCDEF, 8'hFF);                   // core, word 8 (bank 0)
    cw(64'h48, 64'h00000000_0000A5A5, 8'h03);                  // core, partial, word 9 (bank 1)
    for (int p = 0; p < 2; p++) begin
      rd(p, 64'h00,  64'h11223344CAFEBABE, "host w0   ");
      rd(p, 64'h08,  64'h00000000DEADBEEF, "host w1   ");
      rd(p, 64'h108, 64'h000000000BADF00D, "host w21  ");
      rd(p, 64'h40,  64'h0123456789ABCDEF, "core w8   ");
      rd(p, 64'h48,  64'h000000000000A5A5, "core w9   ");
    end
    $display("ERRORS %0d", errs);
    $finish;
  end
endmodule
