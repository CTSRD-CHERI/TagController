import Vector::*;
import FIFO:: *;
import FIFOF:: *;
import BlueAXI4::*;
import TagControllerAXI::*;
import BenchModelDRAM::*;
import Clocks::*;
import SourceSink::*;
import Connectable::* ;
import Debug::*;

typedef 64 AddressLength;
typedef 128 CacheLineLength;

// `define LINE_STRIDE 10000024
`define LINE_STRIDE 128

typedef struct {
  Bit#(8) op_type; // 0 if Read, 1 if Write
  Bit#(AddressLength) address; // 64 bit address
  Bit#(CacheLineLength) data; // 128 bit cache lines
} FileMemoryOp
  deriving (Bits, Eq, FShow);

typedef TDiv#(SizeOf#(FileMemoryOp), 8) BytesPerMemop;

(* synthesize *)
module mkWriteTest (Empty);

    String targetFile = "test_write.dat";
    Reg#(File) file_handler <- mkReg(?);

    Reg#(Bool) opened <- mkReg(False);
    Reg#(Bit#(32)) ops_left_to_write <- mkReg(10000);
    Reg#(Bool) finished <- mkReg(False);

    Reg#(Bit#(AddressLength)) curr_addr <- mkReg(0);

    rule open_file (!opened);
        File file_obj <- $fopen(targetFile, "wb");
        file_handler <= file_obj;
        opened <= True;
    endrule

    rule write_to_file (opened && !finished);
        let next_op = FileMemoryOp {
            op_type: 0,
            address: curr_addr,
            data: 0
        };
        $display("Writing to file: ", fshow(next_op));
        $fwriteh(file_handler, next_op);
        ops_left_to_write <= ops_left_to_write - 1;
        curr_addr <= curr_addr + `LINE_STRIDE;
        if (ops_left_to_write == 0)
        begin
            finished <= True;
            $fflush(file_handler);
            $fclose(file_handler);
            $finish(0);
        end
    endrule

endmodule

function Bit#(4) hexDecode(Bit#(8) x);
    // 0-9 are ASCII 48 to 57
    // a-f are ASCII 97 to 102
    Bit#(8) y = (x >= 97 ? 87 : 48);
    return (x-y)[3:0];
endfunction

(* synthesize *)
module mkReadTest (Empty);

    String sourceFile = "test_write.dat";
    Reg#(File) file_handler <- mkReg(?);

    Reg#(Bool) opened <- mkReg(False);

    rule open_file (!opened);
        File file_obj <- $fopen(sourceFile, "r");
        file_handler <= file_obj;
        opened <= True;
    endrule

    function ActionValue#(Bit#(8)) getByte(File f) =
        actionvalue
            Bit#(8) x;
            int c0 <- $fgetc(f);
            int c1 <- $fgetc(f);
            x[7:4] = hexDecode(pack(c0)[7:0]);
            x[3:0] = hexDecode(pack(c1)[7:0]);
            return x;
        endactionvalue;

    rule read_contents (opened);
        Vector#(BytesPerMemop,Bit#(8)) op_bytes = newVector();
        // Have to read in backwards
        for(Integer i = valueOf(BytesPerMemop) -1; i >= 0; i=i-1)
        begin
            let b <- getByte(file_handler);
            op_bytes[i] = b;
        end
        FileMemoryOp op = unpack(pack(op_bytes));

        // Dodgy but sound way of detecting when got to end of the file!
        // op_type should always be 0 (read) or 1 (write) but at end of the file
        // will never read this if at end of file.
        if(op.op_type > 1)
        begin
            $display( "Could not get byte from %s", sourceFile ) ;
            $fclose ( file_handler ) ;
            $finish(0);
        end
        
        $display("read from file: ", fshow(op));
    endrule

endmodule

  

(* synthesize *)
module mkRequestsFromFile (Empty);
    Clock clk      <- exposeCurrentClock;
    MakeResetIfc r <- mkReset(0, True, clk);

    // 4 bit id width
    // RUNTYPE: ALL NULL
    TagControllerAXI#(4,AddressLength,CacheLineLength) tagcontroller <- mkTagControllerAXI(reset_by r.new_rst);
    // TagControllerAXI#(4,AddressLength,CacheLineLength) tagcontroller <- mkNullTagControllerAXI(reset_by r.new_rst);
    
    AXI4_Slave#(
        8, AddressLength, CacheLineLength, 0, 0, 0, 0, 0
    ) dram <- BenchModelDRAM::mkModelDRAMAssoc(4, reset_by r.new_rst);

    mkConnection(tagcontroller.master, dram, reset_by r.new_rst);
   
    String sourceFile = "test_write.dat";

    mkFileToAXI(sourceFile,tagcontroller.slave,reset_by r.new_rst);
