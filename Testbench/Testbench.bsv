package Testbench;

import  branch :: *;
import  Utils :: *;

Bit#(3) gv_count=5;

(*synthesize*)
module mkTestbench(Empty);
	Ifc_branch branch <- mkbranch;
	Reg#(Gv_pc) test_pc <- mkReg(0);
	Wire#(Bit#(23)) test_predict <- mkWire;
	Reg#(Bit#(3)) lv_count <- mkReg(0);
	rule rl_input(lv_count<gv_count);
		branch.ma_put(test_pc);	
		lv_count<= lv_count+1;
		test_pc<= test_pc+1;
	endrule
	rule rl_output(lv_count<gv_count);
		test_predict<= branch.mn_get();
	endrule

	rule rl_predict(lv_count<gv_count);
		branch.ma_train({test_pc,test_predict});
	endrule

	rule rl_display(lv_count<gv_count);
		$display("%0d:%0d",cur_cycle,test_predict);
	endrule

	rule rl_end(lv_count==gv_count);
		$finish;
	endrule
endmodule 
endpackage
