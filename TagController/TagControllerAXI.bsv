/*-
 * Copyright (c) 2018 Jonathan Woodruff
 * Copyright (c) 2018-2019 Alexandre Joannou
 * All rights reserved.
 *
 * This software was developed by SRI International and the University of
 * Cambridge Computer Laboratory under DARPA/AFRL contract FA8750-10-C-0237
 * ("CTSRD"), as part of the DARPA CRASH research programme.
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

import MasterSlaveCHERI::*;
import MemTypesCHERI::*;
import RoutableCHERI::*;
import GetPut::*;
import SourceSink::*;
import AXI_Helpers::*;
import AXI4::*;
import BlueUtils :: *;
import TagController::*;
import FIFO::*;
import FIFOF::*;
import SpecialFIFOs::*;
import Clocks :: *;
import Debug::*;
import Fabric_Defs::*;
`ifdef PERFORMANCE_MONITORING
import PerformanceMonitor :: *;
import Vector :: *;
import CacheCore :: *;
`endif

import TagTableStructure::*;
import Vector :: *;

/******************************************************************************
 * mkTagControllerAXI
 *
 * A wrapper around the CHERI tag controller to export an AXI interface.
 *
 *****************************************************************************/

interface TagControllerAXI#(
  numeric type id_,
  numeric type addr_,
  numeric type data_);
  interface AXI4_Master#(SizeOf#(ReqId), addr_, data_, 0, 0, 0, 0, 0) master;
  interface AXI4_Slave#(id_, addr_, data_, 0, CapsPerFlit, 0, 1, CapsPerFlit) slave;
  method Action clear;
`ifdef PERFORMANCE_MONITORING
  method EventsCacheCore events;
`endif
`ifdef TAGCONTROLLER_BENCHMARKING
  method Action set_isInUse(Bool inUse);
  method Bool isIdle;
`endif
endinterface

// module mkNullTagControllerAXI(TagControllerAXI#(id_, addr_,Wd_Data))
`ifdef TAGCONTROLLER_BENCHMARKING
module mkNullTagControllerAXI#(Bool inUse)
`else 
module mkNullTagControllerAXI
`endif
  (TagControllerAXI#(id_, addr_,TMul#(CheriBusBytes, 8)))
  provisos (
    Add#(a__, id_, CheriTransactionIDWidth), 
    Add#(b__, id_, SizeOf#(ReqId)), 
    Add#(c__, addr_, 64)
  );

  `ifdef TAGCONTROLLER_BENCHMARKING
  Reg#(Bool) isInUse <- mkReg(inUse);
  `endif

  let    clk <- exposeCurrentClock;
  let newRst <- mkReset(0, True, clk);
  //Workaround: these are being enqueued while full in Piccolo. Made the buffer size larger (32 from 4)
  // AXI4_Shim#(id_, addr_, Wd_Data, 0, CapsPerFlit, 0, 1, CapsPerFlit) shimSlave  <- mkAXI4ShimBypassFIFOF;
  // AXI4_Shim#(SizeOf#(ReqId), addr_, Wd_Data, 0, 0, 0, 0, 0) shimMaster <- mkAXI4ShimBypassFIFOF;
  AXI4_Shim#(id_, addr_, TMul#(CheriBusBytes, 8), 0, CapsPerFlit, 0, 1, CapsPerFlit) shimSlave  <- mkAXI4ShimBypassFIFOF;//mkAXI4ShimFF;
  AXI4_Shim#(SizeOf#(ReqId), addr_, TMul#(CheriBusBytes, 8), 0, 0, 0, 0, 0) shimMaster <- mkAXI4ShimBypassFIFOF;
  
  Reg#(Bool) reset_done <- mkReg(False);

  rule propagateReset(!reset_done);
      newRst.assertReset;
      shimSlave.clear;
      shimMaster.clear;
      reset_done <= True;
  endrule

  rule connectAR;
    let ar <- get(shimSlave.master.ar);
    shimMaster.slave.ar.put(AXI4_ARFlit{
      arid: zeroExtend(ar.arid),
      araddr: ar.araddr,
      arlen: ar.arlen,
      arsize: ar.arsize,
      arburst: INCR,
      arlock: NORMAL,
      arcache: fabric_default_arcache,
      arprot: 0,
      arqos: 0,
      arregion: 0,
      aruser: ?
    });
  endrule
  rule connectAW;
    let aw <- get(shimSlave.master.aw);
    shimMaster.slave.aw.put(AXI4_AWFlit{
      awid: zeroExtend(aw.awid),
      awaddr: aw.awaddr,
      awlen: aw.awlen,
      awsize: aw.awsize,
      awburst: INCR,
      awlock: NORMAL,
      awcache: fabric_default_awcache,
      awprot: 0,
      awqos: 0,
      awregion: 0,
      awuser: ?
    });
  endrule

  `ifdef TAGCONTROLLER_BENCHMARKING
  rule connectB (isInUse);
  `else
  rule connectB;
  `endif
    let b <- get(shimMaster.slave.b);
    shimSlave.master.b.put(AXI4_BFlit{
      bid: truncate(b.bid),
      bresp: b.bresp,
      buser: ?
    });
  endrule

  `ifdef TAGCONTROLLER_BENCHMARKING
  rule connectR (isInUse);
  `else
  rule connectR;
  `endif
    let r <- get(shimMaster.slave.r);
    shimSlave.master.r.put(AXI4_RFlit{
      rid: truncate(r.rid),
      rdata: r.rdata,
      rresp: r.rresp,
      rlast: r.rlast,
      ruser: ~0 // Fake it up; all tags are set.
    });
  endrule

  rule connectW;
    let w <- get(shimSlave.master.w);
    shimMaster.slave.w.put(AXI4_WFlit{
      wdata: w.wdata,
      wstrb: w.wstrb,
      wlast: w.wlast,
      wuser: ? // Fake it up; drop tags.
    });
  endrule

  method clear if (reset_done) = action
    newRst.assertReset;
    shimSlave.clear;
    shimMaster.clear;
  endaction;
  interface slave  = shimSlave.slave;
  interface master = shimMaster.master;

`ifdef PERFORMANCE_MONITORING
  method events = ?;
