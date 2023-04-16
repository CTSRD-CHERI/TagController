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

typedef 32 AddressLength;
typedef 128 CacheLineLength;
typedef 1 TagsPerLine;
typedef `BenchmarkIDWidth AXI_id_width;

// Line stride is BYTES
// `define LINE_STRIDE 128 // 8 * 128bit capabilities
`define LINE_STRIDE 16 // 1 * 128bit capabilities

`define NORMAL_INPUT_FILE "dramtraces/fromFile_input.dat"
`define PIPED_INPUT_FILE "dramtraces/fromFile_input.pipe"

typedef struct {
  Bit#(8) op_type; // 0 if Read, 1 if Write, 2 if End of initialising, 3 if end of file
  Bit#(AddressLength) address; // 64 bit address
  Bit#(CacheLineLength) data; // 128 bit cache lines
  Bit#(8) tags; // tag bits per cache line (round up to 1 byte)
} FileMemoryOp
  deriving (Bits, Eq, FShow);

typedef TDiv#(SizeOf#(FileMemoryOp), 8) BytesPerMemop;

(* synthesize *)
module mkWriteTest (Empty);

    String targetFile = "dramtraces/toFile_output.dat";

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
        // Sequential reads
        let next_op = FileMemoryOp {
            op_type: 0,
            address: curr_addr,
            data: 0,
            tags: 0
        };
        curr_addr <= curr_addr + `LINE_STRIDE;

        // // Sequential writes (no tags)
        // let next_op = FileMemoryOp {
        //     op_type: 1,
        //     address: curr_addr,
        //     data: -1,
        //     tags: 0
        // };
        // curr_addr <= curr_addr + `LINE_STRIDE;

        $display("Writing to file: ", fshow(next_op));
        $fwriteh(file_handler, next_op);

        ops_left_to_write <= ops_left_to_write - 1;

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

    // Used to setup initial DRAM state
    TagControllerAXI#(AXI_id_width,AddressLength,CacheLineLength) tagcontroller_initialiser <- mkWriteAndSetTagControllerAXI(
        True, // Start off connected to DRAM
        reset_by r.new_rst
    );

    
    // What actually does the requests
    // RUNTYPE: ALL NULL
    // 4 bit id width
    TagControllerAXI#(AXI_id_width,AddressLength,CacheLineLength) tagcontroller_main <- mkTagControllerAXI(
        False, // Start off NOT connected to DRAM
        reset_by r.new_rst
    );
    
    // TagControllerAXI#(4,AddressLength,CacheLineLength) tagcontroller_main <- mkNullTagControllerAXI(
    //     False, // Start off NOT connected to DRAM
    //     reset_by r.new_rst
    // );
    
    
    // Initialises with alternatign 1s and 0s
    AXI4_Slave#(
        SizeOf#(MemTypesCHERI::ReqId), AddressLength, CacheLineLength, 0, 0, 0, 0, 0
    ) dram <- BenchModelDRAM::mkModelDRAM(4, reset_by r.new_rst);

    // Only the one with isInUse set will consume DRAM responses
    mkConnection(tagcontroller_initialiser.master, dram, reset_by r.new_rst);
    mkConnection(tagcontroller_main.master, dram, reset_by r.new_rst);
   
    mkFileToTagController(
        tagcontroller_initialiser,
        tagcontroller_main,
        reset_by r.new_rst
    );
endmodule
    
