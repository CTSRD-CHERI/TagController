/* Copyright 2015 Matthew Naylor
 * Copyright 2018 Jonathan Woodruff
 * Copyright 2018-2022 Alexandre Joannou
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

import DefaultValue :: *;
import StmtFSM      :: *;
import RegFile      :: *;
import FIFO         :: *;
import FIFOF        :: *;
import SpecialFIFOs :: *;
import Vector       :: *;
import BlueCheck    :: *;
import Debug        :: *;
import SourceSink   :: *;
import BlueAXI4     :: *;
import Bag          :: *;
import VnD          :: *;
import Fabric_Defs  :: *;
import MemTypesCHERI:: *;

// This module has been developed for the purpose of testing the
// (shared) memory sub-system.  It aims to provide a neat Bluespec
// interface to memory resembling the memory instructions of the MIPS
// ISA.  Given a fiddley axiSlaveer interface we return a neat
// MemoryClient interface.

// Interface ==================================================================

interface MemoryClient;

  // Load value at address
  method Action load(Addr addr);

  // Store data to address
  method Action store(Data data, Addr addr);

  // Get response
  method ActionValue#(MemoryClientResponse) getResponse;
  method Bool canGetResponse;

  // Check if all outstanding operations have been consumed
  method Bool done;

  // Set mapping from Addr values to physical address
  method Action setAddrMap(AddrMap map);
endinterface

// Types ======================================================================

typedef 4 NumAddrBits;

typedef struct {
  Bit#(NumAddrBits) addr;
  Bit#(1) dword;
} Addr
  deriving (Bits, Eq, Bounded);

typedef Bit#(17) Data;

typedef union tagged {
  void WriteResponse;
  Data DataResponse;
} MemoryClientResponse
  deriving (Bits, Eq, FShow);

typedef struct {
  Bit#(idWidth) id;      // ID of the next response (in order)
  Bit#(8) lowAddr;       // Lower 8-bits of address
} OutstandingMemInstr#(numeric type idWidth)
  deriving (Bits, FShow);

typedef struct {
  Addr addr;
  Data data;
  Bool isLoad;
} TestReq
  deriving (Bits, FShow);

// How to map an Addr to a 24-bit physical address offset
typedef struct {
  Vector#(NumAddrBits, Bit#(5)) index;
} AddrMap deriving (Bits, Eq, Bounded);

// Convert an Addr to a 64-bit virtual address
function Bit#(64) fromAddr(Addr x, AddrMap addrMap);
  Bit#(24) offset = 0;
  for (Integer i = 0; i < valueOf(NumAddrBits); i=i+1)
    offset[addrMap.index[i]] = x.addr[i];
  CheriPhyAddr addr = PhyByteAddress{lineNumber: {0, offset, x.dword}, byteOffset: 0};
  //Bit#(5) line = extend({x.dword, 4'b000});
  return zeroExtend(pack(addr));
endfunction

// Functions ==================================================================

// Convert from Data to bus width
function Tuple2#(Bit#(CapsPerFlit), Bit#(Wd_Data)) fromData(Data x) = tuple2(truncateLSB(x),zeroExtend(x));

// Convert from bus width to Data
function Data toData(Bit#(CapsPerFlit) t, Bit#(Wd_Data) d) = {t, truncate(d)};

// Show addresses
instance FShow#(Addr);
  function Fmt fshow (Addr a) =
    $format("%x:%x", a.addr, a.dword);
endinstance

// Show address map
instance FShow#(AddrMap);
  function Fmt fshow(AddrMap map) =
    $format("<" , map.index[3],
            ", ", map.index[2],
            ", ", map.index[1],
            ", ", map.index[0],
            ">");
endinstance

// Custom generators ==========================================================

// Custom generator for AddrMap.  Each value in an AddrMap must be
// unique and lie in the range 0..23 inclusive.

module [BlueCheck] genAddrMap (Gen#(AddrMap));
  Gen#(Vector#(NumAddrBits, Bit#(3))) offsetsGen <- mkGenDefault;
  method ActionValue#(AddrMap) gen;
    Vector#(NumAddrBits, Bit#(3)) offsets <- offsetsGen.gen;
    AddrMap map;
    Bit#(5) offset = 0;
    for (Integer i = 0; i < valueOf(NumAddrBits); i = i+1) begin
      Bit#(5) newOffset = offset + zeroExtend(bound(offsets[i], 4));
      map.index[i] = newOffset;
      offset = newOffset+1;
    end
    return map;
  endmethod
endmodule

instance MkGen#(AddrMap);
  mkGen = genAddrMap;
endinstance

// Memory client module =======================================================

module mkMemoryClient#(AXI4_Slave#(idWidth, addrWidth, Wd_Data, 0, CapsPerFlit, 0, 1, CapsPerFlit) axiSlave) (MemoryClient)
  provisos (Add#(a__, addrWidth, 64), Add#(b__, idWidth, 8));

  // Response FIFO
  FIFOF#(MemoryClientResponse) responseFIFO <- mkFIFOF;
  Vector#(TExp#(idWidth), FIFOF#(MemoryClientResponse)) responseFifos <- replicateM(mkUGFIFOF);

  // FIFO storing details of outstanding loads
  FIFOF#(OutstandingMemInstr#(idWidth)) outstandingFIFO <- mkSizedFIFOF(16);

  // FIFOs for tracking addresses of outstanding requests to ensure we don't
  // issue multiple requests to the same address concurrently.
  Vector#(TExp#(idWidth), FIFOF#(Addr)) addrFifos <- replicateM(mkUGFIFOF1);

  Reg#(Bit#(idWidth)) idCount <- mkReg(0);

  // Address mapping
  Reg#(AddrMap) addrMap <- mkRegU;

  // Fill response FIFO
  rule handleWriteResponses (axiSlave.b.canPeek);
    let b <- get(axiSlave.b);
    debug2("memoryclient", $display("<time %0t MemoryClient> MemoryClient handleWriteResponse: ", $time, fshow(b)));
    addrFifos[b.bid].deq;
  endrule
  rule handleReadResponses (axiSlave.r.canPeek);
    let r <- get(axiSlave.r);
    debug2("memoryclient", $display("<time %0t MemoryClient> MemoryClient handleReadResponses: ", $time, fshow(r)));
    responseFifos[r.rid].enq(DataResponse(toData(r.ruser, r.rdata)));
    addrFifos[r.rid].deq;
  endrule
  FIFOF#(MemoryClientResponse) nextResponseFIFO = responseFifos[outstandingFIFO.first.id];
  rule forwardReadResponseInOrder(nextResponseFIFO.notEmpty);
    debug2("memoryclient", $display("<time %0t MemoryClient> MemoryClient forwardReadResponse: ", $time, fshow(nextResponseFIFO.first), " outstandingFIFO: ", fshow(outstandingFIFO.first)));
    responseFIFO.enq(nextResponseFIFO.first);
    nextResponseFIFO.deq;
    outstandingFIFO.deq;
  endrule

  //rule debug;
  //   $write("DEBUG: ", $time, "> ");
  //   for (Integer i = 0; i < valueOf(TExp#(idWidth)); i = i + 1) $write("addrs[%d].notFull:%d ", i, addrFifos[i].notFull);
  //   $display(" and done ");
  //     "responseFIFO.notFull: ", responseFIFO.notFull, " | ",
  //     "responseFIFO.notEmpty: ", responseFIFO.notEmpty, " | ",
  //     "outstandingFIFO.notFull: ", outstandingFIFO.notFull, " | ",
  //     "outstandingFIFO.notEmpty: ", outstandingFIFO.notEmpty, " | ",
  //     "nextIsLoad: ", nextIsLoad, " | ",
  //     "b.canPeek: ", axiSlave.b.canPeek, " | ",
  //     "r.canPeek: ", axiSlave.r.canPeek, " | ",
  //     ""
  //   );
  //endrule

  FIFO#(TestReq) reqQue <- mkBypassFIFO;
  function Bool matchReqQue(FIFOF#(Addr) f) = (f.notEmpty && f.first == reqQue.first.addr);
  FIFOF#(Addr) nextAddrFIFO = addrFifos[idCount];
  Bool blockNewReq = any(matchReqQue,addrFifos);
  rule loadGeneric(reqQue.first.isLoad && !blockNewReq && nextAddrFIFO.notFull);
    let r <- get(reqQue);
    Bit#(64) fullAddr = fromAddr(r.addr, addrMap);

    debug2("memoryclient", $display("<time %0t MemoryClient> Load issued: ", $time, fshow(r.addr), " -> ", fshow(fullAddr)));

    AXI4_ARFlit#(idWidth, addrWidth, 1) addrReq = defaultValue;
    addrReq.arid = idCount;
    idCount <= idCount + 1;
    addrReq.araddr = truncate(fullAddr);
    addrReq.arsize = 16;
    addrReq.arcache = 4'b1011;

    axiSlave.ar.put(addrReq);
    debug2("memoryclient", $display("<time %0t MemoryClient> Load issued: ", $time, fshow(addrReq), " id: ", fshow(idCount)));
    // debug2("memoryclient", $display("<time %0t MemoryClient> idWidth: ", $time, fshow(idWidth)));

    outstandingFIFO.enq(OutstandingMemInstr{
      id: idCount,
      lowAddr: fullAddr[7:0]
    });

    nextAddrFIFO.enq(r.addr);
  endrule

  rule storeGeneric(!reqQue.first.isLoad && !blockNewReq && nextAddrFIFO.notFull);
    let r <- get(reqQue);
    Bit#(64) fullAddr = fromAddr(r.addr, addrMap);

    debug2("memoryclient", $display("<time %0t MemoryClient> Store issued: ", $time, fshow(r.data), " sent to ", fshow(r.addr), " -> ", fshow(fullAddr)));

    AXI4_AWFlit#(idWidth, addrWidth, 0) addrReq = defaultValue;
    addrReq.awid = idCount;
    idCount <= idCount + 1;
    addrReq.awcache = 4'b1011;
    addrReq.awaddr = truncate(fullAddr);
    axiSlave.aw.put(addrReq);

    AXI4_WFlit#(Wd_Data, CapsPerFlit) dataReq = defaultValue;
    match {.t, .d} = fromData(r.data);
    dataReq.wuser = t;
    dataReq.wdata = d;
    axiSlave.w.put(dataReq);
    debug2("memoryclient", $display("<time %0t MemoryClient> Store issued: ", $time, fshow(addrReq), " ", fshow(dataReq)));
    nextAddrFIFO.enq(r.addr);
  endrule

  // Load value at address into register
  method Action load(Addr addr);
    reqQue.enq(TestReq{data: ?, addr: addr, isLoad: True});
  endmethod

  // Store data to address
  method Action store(Data data, Addr addr);
    reqQue.enq(TestReq{data: data, addr: addr, isLoad: False});
  endmethod

  method ActionValue#(MemoryClientResponse) getResponse =
    get(responseFIFO);

  method Bool canGetResponse = responseFIFO.notEmpty;

  // Check if all outstanding operations have been consumed
  method Bool done = !outstandingFIFO.notEmpty &&
                     !responseFIFO.notEmpty;

//   // Set mapping from Addr values to physical address
  method Action setAddrMap(AddrMap map);
    addrMap <= map;
  endmethod

endmodule

// Golden memory client =======================================================

module mkMemoryClientGolden (MemoryClient);

  // Response FIFO
  FIFOF#(MemoryClientResponse) responseFIFO <- mkSizedFIFOF(16);


  // Golden memory unit (one mem per dword)
  RegFile#(Bit#(NumAddrBits), Data) memA <- mkRegFileFull;
  RegFile#(Bit#(NumAddrBits), Data) memB <- mkRegFileFull;

  // Initialisation
  Reg#(Bool) init <- mkReg(True);
  Reg#(Addr) memAddr <- mkReg(minBound);

  // Address mapping
  Reg#(AddrMap) addrMap <- mkRegU;

  rule initialiseMem(init);
    if (pack(memAddr) == maxBound)
      init <= False;
    else
      memAddr <= unpack(pack(memAddr) + 1);
    memA.upd(memAddr.addr, 0);
    memB.upd(memAddr.addr, 0);
  endrule

  // Load value at address into register
  method Action load(Addr addr) if (!init);
    let dA = memA.sub(addr.addr);
    let dB = memB.sub(addr.addr);
    debug2("memoryclient", $display("<time %0t MemoryClientGolden> load dA: ", $time, fshow(dA), ", dB ", fshow(dB), " addr.dword: %d ", addr.dword));
    responseFIFO.enq(DataResponse(addr.dword == 1 ? dB : dA));
  endmethod

  // Store data to address
  method Action store(Data data, Addr addr) if (!init);
    debug2("memoryclient", $display("<time %0t MemoryClientGolden> store data: ", $time, fshow(data), ", addr ", fshow(addr)));
    if (addr.dword == 1)
      memB.upd(addr.addr, data);
    else
      memA.upd(addr.addr, data);
  endmethod

  // Check if all outstanding operations have been consumed
  method Bool done = !responseFIFO.notEmpty;

  // Responses
  method ActionValue#(MemoryClientResponse) getResponse;
    responseFIFO.deq;
    return responseFIFO.first;
  endmethod

  method Bool canGetResponse = responseFIFO.notEmpty;

  //   // Set mapping from Addr values to physical address
  method Action setAddrMap(AddrMap map);
    addrMap <= map;
  endmethod

endmodule
