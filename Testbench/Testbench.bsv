package Testbench;

import  branch :: *;
import  Utils :: *;

Bit#(4) gv_count=15;

(*synthesize*)
module mkTestbench(Empty);
	Ifc_branch branch <- mkbranch;
	Reg#(Gv_pc) test_pc <- mkReg(0);
	Wire#(Bit#(23)) test_predict <- mkWire;
	Reg#(Bit#(4)) lv_count <- mkReg(0);

	rule rl_input(lv_count<gv_count);
		branch.ma_put(test_pc);		
	endrule

	rule rl_output(lv_count<gv_count && lv_count>=1);
		test_predict<= branch.mn_get();
	endrule

	rule rl_train(lv_count<gv_count && lv_count>=1);
		if(lv_count==1)
			branch.ma_train(test_pc-1,False,test_predict[22],test_predict[21:19],test_predict[18:11],test_predict[10:6],test_predict[5:3],test_predict[2:0]);	
		else
			branch.ma_train(test_pc-1,True,test_predict[22],test_predict[21:19],test_predict[18:11],test_predict[10:6],test_predict[5:3],test_predict[2:0]);	
	endrule

	rule rl_count(lv_count<gv_count);
		lv_count<= lv_count+1;
		test_pc<= test_pc+1;
	endrule

	rule rl_display(lv_count<gv_count);
		$display("%0d:%0d",cur_cycle,test_predict[22]);
	endrule

	rule rl_end(lv_count==gv_count);
		$finish;
	endrule
endmodule 
endpackage