module mkFileToTagController#(
    TagControllerAXI#(
        AXI_id_width,
        AddressLength,
        CacheLineLength
    ) tc_initialiser,
    TagControllerAXI#(
        AXI_id_width,
        AddressLength,
        CacheLineLength
    ) tc_main
) (Empty);
    
    Reg#(File) file_handler <- mkReg(?);
    Reg#(Bool) opened <- mkReg(False);
    Reg#(Bool) done <- mkReg(False);
    
    Reg#(Bit#(64)) simulationTime <- mkReg(0);

    // What id to use for next op
    Reg#(Bit#(AXI_id_width)) idCount <- mkReg(0);
    // FIFO storing details of outstanding loads/stores
    FIFOF#(FileMemoryOp) outstandingFIFO <- mkSizedFIFOF(16);

    // Decided which tag controller to use for requests / responses
    // NOTE: scheduler assumes that need BOTH to be ready in order to do anything
    //   - Requests are OK (as if not in use then always ready to receive requests)
    //   - Responses need seperate rules (as if not in use then never have responses)
    Reg#(Bool) use_main_axi <- mkReg(False);
    let currentAxiSlave = use_main_axi ? tc_main.slave : tc_initialiser.slave;

    // Set to false to ensure all requests after end of iniit get sent to main controller
    Reg#(Bool) process_new_requests <- mkReg(True);
    // Used to indicate that end of init instruction has been seen
    Reg#(Bool) end_of_init <- mkReg(False);

    // Ensure that initialiser is not expecting any more DRAM responses
    rule switch_to_main_slave (end_of_init && !outstandingFIFO.notEmpty && tc_initialiser.isIdle);
        $display("<time %0t Benchmark> Switching to main tag controller!", $time);
        tc_initialiser.set_isInUse(False);
        tc_main.set_isInUse(True);
        use_main_axi <= True;
        process_new_requests <= True;
        end_of_init <= False;
        idCount <= 0;
    endrule


    rule open_file (!opened);
        Bool use_pipe <- $test$plusargs("pipe");
        if (use_pipe) begin 
            File file_obj <- $fopen(`PIPED_INPUT_FILE, "r");
            file_handler <= file_obj;
            debug2("benchmark", $display("<time %0t Benchmark> File opened: ", $time, fshow(`PIPED_INPUT_FILE)));
        end else begin
            File file_obj <- $fopen(`NORMAL_INPUT_FILE, "r");
            file_handler <= file_obj;
            debug2("benchmark", $display("<time %0t Benchmark> File opened: ", $time, fshow(`NORMAL_INPUT_FILE)));
        end
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
        if (op.op_type < 3) 
        begin
            debug2("benchmark", $display("<time %0t Benchmark> Read from file:", $time, fshow(op)));
            sourceFileOpsFIFO.enq(op);
        end else if(op.op_type == 3)
        begin
            debug2("benchmark", $display("<time %0t Benchmark> Reached end of file!", $time));
            $fclose ( file_handler );
            done <= True;
        end else 
        begin 
            $display("EEK!!! Read invalid op: ", fshow(op));
            $fclose ( file_handler );
            done <= True;
        end
    endrule

    rule updateTime;
        let t <- $time;
        simulationTime <= t;
    endrule

    // Functions
    rule issueIntruction (sourceFileOpsFIFO.notEmpty && simulationTime > 10000 && process_new_requests);
        let next_op = sourceFileOpsFIFO.first;
        if (next_op.op_type == 0)
        begin
            let addr = next_op.address;

            // this is a read operation
            
            AXI4_ARFlit#(AXI_id_width, AddressLength, 1) addrReq = defaultValue;
            
            addrReq.arid = truncate(idCount);
            idCount <= idCount + 1;
            addrReq.araddr = addr;
            addrReq.arsize = 16; //TODO (what size to put here?)
            addrReq.arcache = 4'b1011; //TODO (what to put here?)
            
            debug2("benchmark", $display("<time %0t Benchmark> Sending Load: ", $time, fshow(addrReq)));
            
            if (use_main_axi) begin
                debug2("tracing", $display(
                    "<time %0t Tracing> ", $time, fshow(idCount), " ",
                    "sent to tag controller | read"
                ));
            end


            currentAxiSlave.ar.put(addrReq);

            outstandingFIFO.enq(next_op);
            sourceFileOpsFIFO.deq();
        end 
        else if (next_op.op_type == 1)
        begin
            let addr = next_op.address;
            let data = next_op.data;
            let tags = next_op.tags;

            AXI4_AWFlit#(AXI_id_width, AddressLength, 0) addrReq = defaultValue;

            addrReq.awid = truncate(idCount);
            idCount <= idCount + 1;
            addrReq.awaddr = addr;
            addrReq.awcache = 4'b1011;

            debug2("benchmark", $display("<time %0t Benchmark> Sending Write Address request: ", $time, fshow(addrReq)));

            if (use_main_axi) begin
                debug2("tracing", $display(
                    "<time %0t Tracing> ", $time, fshow(idCount), " ",
                    "sent to tag controller | write | ", fshow(tags[0])
                ));
            end

            currentAxiSlave.aw.put(addrReq);
    
            AXI4_WFlit#(128, 1) dataReq = defaultValue;

            dataReq.wdata = data;
            dataReq.wuser = truncate(tags);

            debug2("benchmark", $display("<time %0t Benchmark> Sending Write data: ", $time, fshow(dataReq)));
            currentAxiSlave.w.put(dataReq);

            outstandingFIFO.enq(next_op);
            sourceFileOpsFIFO.deq();
        end
        else if (next_op.op_type == 2)
        begin
            process_new_requests <= False;
            end_of_init <= True;
            sourceFileOpsFIFO.deq();
        end
    endrule

    // Fill response FIFO
    // NOTE: need 2 versions of these rules so compiler knows only 1 of the tc's needs to be ready
    rule handleWriteResponses_main (tc_main.slave.b.canPeek);
        outstandingFIFO.deq;
        let b <- get(tc_main.slave.b);
        debug2("benchmark", $display("<time %0t Benchmark> Write response received: ", $time, fshow(b)));

        debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(b.bid), " ",
            "return from tag controller"
        ));
    endrule
    rule handleWriteResponses_init (tc_initialiser.slave.b.canPeek);
        outstandingFIFO.deq;
        let b <- get(tc_initialiser.slave.b);
        debug2("benchmark", $display("<time %0t Benchmark> Write response received: ", $time, fshow(b)));
    endrule

    rule handleReadResponses_main (tc_main.slave.r.canPeek);
        outstandingFIFO.deq;
        let r <- get(tc_main.slave.r);
        debug2("benchmark", $display("<time %0t Benchmark> Read response received: ", $time, fshow(r)));


        debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(r.rid), " ",
            "return from tag controller | ", fshow(r.ruser[0])
        ));
    endrule
    rule handleReadResponses_init (tc_initialiser.slave.r.canPeek);
        outstandingFIFO.deq;
        let r <- get(tc_initialiser.slave.r);
        debug2("benchmark", $display("<time %0t Benchmark> Read response received: ", $time, fshow(r)));
    endrule

    /*
    rule debug_no_main_resps (tc_main.slave.r.canPeek);
        debug2("benchmark", $display("<time %0t Benchmark> DEBUG: read resp from main ", $time));
    endrule
    rule debug_no_init_resps (tc_initialiser.slave.r.canPeek);
        debug2("benchmark", $display("<time %0t Benchmark> DEBUG: read resp from init ", $time));
    endrule
    */
    
    rule endBenchmark (
        done && // All operations read out of file
        use_main_axi && // Have switched over to main tag controller 
        !outstandingFIFO.notEmpty && // Not waiting for any responses
        !sourceFileOpsFIFO.notEmpty // No requests read from file but not sent to controller
    );
        $finish(0);
    endrule

endmodule

