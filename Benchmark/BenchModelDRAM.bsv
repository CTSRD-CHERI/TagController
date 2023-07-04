/* Copyright 2015 Matthew Naylor
 * Copyright 2018 Jonathan Woodruff
 * Copyright 2022 Alexandre Joannou
 * All rights reserved.
 *
 * This software was developed by SRI International and the University of
 * Cambridge Computer Laboratory under DARPA/AFRL contract FA8750-10-C-0237
 * ("CTSRD"), as part of the DARPA CRASH research programme.
 *
 * This software was developed by SRI International and the University of
 * Cambridge Computer Laboratory under DARPA/AFRL contract FA8750-11-C-0249
 * ("MRC2"), as part of the DARPA MRC research programme.
 *
 * This software was developed by the University of Cambridge Computer
 * Laboratory as part of the Rigorous Engineering of Mainstream
 * Systems (REMS) project, funded by EPSRC grant EP/K008528/1.
 *
 * This software was developed by SRI International and the University of
 * Cambridge Computer Laboratory (Department of Computer Science and
 * Technology) under DARPA contract HR0011-18-C-0016 ("ECATS"), as part of the
 * DARPA SSITH research programme.
 *
 * @BERI_LICENSE_HEADER_START@
 *
 * Licensed to BERI Open Systems C.I.C. (BERI) under one or more contributor
 * license agreements.  See the NOTICE file distributed with this work for
 * additional information regarding copyright ownership.  BERI licenses this
 * file to you under the BERI Hardware-Software License, Version 1.0 (the
 * "License"); you may not use this file except in compliance with the
 * License.  You may obtain a copy of the License at:
 *
 *   http://www.beri-open-systems.org/legal/license-1-0.txt
 *
 * Unless required by applicable law or agreed to in writing, Work distributed
 * under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * @BERI_LICENSE_HEADER_END@
 */

import ConfigReg    :: *;
import RegFile      :: *;
import Vector       :: *;
import FIFO         :: *;
import FIFOF        :: *;
import FF           :: *;
import Debug        :: *;
import SourceSink   :: *;
import BenchRegFileAssoc :: *;
import BenchRegFileHash  :: *;
import BlueAXI4     :: *;
import AXI_Helpers  :: *;
import MemTypesCHERI:: *;
import Fabric_Defs  :: *;

