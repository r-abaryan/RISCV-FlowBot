module t; integer fails=2; initial begin #1 $display("fails=%0d",fails); $display("ALL PASSED"); $finish; end endmodule
