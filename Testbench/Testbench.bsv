package Testbench;

import  branch :: *;
import  Utils :: *;
import  BRAMCore :: *;

`define READ False

Bit#(13) gv_count=4096;
String gv_file_pc="branch_pc.dump";
String gv_file_truth="branch_taken.dump";


(*synthesize*)
module mkTestbench(Empty);
	Ifc_branch branch <- mkbranch;
	BRAM_PORT#(Bit#(16),Bit#(40)) bram_pc <- mkBRAMCore1Load(64000,False,gv_file_pc,False);
	BRAM_PORT#(Bit#(16),Bit#(32)) bram_truth <- mkBRAMCore1Load(64000,False,gv_file_truth,True);
	Reg#(Bit#(16)) rg_pc_addr <- mkReg(0);
	Wire#(Bit#(40)) wr_pc <- mkWire;
	Reg#(Bit#(40)) rg_pc <- mkReg(0);
	Reg#(Bit#(16)) rg_truth_addr <- mkReg(0);
	Wire#(Bit#(32)) wr_truth <- mkWire;

	Wire#(Bit#(23)) test_predict <- mkWire;
	Reg#(Bit#(3)) lv_state <- mkReg(0);
	Reg#(Bit#(13)) lv_count <- mkReg(0);
	Reg#(Bit#(16)) mispredict <- mkReg(0);

	rule rl_flush(lv_state==0);
		branch.ma_flush();
		lv_state<= 1;
	endrule

	rule rl_wait(lv_state==1);
		lv_count<=lv_count+1;
		if(lv_count==gv_count)
			lv_state<= 2;
	endrule

	rule rl_read(lv_state==2);
		bram_pc.put(`READ,rg_pc_addr,?);
		rg_pc_addr<= rg_pc_addr+1;
		//$display("At 2");
		lv_state<= 3;
	endrule

	rule rl_brampc(lv_state==3);
		wr_pc<= bram_pc.read();
		//wr_truth<= bram_truth.read();
	endrule

	rule rl_put(lv_state==3);
		Bit#(24) lv_gnd=0;
		bram_truth.put(`READ,rg_truth_addr,?);
		branch.ma_put({lv_gnd,wr_pc});
		rg_pc<= wr_pc;
		lv_state<= 4;
		//$display("At 3");
		rg_truth_addr<= rg_truth_addr+1;
	endrule	

	rule rl_bramtruth(lv_state==4);
		wr_truth<= bram_truth.read();
	endrule
	
	rule rl_output(lv_state==4);
		test_predict<= branch.mn_get();
	endrule

	
	rule rl_train_check(lv_state==4);
		Bit#(24) lv_gnd=0;
		//$display("At 4");
		if(test_predict[22]!=wr_truth[0])
		begin
			mispredict<= mispredict+1;
			branch.ma_train({lv_gnd,rg_pc},False,test_predict[22],test_predict[21:19],test_predict[18:11],test_predict[10:6],test_predict[5:3],test_predict[2:0]);
		end
		else
			branch.ma_train({lv_gnd,rg_pc},True,test_predict[22],test_predict[21:19],test_predict[18:11],test_predict[10:6],test_predict[5:3],test_predict[2:0]);
		lv_state<= 2;
	endrule

	/*rule rl_display(lv_count<gv_count);
		$display("%0d:%0d",cur_cycle,lv_count);
	endrule*/

	rule rl_end(rg_pc_addr==100);
		$display("%0d",mispredict);
		$finish;
	endrule

endmodule 
endpackage