`define LATENCY 32

module mkModelDRAMGeneric#
         ( Integer maxOutstandingReqs         // Max outstanding requests
         , Integer latency                    // Latency (cycles)
         , RegFile# (Bit#(wordAddrWidth)
                   , Bit#(Wd_Data)
                   ) ram                      // For storage
         )
         (AXI4_Slave#(SizeOf#(MemTypesCHERI::ReqId), addrWidth, Wd_Data, 0, 0, 0, 0, 0))
         provisos (Add#(wordAddrWidth, 4, addrWidth)
         );

  AXI4_Shim#(SizeOf#(MemTypesCHERI::ReqId), addrWidth, Wd_Data, 0, 0, 0, 0, 0) shim <- mkAXI4ShimBypassFIFOF();

  // Slave interface
  FIFOF#(DRAMReq#(SizeOf#(MemTypesCHERI::ReqId), addrWidth)) preReqFifo <- mkSizedFIFOF(maxOutstandingReqs);
  // FIFOF#(DRAMRsp#(SizeOf#(MemTypesCHERI::ReqId))) respFifo   <- mkFIFOF;
  FF#(DRAMRsp#(SizeOf#(MemTypesCHERI::ReqId)),1) respFifo   <- mkUGLFF1;

  // Internal request FIFO contains requests and a flag which denotes
  // the last read request in a burst read.
  FIFOF#(Tuple2#(DRAMReq#(SizeOf#(MemTypesCHERI::ReqId),addrWidth), Bool))  reqFifo <- mkFIFOF;

  // Latency-introducing response FIFO
  FF#(Maybe#(DRAMRsp#(SizeOf#(MemTypesCHERI::ReqId))), `LATENCY) preRespFifo <- mkUGLFF;

  // Storage implemented as a register file
  //RegFile#(Bit#(addrWidth), Bit#(256)) ram <- mkRegFileFull;

  // State for burst reads
  Reg#(Bit#(4)) burstReadCount <- mkConfigReg(0);

  (* descending_urgency = "fillPreReqFifoWrite, fillPreReqFifoRead" *)
  rule fillPreReqFifoWrite;
    let aw <- get(shim.master.aw);
    let  w <- get(shim.master.w);
    preReqFifo.enq(Write(WriteReqFlit{
      aw: aw,
      w: w
    }));
    debug2("dram", $display("<time %0t DRAM> fillPreReqFifoWrite ", $time, fshow(aw), fshow(w)));
  endrule

  rule fillPreReqFifoRead;
    let ar <- get(shim.master.ar);
    preReqFifo.enq(tagged Read ar);
    debug2("dram", $display("<time %0t DRAM> fillPreReqFifoRead ", $time, fshow(ar)));
  endrule

  // State for initialisation
  Reg#(Bool) init <- mkConfigReg(True);

  // Unroll burst read requests
  rule unrollBurstReads (!init);
    // Extract request
    DRAMReq#(SizeOf#(MemTypesCHERI::ReqId),addrWidth) req  = preReqFifo.first;

    // Only dequeue read request if burst read finished
    Bool last = False;
    if (req matches tagged Read .r)
      begin
        Bit#(addrWidth) addr = r.araddr;
        AXI4_ARFlit#(SizeOf#(MemTypesCHERI::ReqId), addrWidth, 0) newR = r;
        // Update address to account for bursts
        newR.araddr = addr + (zeroExtend(pack(burstReadCount)) << 4);
        newR.araddr[3:0] = 0;
        req = tagged Read newR;
        if (truncate(r.arlen) == burstReadCount)
          begin
            last = True;
            burstReadCount <= 0;
            preReqFifo.deq;
            debug2("dram", $display("<time %0t DRAM> unrollBurstReads preReqFifo.deq", $time));
          end
        else
          burstReadCount <= burstReadCount+1;
      end
    else
      preReqFifo.deq;

    // Forward request to next stage
    reqFifo.enq(tuple2(req, last));
    debug2("dram", $display("<time %0t DRAM> unrollBurstReads ", $time, fshow(req)));
  endrule

  PulseWire validRespAdded <- mkPulseWire;

  // Produce responses
  rule produceResponses (!init && preRespFifo.notFull);
    // Extract request
    let req  = tpl_1(reqFifo.first);
    let last = tpl_2(reqFifo.first);
    Bit#(addrWidth) addr =
      (case (req) matches
        tagged Write .w: return w.aw.awaddr;
        tagged Read  .r: return r.araddr;
      endcase);
    reqFifo.deq;

    Bit#(wordAddrWidth) wordAddr = truncate(addr>>4);

    // Data lookup
    Bit#(Wd_Data) data = ram.sub(wordAddr);

    // Defualt response
    DRAMRsp#(SizeOf#(MemTypesCHERI::ReqId)) resp = ?;
    Bool validResponse = False;

    case (req) matches
      // Write ================================================================
      tagged Write .write:
        begin
          // Perform write
          Vector#(CheriBusBytes, Bit#(8)) bytes    = unpack(truncate(data));
          Vector#(CheriBusBytes, Bit#(8)) newBytes = unpack(truncate(write.w.wdata));
          for (Integer i = 0; i < valueOf(CheriBusBytes); i=i+1)
            if (write.w.wstrb[i]==1'b1)
              bytes[i] = newBytes[i];
          ram.upd(wordAddr, pack(bytes));
          debug2("dram", $display("<time %0t DRAM> Wrote %x to address %x in RAM", $time, bytes, wordAddr));
          resp = Write(AXI4_BFlit{
            bid: write.aw.awid,
            bresp: OKAY,
            buser: ?
          });
          validResponse = write.w.wlast;
        end

      // Read =================================================================
      tagged Read .read:
        begin
          debug2("dram", $display("<time %0t DRAM> Read %x from address %x in RAM", $time, data, wordAddr));
          resp = tagged Read AXI4_RFlit{
            rid: read.arid,
            rdata: data,
            rresp: OKAY,
            rlast: last,
            ruser: ?
          };
          validResponse  = True;
        end
    endcase

    // Respond
    // if (validResponse) respFifo.enq(resp);
    preRespFifo.enq(validResponse ? tagged Valid resp : tagged Invalid);
    validRespAdded.send;
    debug2("dram", $display("<time %0t DRAM> produceFinalResponses validResponse: %d ", $time, validResponse, fshow(resp)));
  endrule

  rule introduceLatency (!validRespAdded && preRespFifo.notFull);
    preRespFifo.enq(tagged Invalid);
    debug2("dram", $display("<time %0t DRAM> introduced latency. preRespFifo.remaining: ", $time, preRespFifo.remaining));
  endrule

  rule produceFinalResponses (!init && preRespFifo.notEmpty && respFifo.notFull);
    let resp = preRespFifo.first;
    if (resp matches tagged Valid .r) begin
      respFifo.enq(r);
      debug2("dram", $display("<time %0t DRAM> drained response: %d ", $time, fshow(resp)));
    end else begin
      debug2("dram", $display("<time %0t DRAM> drained invalid", $time));
    end
    preRespFifo.deq;
  endrule

  // Initialise until pre-response FIFO is full
  rule initialise (init && !preRespFifo.notFull);
    init <= False;
  endrule

  rule drainRespFifo (respFifo.notEmpty);
    case (respFifo.first) matches
      tagged Write .w: shim.master.b.put(w);
      tagged Read .r: shim.master.r.put(r);
    endcase
    respFifo.deq();
    debug2("dram", $display("<time %0t DRAM> drainRespFifo ", $time, fshow(respFifo.first)));
  endrule

  // Slave interface
  return shim.slave;
endmodule

// Version using a standard register file
module mkModelDRAM#
         ( Integer maxOutstandingReqs         // Max outstanding requests
         , Integer latency                    // Latency (cycles)
         )
         (AXI4_Slave#(SizeOf#(MemTypesCHERI::ReqId), addrWidth, Wd_Data, 0, 0, 0, 0, 0))
         provisos (Add#(wordAddrWidth, 4, addrWidth));
  RegFile#(Bit#(wordAddrWidth), Bit#(Wd_Data)) ram <- mkRegFileFull;
  let dram <- mkModelDRAMGeneric(maxOutstandingReqs, latency, ram);
  return dram;
endmodule

// Version using an associative register file.  Must be small, but has
// the advantage of being efficiently resettable to a predefined state.
module mkModelDRAMAssoc#
         ( Integer maxOutstandingReqs         // Max outstanding requests
         , Integer latency                    // Latency (cycles)
         )
         (AXI4_Slave#(SizeOf#(MemTypesCHERI::ReqId), addrWidth, Wd_Data, 0, 0, 0, 0, 0))
         provisos (Add#(wordAddrWidth, 4, addrWidth));
  RegFile#(Bit#(wordAddrWidth), Bit#(Wd_Data)) ram <- mkRegFileAssoc;
  let dram <- mkModelDRAMGeneric(maxOutstandingReqs, latency, ram);
  return dram;
endmodule