endmodule
    
module mkFileToAXI#(
    String sourceFile,
    AXI4_Slave#(
        id_,
        AddressLength,
        CacheLineLength, 
        0, // awuser
        TagController::CapsPerFlit, // wuser (capabililites)
        0, // buser
        1, // aruser (tagonly)
        TagController::CapsPerFlit // ruser (capabilities)
    ) axiSlave
) (Empty)
    provisos (Add#(a__, id_, 8));

    Reg#(File) file_handler <- mkReg(?);
    Reg#(Bool) opened <- mkReg(False);
    Reg#(Bool) done <- mkReg(False);

    rule open_file (!opened);
        File file_obj <- $fopen(sourceFile, "r");
        file_handler <= file_obj;
        opened <= True;
        debug2("benchmark", $display("<time %0t Benchmark> File opened: ", $time, fshow(sourceFile)));
    endrule

    function ActionValue#(Bit#(8)) getByte(File f) =
        actionvalue
            Bit#(8) x;
            int c0 <- $fgetc(f);
            int c1 <- $fgetc(f);
            x[7:4] = hexDecode(pack(c0)[7:0]);
            x[3:0] = hexDecode(pack(c1)[7:0]);
            return x;
        endactionvalue;

    // FIFO storing details of loads/stores in source file
    FIFOF#(FileMemoryOp) sourceFileOpsFIFO <- mkSizedFIFOF(4);

    // Pump things into sourceFileOpsFIFO
    rule read_contents (opened && !done);
        Vector#(BytesPerMemop,Bit#(8)) op_bytes = newVector();
        // Have to read in backwards
        for(Integer i = valueOf(BytesPerMemop) -1; i >= 0; i=i-1)
        begin
            let b <- getByte(file_handler);
            op_bytes[i] = b;
        end
        FileMemoryOp op = unpack(pack(op_bytes));

        // Dodgy but sound way of detecting when got to end of the file!
        // op_type should always be 0 (read) or 1 (write) but at end of the file
        // will never read this if at end of file.
        if(op.op_type > 1)
        begin
            $display("ERROR: Could not get byte from %s", sourceFile);
            $fclose ( file_handler );
            done <= True;
        end
        else begin
            debug2("benchmark", $display("<time %0t Benchmark> Read from file:", $time, fshow(op)));
            sourceFileOpsFIFO.enq(op);
        end
    endrule

    // What id to use for next op
    Reg#(Bit#(8)) idCount <- mkReg(0);
    // FIFO storing details of outstanding loads/stores
    // TODO: currently just used as "counter" for how many are awaiting a response
    //       would be better to match responses with ids
    FIFOF#(FileMemoryOp) outstandingFIFO <- mkSizedFIFOF(16);

    Reg#(Bit#(64)) simulationTime <- mkReg(0);

    rule updateTime;
        let t <- $time;
        simulationTime <= t;
    endrule

    // Functions
    rule issueIntruction (sourceFileOpsFIFO.notEmpty && simulationTime > 10000);
        let next_op = sourceFileOpsFIFO.first;
        if (next_op.op_type == 0)
        begin
            let addr = next_op.address;

            // this is a read operation
            
            AXI4_ARFlit#(id_, AddressLength, 1) addrReq = defaultValue;
            
            addrReq.arid = truncate(idCount);
            idCount <= idCount + 1;
            addrReq.araddr = addr;
            addrReq.arsize = 16; //TODO (what size to put here?)
            addrReq.arcache = 4'b1011; //TODO (what to put here?)
            
            debug2("benchmark", $display("<time %0t Benchmark> Sending Load: ", $time, fshow(addrReq)));
            axiSlave.ar.put(addrReq);

            outstandingFIFO.enq(next_op);
            sourceFileOpsFIFO.deq();
        end 
        else if (next_op.op_type == 1)
        begin
            $display("ERROR: Writes not supported yet!");
            $finish;
        end
    endrule

    // Fill response FIFO
    rule handleWriteResponses (axiSlave.b.canPeek);
        outstandingFIFO.deq;
        let b <- get(axiSlave.b);
        debug2("benchmark", $display("<time %0t Benchmark> Write response received: ", $time, fshow(b)));
    endrule


    rule handleReadResponses (axiSlave.r.canPeek);
        outstandingFIFO.deq;
        let r <- get(axiSlave.r);
        debug2("benchmark", $display("<time %0t Benchmark> Read response received: ", $time, fshow(r)));
    endrule

    rule endBenchmark (done && !outstandingFIFO.notEmpty);
        $finish(0);
    endrule

endmodule