`endif

`ifdef TAGCONTROLLER_BENCHMARKING
  method Action set_isInUse(Bool inUse);
    // Need to clear to remove packets still in buffer
    shimMaster.clear;
    isInUse <= inUse;
  endmethod
  method Bool isIdle = True;
`endif


endmodule
 
`ifdef TAGCONTROLLER_BENCHMARKING
module mkTagControllerAXI#(Bool inUse)
`else 
module mkTagControllerAXI
`endif
  (TagControllerAXI#(id_, addr_,TMul#(CheriBusBytes, 8)))
  provisos (Add#(a__, id_, CheriTransactionIDWidth), Add#(c__, addr_, 64));
  let tmp <- mkDbgTagControllerAXI(
    `ifdef TAGCONTROLLER_BENCHMARKING
    inUse,
    `endif
    Invalid
  );
  return tmp;
endmodule

module mkDbgTagControllerAXI#(
  `ifdef TAGCONTROLLER_BENCHMARKING
  Bool inUse,
  `endif
  Maybe#(String) dbg
)(TagControllerAXI#(id_, addr_,TMul#(CheriBusBytes, 8)))
  provisos (Add#(a__, id_, CheriTransactionIDWidth), Add#(c__, addr_, 64));

  `ifdef TAGCONTROLLER_BENCHMARKING
  Reg#(Bool) isInUse <- mkReg(inUse);
  `endif

  let    clk <- exposeCurrentClock;
  let newRst <- mkReset(0, True, clk);
  TagControllerIfc tagCon <- mkTagController(
    reset_by newRst.new_rst
  );
  //Workaround: these are being enqueued while full in Piccolo. Made the buffer size larger (32 from 4)
  AXI4_Shim#(id_, addr_, TMul#(CheriBusBytes, 8), 0, CapsPerFlit, 0, 1, CapsPerFlit) shimSlave  <- mkAXI4ShimBypassFIFOF;//mkAXI4ShimFF;
  AXI4_Shim#(SizeOf#(ReqId), addr_, TMul#(CheriBusBytes, 8), 0, 0, 0, 0, 0) shimMaster <- mkAXI4ShimBypassFIFOF;
  let awreqff <- mkBypassFIFOF;
  let addrOffset <- mkReg(0);
  Reg#(Bool) writeBurst <- mkReg(False);
  Reg#(Bool) reset_done <- mkReg(False);

  rule propagateReset(!reset_done);
      newRst.assertReset;
      shimSlave.clear;
      shimMaster.clear;
      reset_done <= True;
  endrule

  rule getCacheAW;
    let awreq <- get(shimSlave.master.aw);
    awreqff.enq(awreq);
  endrule

  // Rules to feed the tag controller from the slave AXI interface
  // Ready if there is no read request or if the write request is first.
  (* descending_urgency = "passCacheRead, passCacheWrite" *)
  rule passCacheWrite;
    let awreq = awreqff.first;
    let wreq <- get(shimSlave.master.w);
    if (wreq.wlast) begin
      writeBurst <= False;
      addrOffset <= 0;
      awreqff.deq;
    end else begin
      writeBurst <= True;
      addrOffset <= addrOffset + (1 << pack(awreq.awsize));
    end
    awreq.awaddr = awreq.awaddr + addrOffset;
    let mreq = axi2mem_req(Write(WriteReqFlit{aw: awreq, w: wreq}));
    debug2("AXItagcontroller", $display("<time %0t TagController> AXI TagController write request ", $time, fshow(awreq), " - ", fshow(wreq)));
    tagCon.cache.request.put(mreq);
  endrule
  // Ready if there is no partial write burst or if the read request is first.
  // The tag controller is currently unable to correctly handle a read in the
  // middle of a write burst; if fixed, the condition can be removed.
  rule passCacheRead(!writeBurst);
    let ar <- get(shimSlave.master.ar);
    debug2("AXItagcontroller", $display("<time %0t TagController> AXI TagController read request ", $time, fshow(ar)));
    tagCon.cache.request.put(axi2mem_req(Read(ar)));
    //printDbg(dbg, $format("TagController read request ", fshow(ar)));
  endrule
  rule passCacheResponse;
    CheriMemResponse mr <- tagCon.cache.response.get();
    AXI_Helpers::MemRsp#(id_) ar = mem2axi_rsp(mr);
    debug2("AXItagcontroller", $display("<time %0t TagController> AXI TagController response ", $time, fshow(ar)));
    case (ar) matches
    tagged Write .w: shimSlave.master.b.put(w);
    tagged Read  .r: shimSlave.master.r.put(r);
    endcase
    //printDbg(dbg, $format("TagController response ", fshow(ar)));
  endrule

  // Rules to forward requests from the tag controller to the master AXI interface.
  let doneSendingAW <- mkReg(False);
  rule passMemoryRequest;
    CheriMemRequest mr <- tagCon.memory.request.get();
    DRAMReq#(SizeOf#(ReqId), addr_) ar = mem2axi_req(mr);
    // debug2("AXItagcontroller", $display("<time %0t TagController> AXI Memory request (CMM): ", $time, fshow(mr)));
    debug2("AXItagcontroller", $display("<time %0t TagController> AXI Memory request ", $time, fshow(ar)));
    case (ar) matches
      tagged Write .w: begin
        let newDoneSendingAW = doneSendingAW;
        if (!doneSendingAW) begin
          shimMaster.slave.aw.put(w.aw);
          newDoneSendingAW = True;
        end
        shimMaster.slave.w.put(w.w);
        if (w.w.wlast) newDoneSendingAW = False;
        doneSendingAW <= newDoneSendingAW;
      end
      tagged Read .r: shimMaster.slave.ar.put(r);
    endcase
  endrule

  (* descending_urgency = "passMemoryResponseRead, passMemoryResponseWrite" *)
  `ifdef TAGCONTROLLER_BENCHMARKING
  rule passMemoryResponseWrite (isInUse);
  `else
  rule passMemoryResponseWrite;
  `endif
    let rsp <- get(shimMaster.slave.b);
    CheriMemResponse mr = axi2mem_rsp(Write(rsp));
    debug2("AXItagcontroller", $display("<time %0t TagController> AXI Memory write response ", $time, fshow(rsp)));
    tagCon.memory.response.put(mr);
  endrule
  `ifdef TAGCONTROLLER_BENCHMARKING
  rule passMemoryResponseRead (isInUse);
  `else
  rule passMemoryResponseRead;
  `endif
    let rsp <- get(shimMaster.slave.r);
    CheriMemResponse mr = axi2mem_rsp(Read(rsp));
    debug2("AXItagcontroller", $display("<time %0t TagController> AXI Memory read response ", $time, fshow(rsp)));
    tagCon.memory.response.put(mr);
  endrule

  method clear if (reset_done) = action
    newRst.assertReset;
    shimSlave.clear;
    shimMaster.clear;
  endaction;

  interface slave  = shimSlave.slave;
  interface master = shimMaster.master;

`ifdef PERFORMANCE_MONITORING
  method events = tagCon.events;
`endif

`ifdef TAGCONTROLLER_BENCHMARKING
  method Action set_isInUse(Bool inUse);
    isInUse <= inUse;
    // Need to clear to remove packets still in buffer
    shimMaster.clear;
  endmethod
  method Bool isIdle = tagCon.isIdle;
`endif
endmodule


typedef enum {Zeroing, WaitingForReq, GettingRootTags, WritingRootTags, GettingLeafTags, WritingLeafTags, ReturnWriteResponse} State deriving (Bits,FShow,Eq);
 
typedef struct {
  CheriPhyAddr startAddr;
  Integer size;
  Integer shiftAmnt;
  Integer groupFactor;
  Integer groupFactorLog;
} TableLvl deriving (FShow);

// Can be used for initialising the tag table in DRAM
// - Starts by zeroing the root tag table 
// - When given a write, sets tags for that address and forwards data
// - If tag set causes 0->1 root transition, writes all 0s in leaf
// - Write responses ids are meaningless!! 
`ifdef TAGCONTROLLER_BENCHMARKING
module mkWriteAndSetTagControllerAXI#(
  Bool inUse
  )(TagControllerAXI#(id_, addr_,TMul#(CheriBusBytes, 8)))
`else 
module mkWriteAndSetTagControllerAXI
  (TagControllerAXI#(id_, addr_,TMul#(CheriBusBytes, 8)))
`endif
  provisos (
    Add#(a__, id_, CheriTransactionIDWidth), 
    Add#(b__, id_, SizeOf#(ReqId)), 
    Add#(c__, addr_, 64)
    // Add#(c__, 36, addr_)
  );

  let    clk <- exposeCurrentClock;
  let newRst <- mkReset(0, True, clk);
 
  `ifdef TAGCONTROLLER_BENCHMARKING
  Reg#(Bool) isInUse <- mkReg(False);
  `endif

  //Workaround: these are being enqueued while full in Piccolo. Made the buffer size larger (32 from 4)
  AXI4_Shim#(id_, addr_, TMul#(CheriBusBytes, 8), 0, CapsPerFlit, 0, 1, CapsPerFlit) shimSlave  <- mkAXI4ShimBypassFIFOF;//mkAXI4ShimFF;
  AXI4_Shim#(SizeOf#(ReqId), addr_, TMul#(CheriBusBytes, 8), 0, 0, 0, 0, 0) shimMaster <- mkAXI4ShimBypassFIFOF;
  
  let awreqff <- mkBypassFIFOF;
  let addrOffset <- mkReg(0);
  Reg#(Bool) reset_done <- mkReg(False);

  rule propagateReset(!reset_done);
      newRst.assertReset;
      shimSlave.clear;
      shimMaster.clear;
      reset_done <= True;
  endrule

  rule getCacheAW;
    let awreq <- get(shimSlave.master.aw);
    awreqff.enq(awreq);
  endrule

  Int#(40) table_end_addr = fromInteger(TagTableStructure::table_end_addr);
  Int#(40) table_start_addr = fromInteger(TagTableStructure::table_start_addr);
  Int#(40) covered_start_addr = fromInteger(TagTableStructure::covered_start_addr);

  function TableLvl lvlDesc (Integer d);
    Integer sz;
    // leaf lvl
    sz = div(covered_mem_size,8*valueof(CapBytes));
    TableLvl tlvl = TableLvl {
          startAddr: unpack(pack(table_end_addr)-fromInteger(sz)),
          size: sz,
          shiftAmnt: 0,
          groupFactor: 0,
          groupFactorLog: 0
      };
    // root lvt
    if (d > 0) begin
      TableLvl t = lvlDesc(d-1);
      sz = div(t.size, tableStructure[d]);
      tlvl = TableLvl {
          startAddr: unpack(pack(t.startAddr)-fromInteger(sz)),
          size: sz,
          shiftAmnt: t.shiftAmnt + log2(tableStructure[d]),
          groupFactor: tableStructure[d],
          groupFactorLog: log2(tableStructure[d])
      };
    end
    tlvl.startAddr.byteOffset = 0;
    return tlvl;
  endfunction
  // table descriptor has leaf lvl 0 ---> root lvl 1
  Vector#(2,TableLvl) tableDesc = genWith(lvlDesc);

  function ActionValue#(CheriPhyBitAddr) getTableAddr(int cd, CheriMemRequest req) = actionvalue
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Identifying tag addr for req: ", $time, fshow(req)));
    
    CheriCapAddress capAddr = unpack(pack(req.addr) - pack(covered_start_addr));
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> capAddr: ", $time, fshow(capAddr)));
    
    CapNumber cn = capAddr.capNumber;
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> capNumber: ", $time, fshow(cn)));
    
    TableLvl t = tableDesc[cd];
    CheriPhyBitAddr bitAddr = unpack(zeroExtend(cn >> t.shiftAmnt));
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> bitAddr relative: ", $time, fshow(bitAddr)));
    
    bitAddr.byteAddr = unpack(pack(bitAddr.byteAddr) + pack(t.startAddr));
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> bitAddr final: ", $time, fshow(bitAddr)));
    return bitAddr;
  endactionvalue;

  Reg#(Bit#(id_)) idCount <- mkReg(0);

  Reg#(State) state <- mkReg(Zeroing);
  Reg#(CheriMemRequest) request <- mkReg(?);
  Reg#(Bool) rootWasZero <- mkReg(?);

  function Action sendGetTags(CheriPhyAddr byte_addr, String level) = action 

    Bit#(64) tmp = zeroExtend(pack(byte_addr) & (~0 << pack(cheriBusBytes)));

    AXI4_ARFlit#(SizeOf#(MemTypesCHERI::ReqId), addr_, 0) tag_req = defaultValue;
    tag_req.arid = zeroExtend(idCount);
    idCount <= idCount + 1;
    tag_req.araddr = truncate(tmp);
    tag_req.arsize = 16; //TODO (what size to put here?)
    tag_req.arcache = 4'b1011; //TODO (what to put here?)
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Sending %s tag read request: ", $time, level, fshow(tag_req)));
    shimMaster.slave.ar.put(tag_req);
  endaction;

  function Action sendNewTags(CheriPhyAddr byte_addr, Bit#(CheriDataWidth) new_tags,  String level) = action 
    // Write the new tags
    Bit#(64) tmp = zeroExtend(pack(byte_addr) & (~0 << pack(cheriBusBytes)));

    AXI4_AWFlit#(SizeOf#(MemTypesCHERI::ReqId), addr_, 0) rootUpdateReq = defaultValue;
    rootUpdateReq.awid = zeroExtend(idCount);
    idCount <= idCount + 1;
    rootUpdateReq.awaddr = truncate(tmp);
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Sending %s tag awflit: ", $time, level, fshow(rootUpdateReq)));
    shimMaster.slave.aw.put(rootUpdateReq);
    
    AXI4_WFlit#(TMul#(CheriBusBytes, 8), 0) updateReq = defaultValue;
    updateReq.wdata = new_tags;
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Sending %s tag wflit: ", $time, level, fshow(updateReq)));
    shimMaster.slave.w.put(updateReq);

  endaction;    

  `ifdef TAGCONTROLLER_BENCHMARKING
  let not_expecting_dram_responses = state==WaitingForReq;
  `else
  let not_expecting_dram_responses = state==WaitingForReq;
  `endif

  rule passDataWrite (state==WaitingForReq);
    let awreq = awreqff.first;
    let wreq <- get(shimSlave.master.w);
    if (wreq.wlast) begin
      addrOffset <= 0;
      awreqff.deq;
    end else begin
      $display("PANIC: only bursts of length 1 supported here");
    end
    let mreq = axi2mem_req(Write(WriteReqFlit{aw: awreq, w: wreq}));
  
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Received new write request: ", $time, fshow(mreq)));
    
    // Forward the data component of the write
    AXI4_AWFlit#(SizeOf#(MemTypesCHERI::ReqId), addr_, 0) dataAddrReq = defaultValue;
    dataAddrReq.awid = zeroExtend(idCount);
    idCount <= idCount + 1;
    dataAddrReq.awaddr = awreq.awaddr;
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Sending awflit: ", $time, fshow(dataAddrReq)));
    shimMaster.slave.aw.put(dataAddrReq);
    
    AXI4_WFlit#(TMul#(CheriBusBytes, 8), 0) dataReq = defaultValue;
    dataReq.wdata = wreq.wdata;
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Sending wflit: ", $time, fshow(dataReq)));
    shimMaster.slave.w.put(dataReq);
    
    request <= mreq;
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> TRANSITIONING: WaitingForReq->GettingRootTags", $time));
    state <= GettingRootTags;
  endrule

  Reg#(CheriPhyAddr) zeroAddr <- mkReg(unpack(pack(table_start_addr)));
  FF#(Bool, 256) zeros_without_resp <- mkUGFFDebug("zeros_without_resp");

  rule doZeroing (state == Zeroing && zeros_without_resp.notFull); 
    TableLvl t = tableDesc[1];
    if (zeroAddr < unpack(pack(t.startAddr) + fromInteger(t.size))) begin
      // prepare memory request
      Bit#(CheriDataWidth) tags = 0;
      sendNewTags(zeroAddr,tags,"zeroing root");
      debug2("AXItagwriter", $display("<time %0t AXItagwriter> Sent zeroing write req, no_resp.remaining: ", $time, fshow(zeros_without_resp.remaining)));

      zeros_without_resp.enq(?);
      
      zeroAddr.lineNumber <= zeroAddr.lineNumber + 1;
    end else if (!zeros_without_resp.notEmpty) begin
      //Wait for all outstaning responses to be processed
      debug2("AXItagwriter", $display("<time %0t AXItagwriter> TRANSITIONING: Zeroing->WaitingForReq", $time));
      state <= WaitingForReq;
    end
  endrule

  rule drainZeroingResps (state == Zeroing && zeros_without_resp.notEmpty); 
    let b <- get(shimMaster.slave.b);
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Received zeroing write resposne: ", $time, fshow(b)));
    zeros_without_resp.deq();
  endrule

  rule getCurrentRootTags (state==GettingRootTags);
    // Get data write response before proceeding
    let b <- get(shimMaster.slave.b);
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Received data write resposne: ", $time, fshow(b)));
    
    let root_bit_addr <- getTableAddr(1,request);
    sendGetTags(root_bit_addr.byteAddr, "root");
    
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> TRANSITIONING: GettingRootTags->WritingRootTags", $time));
    state <= WritingRootTags;
  endrule
  
  rule updatingRootTags (state==WritingRootTags);
    // Get data write response before proceeding
    let curr_tag_data <- get(shimMaster.slave.r);
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Received root tag response: ", $time, fshow(curr_tag_data)));
   
    let root_bit_addr <- getTableAddr(1,request);
    Bit#(CheriDataWidth) root_tags = curr_tag_data.rdata;
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Current root tags: ", $time, fshow(root_tags)));


    // Need to explicity inform that is 128 bits long or << will wrap around
    Bit#(CheriDataWidth) new_tags_set = 1;
    // Need to extend this otherwise multiplying by 8 wraps it round
    Bit#(7) byte_offset = zeroExtend(root_bit_addr.byteAddr.byteOffset);
    new_tags_set = (
      // We are setting tags only!
      (new_tags_set << (8 * byte_offset)) 
      << root_bit_addr.bitOffset
    );
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Root bit address: ", $time, fshow(root_bit_addr)));
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Tags being set: ", $time, fshow(new_tags_set)));

    if ((root_tags & new_tags_set)==0) rootWasZero <= True;
    else rootWasZero <= False;

    root_tags = root_tags | new_tags_set;

    debug2("AXItagwriter", $display("<time %0t AXItagwriter> New root tags: ", $time, fshow(root_tags)));

    sendNewTags(root_bit_addr.byteAddr, root_tags, "root");
    
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> TRANSITIONING: WritingRootTags->GettingLeafTags", $time));
    state <= GettingLeafTags;
  endrule

  rule getCurrentLeafTags (state==GettingLeafTags);
    // Get data write response before proceeding
    let b <- get(shimMaster.slave.b);
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Received root tag write response: ", $time, fshow(b)));
    
    let leaf_bit_addr <- getTableAddr(0,request);
    sendGetTags(leaf_bit_addr.byteAddr, "leaf");

    debug2("AXItagwriter", $display("<time %0t AXItagwriter> TRANSITIONING: GettingLeafTags->WritingLeafTags", $time));
    state <= WritingLeafTags;
  endrule

  rule updatingleafTags (state==WritingLeafTags);
    // Get data write response before proceeding
    let curr_tag_data <- get(shimMaster.slave.r);
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Received leaf tag response: ", $time, fshow(curr_tag_data)));
   
    let leaf_bit_addr <- getTableAddr(0,request);
    Bit#(CheriDataWidth) leaf_tags = curr_tag_data.rdata;
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Current leaf tags: ", $time, fshow(leaf_tags)));

    // Need to explicity inform that is 128 bits long or << will wrap around
    Bit#(CheriDataWidth) new_tags_set = 1;
    // Need to extend this otherwise multiplying by 8 wraps it round
    Bit#(7) byte_offset = zeroExtend(leaf_bit_addr.byteAddr.byteOffset);
    new_tags_set = (
      // We are setting tags only!
      (new_tags_set << (8 * byte_offset)) 
      << leaf_bit_addr.bitOffset
    );
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Leaf bit address: ", $time, fshow(leaf_bit_addr)));
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Tags being set: ", $time, fshow(new_tags_set)));

    if (rootWasZero) leaf_tags = new_tags_set;
    else leaf_tags = leaf_tags | new_tags_set;

    debug2("AXItagwriter", $display("<time %0t AXItagwriter> New leaf tags: ", $time, fshow(leaf_tags)));

    sendNewTags(leaf_bit_addr.byteAddr, leaf_tags, "leaf");
    
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> TRANSITIONING: WritingLeafTags->ReturnWriteResponse", $time));
    state <= ReturnWriteResponse;
  endrule

  rule returnWriteResponse (state==ReturnWriteResponse);
    let b <- get(shimMaster.slave.b);
    debug2("AXItagwriter", $display("<time %0t AXItagwriter> Received leaf  tag write response: ", $time, fshow(b)));

    AXI4_BFlit#(id_,0) bflit = defaultValue;
    shimSlave.master.b.put(bflit);

    debug2("AXItagwriter", $display("<time %0t AXItagwriter> TRANSITIONING: ReturnWriteResponse->WaitingForReq", $time));
    state <= WaitingForReq;
  endrule

  method clear if (reset_done) = action
    newRst.assertReset;
    shimSlave.clear;
    shimMaster.clear;
  endaction;

  interface slave  = shimSlave.slave;
  interface master = shimMaster.master;

`ifdef TAGCONTROLLER_BENCHMARKING
  method Action set_isInUse(Bool inUse);
    isInUse <= inUse;
    // Need to clear to remove packets still in buffer
    shimMaster.clear;
  endmethod
  method Bool isIdle = state==WaitingForReq;
`endif

`ifdef PERFORMANCE_MONITORING
  method events = ?;
`endif
endmodule
