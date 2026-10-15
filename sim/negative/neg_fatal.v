module t; initial begin #1 $display("x"); $fatal(1,"boom"); end endmodule
