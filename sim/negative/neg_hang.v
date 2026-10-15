module t; reg c=0; always #1 c=~c; initial begin #10 $display("never finishes"); end endmodule
