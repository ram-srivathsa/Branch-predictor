package branch;

import BRAMCore :: *;

`define SIZE_BIMODAL 4096  //size of the tables
`define SIZE_GLOBAL 1024
`define BIMODAL_MAX_ADDR 4095
`define GLOBAL_MAX_ADDR 1023
`define DATA_SIZE_BIMODAL 4
`define DATA_SIZE_GLOBAL 12
`define TAG_SIZE 8
`define HIST_SIZE 80 //no. of history bits
`define PC_SIZE 64
`define BANK_BITS 3
`define WRITE True
`define READ False
`define COUNTER_SIZE 3

//for debugging
String gv_file0="bimodal.bin";
String gv_file1="bank1.bin";
String gv_file2="bank2.bin";
String gv_file3="bank3.bin";
String gv_file4="bank4.bin";
//

typedef Bit#(TLog#(`SIZE_BIMODAL)) Gv_bimodal_addr;
typedef Bit#(TLog#(`SIZE_GLOBAL)) Gv_global_addr;
typedef Bit#(`DATA_SIZE_BIMODAL) Gv_bimodal_data;
typedef Bit#(`DATA_SIZE_GLOBAL) Gv_global_data;
typedef Bit#(`TAG_SIZE) Gv_tag;
typedef Bit#(`HIST_SIZE) Gv_hist;
typedef Bit#(`PC_SIZE) Gv_pc;
typedef Bit#(TSub#(`TAG_SIZE,1)) Gv_secondary_csr;
typedef Bit#(`BANK_BITS) Gv_bank_num;
typedef Bit#(`COUNTER_SIZE) Gv_counter;


//functions
//compares tag with hash function output
function Bool fn_compare(Gv_tag x,Gv_tag y);
	return (x==y)?True:False;
endfunction 


