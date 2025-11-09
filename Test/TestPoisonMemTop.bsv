import Vector::*;
import SourceSink::*;
import Connectable::* ;
import MemoryClient::*;
import BlueAXI4::*;
import TestEquiv::*;
import ModelDRAM :: *;
import Clocks::*;
import BlueCheck::*;
import StmtFSM::*;
import DefaultValue :: *;
import ConfigReg::*;
import TagControllerAXI::*;


module mkTestPoisonMemTop (Empty);
  mkTestPoisonMemTopSingle;
endmodule

typedef enum {Init, WriteTag, WaitWriteResponse, ReadTag, WaitReadResponse} State deriving (Bits, Eq, FShow);

module [Module] mkTestPoisonMemTopSingle (Empty);
  Clock clk      <- exposeCurrentClock;
  MakeResetIfc r <- mkReset(0, True, clk);
  //PoisonTagControllerAXI#(4,32,128) dut <- mkPoisonTagControllerAXI(reset_by r.new_rst);
  TagControllerAXI#(4,32,512) dut <- mkTagControllerAXI(reset_by r.new_rst);

  AXI4_Slave#(8, 32, 512, 0, 0, 0, 0, 0) dram <- mkModelDRAMAssoc(32, reset_by r.new_rst);
  Reg#(Bool) done_write <- mkReg(False);
  mkConnection(dut.master, dram, reset_by r.new_rst);

  MemoryClient dutClient <- mkMemoryClient(dut.slave, reset_by r.new_rst);
  Reg#(State) state <- mkConfigReg(Init);
  Reg#(Bit#(32)) counter <- mkReg(0);
  Reg#(Bit#(8)) wait_counter <- mkReg(0);
  rule init_wait(state == Init);
    wait_counter <= wait_counter + 1;
    if(wait_counter < 10) state <= WriteTag;
  endrule
  rule write_req(state == WriteTag);
    if(counter < 1280) 
      counter <= counter+1;
    if(counter ==1) begin 
      dutClient.store_simple(unpack({4'b1, 13'b0000}), unpack(4096*0), 2'b01);
     //dutClient.store_simple(unpack({4'b1, 13'b0000}), unpack(4096), 2'b10);
      //dutClient.load( unpack(0));
    end 
    else if (counter == 100) begin 
    end 
    else if (counter ==1280 ) begin
      dutClient.store_simple(unpack({4'b1, 13'b0000}), unpack(4096*0), 2'b10);

      //dutClient.store_simple(unpack({4'b1, 13'b0000}), unpack(4096), 2'b01);
      state <= WaitWriteResponse;
      //dutClient.store(unpack({4'b1, 13'b0000}), unpack(0), 2'b11);
    end 
      //dutClient.load( unpack(0));
    //if(dutClient.canGetResponse()) begin
    //  $display("to wait write response");
      
      //$display("counter %d", counter);
  endrule

  rule readResponse( state == WaitWriteResponse);
    //$display("resp write poison");
    dutClient.store_simple(unpack({4'b1, 13'b0000}), unpack(4096*0), 2'b11);
    counter <= 0;
    //let resp <- dutClient.getResponse();
    // //if(dutClient.canGetResponse)
    
    state <= ReadTag;
  endrule 

  rule read_req( state == ReadTag);
    counter <= counter+1;
    if(counter ==1) begin 
      //dutClient.load( unpack(5'b00001));
      //dutClient.load_simple( 32'h1000);
      dutClient.load_simple( unpack(4096*0));
      //dutClient.store(unpack({1'b1, 16'b0000}), unpack(0));
      $display("read_req ");
    end 
    if (counter ==600) begin
      state <= WaitReadResponse;
      //dutClient.load_simple( unpack(4096));
    end 
  endrule 
//
  rule readResp(state == WaitReadResponse);
      let resp <- dutClient.getResponse();
      $display("resp read poison", fshow(resp));
  endrule 
endmodule