//hash functions
function Gv_global_addr fn_hash_indx(Bit#(20) pc,Bit#(10) csr);
	return pc[9:0]^pc[19:10]^csr;
endfunction


function Gv_tag fn_hash_tag(Bit#(8) pc,Bit#(8) csr1,Bit#(7) csr2);
	return pc^csr1^{csr2,1'b0};
endfunction


//interface
interface Ifc_branch;
	//enters pc into module,performs hash and initiates bram requests
	method Action ma_put(Gv_pc pc);
	//returns the prediction result
	method Bit#(23) mn_get;
	//to train the predictor
	method Action ma_train(Gv_pc pc,Bool truth,Bit#(1) prediction,Gv_counter counter,Gv_tag tag,Bit#(5) bank_bits,Gv_bank_num bank_no,Gv_counter bimodal);
	//to initialize the predictor banks at any time
	method Action ma_flush;
endinterface


//module
(*synthesize*)
module mkbranch(Ifc_branch);
	//port 'a' for read and port 'b' for write
	BRAM_DUAL_PORT#(Gv_bimodal_addr,Gv_bimodal_data) bram_bimodal <- mkBRAMCore2Load(`SIZE_BIMODAL,False,gv_file0,True);
	BRAM_DUAL_PORT#(Gv_global_addr,Gv_global_data) bram_bank1 <- mkBRAMCore2Load(`SIZE_GLOBAL,False,gv_file1,True);
	BRAM_DUAL_PORT#(Gv_global_addr,Gv_global_data) bram_bank2 <- mkBRAMCore2Load(`SIZE_GLOBAL,False,gv_file2,True);
	BRAM_DUAL_PORT#(Gv_global_addr,Gv_global_data) bram_bank3 <- mkBRAMCore2Load(`SIZE_GLOBAL,False,gv_file3,True);
	BRAM_DUAL_PORT#(Gv_global_addr,Gv_global_data) bram_bank4 <- mkBRAMCore2Load(`SIZE_GLOBAL,False,gv_file4,True);
	//outputs of the banks
	Wire#(Gv_bimodal_data) wr_bimodal_out <- mkWire();
	Wire#(Gv_global_data) wr_bank1_out <- mkWire();
	Wire#(Gv_global_data) wr_bank2_out <- mkWire();
	Wire#(Gv_global_data) wr_bank3_out <- mkWire();
	Wire#(Gv_global_data) wr_bank4_out <- mkWire();
	//copy of incoming pc for update stages
	Reg#(Gv_pc) rg_pc_copy <- mkReg(0);
	//to control flushing operation
	Reg#(Bool) rg_flush <- mkReg(False);
	Reg#(Gv_bimodal_addr) rg_bimodal_flush_addr <- mkReg(0);
	Reg#(Gv_global_addr) rg_global_flush_addr <- mkReg(0);

	//global history
	Reg#(Gv_hist) rg_global_history <- mkReg(0);
	//csrs for hash functions
	//primary csrs for tag calculation
	Reg#(Gv_tag) rg_bank1_csr_p <- mkReg(0);
	Reg#(Gv_tag) rg_bank2_csr_p <- mkReg(0);
	Reg#(Gv_tag) rg_bank3_csr_p <- mkReg(0);
	Reg#(Gv_tag) rg_bank4_csr_p <- mkReg(0);
	//secondary csrs for tag calculation
	Reg#(Gv_secondary_csr) rg_bank1_csr_s <- mkReg(0);
	Reg#(Gv_secondary_csr) rg_bank2_csr_s <- mkReg(0);
	Reg#(Gv_secondary_csr) rg_bank3_csr_s <- mkReg(0);
	Reg#(Gv_secondary_csr) rg_bank4_csr_s <- mkReg(0);
	//csrs for index calculation
	Reg#(Gv_global_addr) rg_bank2_csr_indx <- mkReg(0);
	Reg#(Gv_global_addr) rg_bank3_csr_indx <- mkReg(0);
	Reg#(Gv_global_addr) rg_bank4_csr_indx <- mkReg(0);

	//final prediction bit; 1 if branch taken is the prediction and 0 otherwise
	Wire#(Bit#(1)) wr_prediction <- mkWire;
	//counter value of matching bank
	Wire#(Gv_counter) wr_counter <- mkWire;
	//m and u bits of all banks; bank_bits[4] is bimodal m bit, bank_bits[3] is for bank 1 u bit, bank_bits[2] is for bank2 and so on
	Wire#(Bit#(5)) wr_bank_bits <- mkWire;	
	//tag value of matching bank
	Wire#(Gv_tag) wr_tag <- mkWire;
	//bank number of matching bank
	Wire#(Gv_bank_num) wr_bank_num <- mkWire;
	//counter value of bank 0
	Wire#(Gv_counter) wr_bimodal_counter <- mkWire;

	//rule to perform the complete prediction; computes hash outputs,performs comparisons and muxing(through if else tree)
	//updates the counter value of matching bank as well as m,u bits of all banks and the bank no. of matching bank
	rule rl_predict;
		Bool lv_compare1=fn_compare(wr_bank1_out[8:1], fn_hash_tag(rg_pc_copy[7:0],rg_bank1_csr_p,rg_bank1_csr_s)); //compare tag output of bank 4 with hash function output at bank 4
		Bool lv_compare2=fn_compare(wr_bank2_out[8:1], fn_hash_tag(rg_pc_copy[7:0],rg_bank2_csr_p,rg_bank2_csr_s)); //compare tag output of bank 3 with hash function output at bank 3
		Bool lv_compare3=fn_compare(wr_bank3_out[8:1], fn_hash_tag(rg_pc_copy[7:0],rg_bank3_csr_p,rg_bank3_csr_s)); //compare tag output of bank 2 with hash function output at bank 2
		Bool lv_compare4=fn_compare(wr_bank4_out[8:1], fn_hash_tag(rg_pc_copy[7:0],rg_bank4_csr_p,rg_bank4_csr_s)); //compare tag output of bank 1 with hash function output at bank 1
		
		wr_bank_bits<= {wr_bimodal_out[0],wr_bank1_out[0],wr_bank2_out[0],wr_bank3_out[0],wr_bank4_out[0]};
		wr_bimodal_counter<= wr_bimodal_out[3:1];
		if (lv_compare4)   
		begin             
			wr_prediction<= wr_bank4_out[11];     //for type conversion from Bit#(1) to Bool	
			wr_counter<= wr_bank4_out[11:9];
			wr_tag<= wr_bank4_out[8:1];
			wr_bank_num<= 3'b100;
		end

		else 
		begin
			if(lv_compare3) 
			begin
				wr_prediction<= wr_bank3_out[11];			
				wr_counter<= wr_bank3_out[11:9];
				wr_tag<= wr_bank3_out[8:1];
				wr_bank_num<= 3'b011;
			end

			else 
			begin
				if(lv_compare2) 
				begin
					wr_prediction<= wr_bank2_out[11]; 		
					wr_counter<= wr_bank2_out[11:9];
					wr_tag<= wr_bank2_out[8:1];
					wr_bank_num<= 3'b010;
				end

				else 
				begin
					if(lv_compare1) 
					begin
						wr_prediction<= wr_bank1_out[11];	
						wr_counter<= wr_bank1_out[11:9];
						wr_tag<= wr_bank1_out[8:1];
						wr_bank_num<= 3'b001;
					end
	
					else                                                                                          //none of the tags match
					begin						
						wr_prediction<= wr_bimodal_out[3];	
						wr_counter<= wr_bimodal_out[3:1];
						wr_tag<= ?;
						wr_bank_num<= 3'b000;
					end                                                     
				end
			end
		end
		
	endrule


	//reads bram outputs onto the wires; separate rule used instead of putting it in ma_put to prevent scheduling issues if any
	rule rl_read_bram;
		wr_bimodal_out<= bram_bimodal.a.read();
		wr_bank1_out<= bram_bank1.a.read();
		wr_bank2_out<= bram_bank2.a.read();
		wr_bank3_out<= bram_bank3.a.read();
		wr_bank4_out<= bram_bank4.a.read();
	endrule


	//initializes all bank entries with counter value=011(weakly taken), tag=0 and LSB=0;stops when the bank with the largest number of entries has been filled
	rule rl_flush(rg_flush);
		Gv_global_addr lv_global_size= `GLOBAL_MAX_ADDR;
		Gv_bimodal_addr lv_bimodal_size= `BIMODAL_MAX_ADDR;

		if(rg_global_flush_addr<= lv_global_size)
		begin
			bram_bank1.b.put(`WRITE,rg_global_flush_addr,12'b011000000000);
			bram_bank2.b.put(`WRITE,rg_global_flush_addr,12'b011000000000);
			bram_bank3.b.put(`WRITE,rg_global_flush_addr,12'b011000000000);
			bram_bank4.b.put(`WRITE,rg_global_flush_addr,12'b011000000000);
			rg_global_flush_addr<= rg_global_flush_addr+1;
		end
		
		else
		begin
			if(`GLOBAL_MAX_ADDR>`BIMODAL_MAX_ADDR)
				rg_flush<= False;	
		end

		if(rg_bimodal_flush_addr<= lv_bimodal_size)
		begin
			bram_bimodal.b.put(`WRITE,rg_bimodal_flush_addr,4'b0110);
			rg_bimodal_flush_addr<= rg_bimodal_flush_addr+1;
		end

		else
		begin
			if(`BIMODAL_MAX_ADDR>`GLOBAL_MAX_ADDR)
				rg_flush<= False;
		end
	endrule


	//enters pc into module and issues read requests to the brams to perform prediction 
	method Action ma_put(Gv_pc pc);
		//calculate addresses to be sent to bram banks
		Gv_bimodal_addr lv_bimodal_addr=pc[11:0];
		Gv_global_addr lv_bank1_addr=fn_hash_indx(pc[19:0],rg_global_history[9:0]);
		Gv_global_addr lv_bank2_addr=fn_hash_indx(pc[19:0],rg_bank2_csr_indx);
		Gv_global_addr lv_bank3_addr=fn_hash_indx(pc[19:0],rg_bank3_csr_indx);
		Gv_global_addr lv_bank4_addr=fn_hash_indx(pc[19:0],rg_bank4_csr_indx);
		
		//issue read requests to all banks
		bram_bimodal.a.put(`READ,lv_bimodal_addr,?);
		
		
		bram_bank1.a.put(`READ,lv_bank1_addr,?);
		
		
		bram_bank2.a.put(`READ,lv_bank2_addr,?);
		

		bram_bank3.a.put(`READ,lv_bank3_addr,?);
		

		bram_bank4.a.put(`READ,lv_bank4_addr,?);
		

		//copy pc value into a local register for further use in rules
		rg_pc_copy<= pc;

	endmethod

	//returns prediction along with training data
	method Bit#(23) mn_get;
		return {wr_prediction,wr_counter,wr_tag,wr_bank_bits,wr_bank_num,wr_bimodal_counter};
	endmethod

	//to start flush operation
	method Action ma_flush if(!rg_flush);        //condition is used to prevent ma_flush from interrupting an already executing flush operation
		rg_flush<= True;
		rg_bimodal_flush_addr<= 0;
		rg_global_flush_addr<= 0;
	endmethod	


	//gets training data into predictor and does the training; also updates the csrs

	method Action ma_train(Gv_pc pc,Bool truth,Bit#(1) prediction,Gv_counter counter,Gv_tag tag,Bit#(5) bank_bits,Gv_bank_num bank_num,Gv_counter bimodal) if(!rg_flush);
		Gv_bimodal_addr lv_bimodal_addr=pc[11:0];
		Gv_global_addr lv_bank1_addr=fn_hash_indx(pc[19:0],rg_global_history[9:0]);
		Gv_global_addr lv_bank2_addr=fn_hash_indx(pc[19:0],rg_bank2_csr_indx);
		Gv_global_addr lv_bank3_addr=fn_hash_indx(pc[19:0],rg_bank3_csr_indx);
		Gv_global_addr lv_bank4_addr=fn_hash_indx(pc[19:0],rg_bank4_csr_indx);
		
		Gv_tag lv_new_tag1=fn_hash_tag(pc[7:0],rg_bank1_csr_p,rg_bank1_csr_s);
		Gv_tag lv_new_tag2=fn_hash_tag(pc[7:0],rg_bank2_csr_p,rg_bank2_csr_s);
		Gv_tag lv_new_tag3=fn_hash_tag(pc[7:0],rg_bank3_csr_p,rg_bank3_csr_s);
		Gv_tag lv_new_tag4=fn_hash_tag(pc[7:0],rg_bank4_csr_p,rg_bank4_csr_s);

		Gv_pc lv_pc= pc;
		Bit#(1) lv_prediction= prediction;
		Gv_bank_num lv_bank_num= bank_num;
		Bool lv_truth= truth;
		Gv_counter lv_counter= counter;
		Bit#(5) lv_bank_bits= bank_bits; 
		Gv_tag lv_tag= tag;
		Gv_counter lv_training_bimodal_out= bimodal;
		
		//prediction is correct
		if(lv_truth)
		begin
			//updating bank x and bank 0
			//branch taken was the prediction => branch was actually taken
			if(unpack(lv_prediction))													//for type conversion from Bit#(1) to Bool
			begin
				//update csrs first
				rg_global_history<= (rg_global_history << 1)|1;
				rg_bank2_csr_indx <= (rg_bank2_csr_indx << 1) | {9'b0,(rg_global_history[19]^1^rg_bank2_csr_indx[9])}; 			//Calculating new values of cyclic
			 	rg_bank3_csr_indx <= (rg_bank3_csr_indx << 1) | {9'b0,(rg_global_history[39]^1^rg_bank3_csr_indx[9])}; 			// shift registers
			 	rg_bank4_csr_indx <= (rg_bank4_csr_indx << 1) | {9'b0,(rg_global_history[79]^1^rg_bank4_csr_indx[9])};

			 	rg_bank1_csr_p <= {(rg_bank1_csr_p[7:6] << 1) | {1'b0,(rg_global_history[9]^rg_bank1_csr_p[5])}, (rg_bank1_csr_p[5:0] << 1) | {5'b0, 1^rg_bank1_csr_p[7]}};
			 	rg_bank2_csr_p <= {(rg_bank2_csr_p[7:4] << 1 | zeroExtend(rg_global_history[19]^rg_bank2_csr_p[3])), rg_bank2_csr_p[3:0] << 1 | zeroExtend(1^rg_bank2_csr_p[7])};
			 	rg_bank3_csr_p <= rg_bank3_csr_p << 1 | zeroExtend(rg_global_history[39]^1^rg_bank3_csr_p[7]);
			 	rg_bank4_csr_p <= rg_bank4_csr_p << 1 | zeroExtend(rg_global_history[79]^1^rg_bank4_csr_p[7]);

			 	rg_bank1_csr_s <= {(rg_bank1_csr_s[6:4] << 1 | zeroExtend(rg_global_history[9]^rg_bank1_csr_p[2])), rg_bank1_csr_p[3:0] << 1 | zeroExtend(1^rg_bank1_csr_p[7])};
			 	rg_bank2_csr_s <= {(rg_bank2_csr_s[5]^(rg_global_history[19])), rg_bank2_csr_p[5:0] << 1 | zeroExtend(1^rg_bank2_csr_p[6])};
			 	rg_bank3_csr_s <= {(rg_bank3_csr_s[6:5] << 1 | zeroExtend(rg_global_history[39]^rg_bank3_csr_p[4])), rg_bank3_csr_p[4:0] << 1 | zeroExtend(1^rg_bank3_csr_p[7])};
			 	rg_bank4_csr_s <= {(rg_bank4_csr_s[6:3] << 1 | zeroExtend(rg_global_history[79]^rg_bank4_csr_p[2])), rg_bank4_csr_p[2:0] << 1 | zeroExtend(1^rg_bank4_csr_p[7])};

				//perform bank updation
				case(lv_bank_num)
				0:
				begin
					if(lv_counter != 3'b111)
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_counter+1,lv_bank_bits[4]}); //updating counter value only
				end

				1:
				begin
					if(lv_counter != 3'b111)
					begin
						bram_bank1.b.put(`WRITE,lv_bank1_addr,{lv_counter+1,lv_tag,1'b1});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end

					else
					begin						
						bram_bank1.b.put(`WRITE,lv_bank1_addr,{lv_counter,lv_tag,1'b1});                         //updating bits u and m only as counter is saturated	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
				end

				2:
				begin
					if(lv_counter != 3'b111)
					begin
						bram_bank2.b.put(`WRITE,lv_bank2_addr,{lv_counter+1,lv_tag,1'b1});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
					else
					begin						
						bram_bank2.b.put(`WRITE,lv_bank2_addr,{lv_counter,lv_tag,1'b1});                        //updating bits u and m only as counter is saturated	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
				end

				3:
				begin
					if(lv_counter != 3'b111)
					begin
						bram_bank3.b.put(`WRITE,lv_bank3_addr,{lv_counter+1,lv_tag,1'b1});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
					else
					begin						
						bram_bank3.b.put(`WRITE,lv_bank3_addr,{lv_counter,lv_tag,1'b1});                         //updating bits u and m only as counter is saturated	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
				end

				4:
				begin
					if(lv_counter != 3'b111)
					begin
						bram_bank4.b.put(`WRITE,lv_bank4_addr,{lv_counter+1,lv_tag,1'b1});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
					else
					begin						
						bram_bank4.b.put(`WRITE,lv_bank4_addr,{lv_counter,lv_tag,1'b1});                         //updating bits u and m only as counter is saturated	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
				end
				endcase
			end
			//branch not taken was the prediction => branch was actually not taken
			else
			begin
				//update csrs first
				rg_global_history<= (rg_global_history << 1);
				rg_bank2_csr_indx <= (rg_bank2_csr_indx << 1) | zeroExtend(rg_global_history[19]^0^rg_bank2_csr_indx[9]); 			//Calculating new values of cyclic
			 	rg_bank3_csr_indx <= (rg_bank3_csr_indx << 1) | zeroExtend(rg_global_history[39]^0^rg_bank3_csr_indx[9]); 			// shift registers
			 	rg_bank4_csr_indx <= (rg_bank4_csr_indx << 1) | zeroExtend(rg_global_history[79]^0^rg_bank4_csr_indx[9]);

			 	rg_bank1_csr_p <= {(rg_bank1_csr_p[7:6] << 1) | zeroExtend(rg_global_history[9]^rg_bank1_csr_p[5]), (rg_bank1_csr_p[5:0] << 1) | zeroExtend(0^rg_bank1_csr_p[7])};
			 	rg_bank2_csr_p <= {(rg_bank2_csr_p[7:4] << 1 | zeroExtend(rg_global_history[19]^rg_bank2_csr_p[3])), rg_bank2_csr_p[3:0] << 1 | zeroExtend(0^rg_bank2_csr_p[7])};
			 	rg_bank3_csr_p <= rg_bank3_csr_p << 1 | zeroExtend(rg_global_history[39]^0^rg_bank3_csr_p[7]);
			 	rg_bank4_csr_p <= rg_bank4_csr_p << 1 | zeroExtend(rg_global_history[79]^0^rg_bank4_csr_p[7]);

			 	rg_bank1_csr_s <= {(rg_bank1_csr_s[6:4] << 1 | zeroExtend(rg_global_history[9]^rg_bank1_csr_p[2])), rg_bank1_csr_p[3:0] << 1 | zeroExtend(0^rg_bank1_csr_p[7])};
			 	rg_bank2_csr_s <= {(rg_bank2_csr_s[5]^(rg_global_history[19])), rg_bank2_csr_p[5:0] << 1 | zeroExtend(0^rg_bank2_csr_p[6])};
			 	rg_bank3_csr_s <= {(rg_bank3_csr_s[6:5] << 1 | zeroExtend(rg_global_history[39]^rg_bank3_csr_p[4])), rg_bank3_csr_p[4:0] << 1 | zeroExtend(0^rg_bank3_csr_p[7])};
			 	rg_bank4_csr_s <= {(rg_bank4_csr_s[6:3] << 1 | zeroExtend(rg_global_history[79]^rg_bank4_csr_p[2])), rg_bank4_csr_p[2:0] << 1 | zeroExtend(0^rg_bank4_csr_p[7])};

				//perform bank updation
				case(lv_bank_num)
				0:
				begin
					if(lv_counter != 3'b000)
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_counter-1,lv_bank_bits[4]}); //updating counter value only
				end

				1:
				begin
					if(lv_counter != 3'b000)
					begin
						bram_bank1.b.put(`WRITE,lv_bank1_addr,{lv_counter-1,lv_tag,1'b1});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
					else
					begin						
						bram_bank1.b.put(`WRITE,lv_bank1_addr,{lv_counter,lv_tag,1'b1});                         //updating bits u and m only as counter is saturated
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
				end

				2:
				begin
					if(lv_counter != 3'b000)
					begin
						bram_bank2.b.put(`WRITE,lv_bank2_addr,{lv_counter-1,lv_tag,1'b1});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
					else
					begin						
						bram_bank2.b.put(`WRITE,lv_bank2_addr,{lv_counter,lv_tag,1'b1});                         //updating bits u and m only as counter is saturated	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
				end

				3:
				begin
					if(lv_counter != 3'b000)
					begin
						bram_bank3.b.put(`WRITE,lv_bank3_addr,{lv_counter-1,lv_tag,1'b1});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
					else
					begin						
						bram_bank3.b.put(`WRITE,lv_bank3_addr,{lv_counter,lv_tag,1'b1});                         //updating bits u and m only as counter is saturated
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
				end

				4:
				begin
					if(lv_counter != 3'b000)
					begin
						bram_bank4.b.put(`WRITE,lv_bank4_addr,{lv_counter-1,lv_tag,1'b1});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
					else
					begin						
						bram_bank4.b.put(`WRITE,lv_bank4_addr,{lv_counter,lv_tag,1'b1});                         //updating bits u and m only as counter is saturated	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b1});
					end
				end
				endcase
			end
		end
		//prediction is false
		//in each case statement, the respective bank is updated along with bank0; after that banks x+1-->4 are updated
		else
		begin
			//branch not taken is prediction => branch was actually taken
			if(!unpack(lv_prediction))													//for type conversion from Bit#(1) to Bool
			begin
				//update csrs first
				rg_global_history<= (rg_global_history << 1)|1;
				rg_bank2_csr_indx <= (rg_bank2_csr_indx << 1) | {9'b0,(rg_global_history[19]^1^rg_bank2_csr_indx[9])}; 			//Calculating new values of cyclic
			 	rg_bank3_csr_indx <= (rg_bank3_csr_indx << 1) | {9'b0,(rg_global_history[39]^1^rg_bank3_csr_indx[9])}; 			// shift registers
			 	rg_bank4_csr_indx <= (rg_bank4_csr_indx << 1) | {9'b0,(rg_global_history[79]^1^rg_bank4_csr_indx[9])};

			 	rg_bank1_csr_p <= {(rg_bank1_csr_p[7:6] << 1) | {1'b0,(rg_global_history[9]^rg_bank1_csr_p[5])}, (rg_bank1_csr_p[5:0] << 1) | {5'b0, 1^rg_bank1_csr_p[7]}};
			 	rg_bank2_csr_p <= {(rg_bank2_csr_p[7:4] << 1 | zeroExtend(rg_global_history[19]^rg_bank2_csr_p[3])), rg_bank2_csr_p[3:0] << 1 | zeroExtend(1^rg_bank2_csr_p[7])};
			 	rg_bank3_csr_p <= rg_bank3_csr_p << 1 | zeroExtend(rg_global_history[39]^1^rg_bank3_csr_p[7]);
			 	rg_bank4_csr_p <= rg_bank4_csr_p << 1 | zeroExtend(rg_global_history[79]^1^rg_bank4_csr_p[7]);

			 	rg_bank1_csr_s <= {(rg_bank1_csr_s[6:4] << 1 | zeroExtend(rg_global_history[9]^rg_bank1_csr_p[2])), rg_bank1_csr_p[3:0] << 1 | zeroExtend(1^rg_bank1_csr_p[7])};
			 	rg_bank2_csr_s <= {(rg_bank2_csr_s[5]^(rg_global_history[19])), rg_bank2_csr_p[5:0] << 1 | zeroExtend(1^rg_bank2_csr_p[6])};
			 	rg_bank3_csr_s <= {(rg_bank3_csr_s[6:5] << 1 | zeroExtend(rg_global_history[39]^rg_bank3_csr_p[4])), rg_bank3_csr_p[4:0] << 1 | zeroExtend(1^rg_bank3_csr_p[7])};
			 	rg_bank4_csr_s <= {(rg_bank4_csr_s[6:3] << 1 | zeroExtend(rg_global_history[79]^rg_bank4_csr_p[2])), rg_bank4_csr_p[2:0] << 1 | zeroExtend(1^rg_bank4_csr_p[7])};

				//perform bank updation
				case(lv_bank_num)
				0:
				begin	
					//update bank x=0
					if(lv_counter != 3'b111)
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_counter+1,lv_bank_bits[4]}); //updating counter value only
					//updating banks 1-->4
					//if all u bits are set
					if({lv_bank_bits[3],lv_bank_bits[2],lv_bank_bits[1],lv_bank_bits[0]}==4'b1111)
					begin
						if(lv_bank_bits[4]==1'b1)                                                  //if m bit is set
							bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
						else
						begin
							if(lv_training_bimodal_out[2]==1'b1)                              //check bimodal prediction
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						end
					end
					//some u bits are reset
					else
					begin
						//update whichever banks have u=0
						if(lv_bank_bits[3]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank1.b.put(`WRITE,lv_bank1_addr,{3'b100,lv_new_tag1,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank1.b.put(`WRITE,lv_bank1_addr,{3'b100,lv_new_tag1,1'b0});
								else
									bram_bank1.b.put(`WRITE,lv_bank1_addr,{3'b011,lv_new_tag1,1'b0});
							end
						end
						if(lv_bank_bits[2]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank2.b.put(`WRITE,lv_bank2_addr,{3'b100,lv_new_tag2,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank2.b.put(`WRITE,lv_bank2_addr,{3'b100,lv_new_tag2,1'b0});
								else
									bram_bank2.b.put(`WRITE,lv_bank2_addr,{3'b011,lv_new_tag2,1'b0});
							end
						end
						if(lv_bank_bits[1]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b100,lv_new_tag3,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b100,lv_new_tag3,1'b0});
								else
									bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b011,lv_new_tag3,1'b0});
							end
						end
						if(lv_bank_bits[0]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
								else
									bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
							end
						end
					end

				end

				1:
				begin
					//update banks 1 and 0
					if(lv_counter != 3'b111)
					begin
						bram_bank1.b.put(`WRITE,lv_bank1_addr,{lv_counter+1,lv_tag,1'b0});	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end
					else
					begin						
						bram_bank1.b.put(`WRITE,lv_bank1_addr,{lv_counter,lv_tag,1'b0});             //updating bits u and m only, if bank x counter is saturated 	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end
					//update banks 2-->4
					if({lv_bank_bits[2],lv_bank_bits[1],lv_bank_bits[0]}==3'b111)
					begin
						if(lv_bank_bits[4]==1'b1)
							bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
						else
						begin
							if(lv_training_bimodal_out[2]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						end
					end
					//some u bits are reset
					else
					begin
						//update whichever banks have u=0
						if(lv_bank_bits[2]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank2.b.put(`WRITE,lv_bank2_addr,{3'b100,lv_new_tag2,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank2.b.put(`WRITE,lv_bank2_addr,{3'b100,lv_new_tag2,1'b0});
								else
									bram_bank2.b.put(`WRITE,lv_bank2_addr,{3'b011,lv_new_tag2,1'b0});
							end
						end
						if(lv_bank_bits[1]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b100,lv_new_tag3,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b100,lv_new_tag3,1'b0});
								else
									bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b011,lv_new_tag3,1'b0});
							end
						end
						if(lv_bank_bits[0]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
								else
									bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
							end
						end
					end
					
				end

				2:
				begin
					//update banks 2 and 0
					if(lv_counter != 3'b111)
					begin
						bram_bank2.b.put(`WRITE,lv_bank2_addr,{lv_counter+1,lv_tag,1'b0});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end

					else
					begin						
						bram_bank2.b.put(`WRITE,lv_bank2_addr,{lv_counter,lv_tag,1'b0});                            //updating bits u and m only	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end
					//update banks 3-->4
					if({lv_bank_bits[1],lv_bank_bits[0]}==2'b11)
					begin
						if(lv_bank_bits[4]==1'b1)
							bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
						else
						begin
							if(lv_training_bimodal_out[2]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						end
					end
					//some u bits are reset
					else
					begin
						//update whichever banks have u=0
						if(lv_bank_bits[1]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b100,lv_new_tag3,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b100,lv_new_tag3,1'b0});
								else
									bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b011,lv_new_tag3,1'b0});
							end
						end
						if(lv_bank_bits[0]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
								else
									bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
							end
						end
					end
				end

				3:
				begin
					//update banks 3 and 0
					if(lv_counter != 3'b111)
					begin
						bram_bank3.b.put(`WRITE,lv_bank3_addr,{lv_counter+1,lv_tag,1'b0});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end

					else
					begin						
						bram_bank3.b.put(`WRITE,lv_bank3_addr,{lv_counter,lv_tag,1'b0});                            //updating bits u and m only	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end
					//update bank 4
					if(lv_bank_bits[0]==1'b1)
					begin
						if(lv_bank_bits[4]==1'b1)
							bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
						else
						begin
							if(lv_training_bimodal_out[2]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						end
					end
					//u bit of bank4 is 0
					else
					begin
						if(lv_bank_bits[4]==1'b1)
							bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
						else
						begin
							if(lv_training_bimodal_out[2]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						end
						
					end
				end

				4:
				begin
					if(lv_counter != 3'b111)
					begin
						bram_bank4.b.put(`WRITE,lv_bank4_addr,{lv_counter+1,lv_tag,1'b0});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end
					else
					begin						
						bram_bank4.b.put(`WRITE,lv_bank4_addr,{lv_counter,lv_tag,1'b0});                            //updating bits u and m only	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end
				end
				endcase
			end
			//branch taken was the prediction => branch was actually not taken
			else
			begin
				//update csrs first
				rg_global_history<= (rg_global_history << 1);
				rg_bank2_csr_indx <= (rg_bank2_csr_indx << 1) | zeroExtend(rg_global_history[19]^0^rg_bank2_csr_indx[9]); 			//Calculating new values of cyclic
			 	rg_bank3_csr_indx <= (rg_bank3_csr_indx << 1) | zeroExtend(rg_global_history[39]^0^rg_bank3_csr_indx[9]); 			// shift registers
			 	rg_bank4_csr_indx <= (rg_bank4_csr_indx << 1) | zeroExtend(rg_global_history[79]^0^rg_bank4_csr_indx[9]);

			 	rg_bank1_csr_p <= {(rg_bank1_csr_p[7:6] << 1) | zeroExtend(rg_global_history[9]^rg_bank1_csr_p[5]), (rg_bank1_csr_p[5:0] << 1) | zeroExtend(0^rg_bank1_csr_p[7])};
			 	rg_bank2_csr_p <= {(rg_bank2_csr_p[7:4] << 1 | zeroExtend(rg_global_history[19]^rg_bank2_csr_p[3])), rg_bank2_csr_p[3:0] << 1 | zeroExtend(0^rg_bank2_csr_p[7])};
			 	rg_bank3_csr_p <= rg_bank3_csr_p << 1 | zeroExtend(rg_global_history[39]^0^rg_bank3_csr_p[7]);
			 	rg_bank4_csr_p <= rg_bank4_csr_p << 1 | zeroExtend(rg_global_history[79]^0^rg_bank4_csr_p[7]);

			 	rg_bank1_csr_s <= {(rg_bank1_csr_s[6:4] << 1 | zeroExtend(rg_global_history[9]^rg_bank1_csr_p[2])), rg_bank1_csr_p[3:0] << 1 | zeroExtend(0^rg_bank1_csr_p[7])};
			 	rg_bank2_csr_s <= {(rg_bank2_csr_s[5]^(rg_global_history[19])), rg_bank2_csr_p[5:0] << 1 | zeroExtend(0^rg_bank2_csr_p[6])};
			 	rg_bank3_csr_s <= {(rg_bank3_csr_s[6:5] << 1 | zeroExtend(rg_global_history[39]^rg_bank3_csr_p[4])), rg_bank3_csr_p[4:0] << 1 | zeroExtend(0^rg_bank3_csr_p[7])};
			 	rg_bank4_csr_s <= {(rg_bank4_csr_s[6:3] << 1 | zeroExtend(rg_global_history[79]^rg_bank4_csr_p[2])), rg_bank4_csr_p[2:0] << 1 | zeroExtend(0^rg_bank4_csr_p[7])};

				//perform bank updation
				case(lv_bank_num)
				0:
				begin
					//update bank 0
					if(lv_counter != 3'b000)
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_counter-1,lv_bank_bits[4]}); //updating counter value only
					//updating banks 1-->4
					//if all u bits are set
					if({lv_bank_bits[3],lv_bank_bits[2],lv_bank_bits[1],lv_bank_bits[0]}==4'b1111)
					begin
						if(lv_bank_bits[4]==1'b1)
							bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						else
						begin
							if(lv_training_bimodal_out[2]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						end
					end
					//some u bits are reset
					else
					begin
						//update whichever banks have u=0
						if(lv_bank_bits[3]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank1.b.put(`WRITE,lv_bank1_addr,{3'b011,lv_new_tag1,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank1.b.put(`WRITE,lv_bank1_addr,{3'b100,lv_new_tag1,1'b0});
								else
									bram_bank1.b.put(`WRITE,lv_bank1_addr,{3'b011,lv_new_tag1,1'b0});
							end
						end
						if(lv_bank_bits[2]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank2.b.put(`WRITE,lv_bank2_addr,{3'b011,lv_new_tag2,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank2.b.put(`WRITE,lv_bank2_addr,{3'b100,lv_new_tag2,1'b0});
								else
									bram_bank2.b.put(`WRITE,lv_bank2_addr,{3'b011,lv_new_tag2,1'b0});
							end
						end
						if(lv_bank_bits[1]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b011,lv_new_tag3,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b100,lv_new_tag3,1'b0});
								else
									bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b011,lv_new_tag3,1'b0});
							end
						end
						if(lv_bank_bits[0]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
								else
									bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
							end
						end
					end				
				end

				1:
				begin
					//update banks 1 and 0
					if(lv_counter != 3'b000)
					begin
						bram_bank1.b.put(`WRITE,lv_bank1_addr,{lv_counter-1,lv_tag,1'b0});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end

					else
					begin						
						bram_bank1.b.put(`WRITE,lv_bank1_addr,{lv_counter,lv_tag,1'b0});                            //updating bits u and m only	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end
					//update banks 2-->4
					//check if all u bits are set
					if({lv_bank_bits[2],lv_bank_bits[1],lv_bank_bits[0]}==3'b111)
					begin
						if(lv_bank_bits[4]==1'b1)
							bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						else
						begin
							if(lv_training_bimodal_out[2]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						end
					end
					//some u bits are reset
					else
					begin
						//update whichever banks have u=0
						if(lv_bank_bits[2]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank2.b.put(`WRITE,lv_bank2_addr,{3'b011,lv_new_tag2,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank2.b.put(`WRITE,lv_bank2_addr,{3'b100,lv_new_tag2,1'b0});
								else
									bram_bank2.b.put(`WRITE,lv_bank2_addr,{3'b011,lv_new_tag2,1'b0});
							end
						end

						if(lv_bank_bits[1]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b011,lv_new_tag3,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b100,lv_new_tag3,1'b0});
								else
									bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b011,lv_new_tag3,1'b0});
							end
						end

						if(lv_bank_bits[0]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
								else
									bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
							end
						end
					end
					
				end

				2:
				begin
					//update banks 2 and 0
					if(lv_counter != 3'b000)
					begin
						bram_bank2.b.put(`WRITE,lv_bank2_addr,{lv_counter-1,lv_tag,1'b0});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end

					else
					begin						
						bram_bank2.b.put(`WRITE,lv_bank2_addr,{lv_counter,lv_tag,1'b0});                            //updating bits u and m only	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end
					//update banks 3-->4
					//check if all u bits are set
					if({lv_bank_bits[1],lv_bank_bits[0]}==2'b11)
					begin
						if(lv_bank_bits[4]==1'b1)
							bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						else
						begin
							if(lv_training_bimodal_out[2]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						end
					end
					//some u bits are reset
					else
					begin
						//update whichever banks have u=0
						if(lv_bank_bits[1]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b011,lv_new_tag3,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b100,lv_new_tag3,1'b0});
								else
									bram_bank3.b.put(`WRITE,lv_bank3_addr,{3'b011,lv_new_tag3,1'b0});
							end
						end

						if(lv_bank_bits[0]==1'b0)
						begin
							if(lv_bank_bits[4]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
							else
							begin
								if(lv_training_bimodal_out[2]==1'b1)
									bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
								else
									bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
							end
						end
					end
				end

				3:
				begin
					//update banks 3 and 0
					if(lv_counter != 3'b000)
					begin
						bram_bank3.b.put(`WRITE,lv_bank3_addr,{lv_counter-1,lv_tag,1'b0});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end

					else
					begin						
						bram_bank3.b.put(`WRITE,lv_bank3_addr,{lv_counter,lv_tag,1'b0});                            //updating bits u and m only	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end
					//update bank 4
					if(lv_bank_bits[0]==1'b1)
					begin
						if(lv_bank_bits[4]==1'b1)
							bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						else
						begin
							if(lv_training_bimodal_out[2]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						end
					end
					//u bit of bank 4=0
					else
					begin
						if(lv_bank_bits[4]==1'b1)
							bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						else
						begin
							if(lv_training_bimodal_out[2]==1'b1)
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b100,lv_new_tag4,1'b0});
							else
								bram_bank4.b.put(`WRITE,lv_bank4_addr,{3'b011,lv_new_tag4,1'b0});
						end
						
					end
				end

				4:
				begin
					//update banks 4 and 0
					if(lv_counter != 3'b000)
					begin
						bram_bank4.b.put(`WRITE,lv_bank4_addr,{lv_counter-1,lv_tag,1'b0});//updating bits u and m and counter value	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end

					else
					begin						
						bram_bank4.b.put(`WRITE,lv_bank4_addr,{lv_counter,lv_tag,1'b0});                            //updating bits u and m only	
						bram_bimodal.b.put(`WRITE,lv_bimodal_addr,{lv_training_bimodal_out,1'b0});
					end
				end
				endcase
			end
		end

	endmethod

endmodule	
endpackage

