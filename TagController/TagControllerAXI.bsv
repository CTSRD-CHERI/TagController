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
import Clocks :: *;

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
  interface AXI4_Master#(TAdd#(id_, 1), addr_, data_, 0, 0, 0, 0, 0) master;
  interface AXI4_Slave#(id_, addr_, data_, 0, CapsPerFlit, 0, 0, CapsPerFlit) slave;
  method Action clear;
endinterface

module mkTagControllerAXI(TagControllerAXI#(id_, addr_,128))
  provisos (Add#(a__, id_, SizeOf#(ReqId)), Add#(b__, TAdd#(id_, 1), SizeOf#(ReqId)), Add#(c__, addr_, 64));
  let tmp <- mkDbgTagControllerAXI(Invalid);
  return tmp;
endmodule
module mkDbgTagControllerAXI#(Maybe#(String) dbg)(TagControllerAXI#(id_, addr_,128))
  provisos (Add#(a__, id_, SizeOf#(ReqId)), Add#(b__, TAdd#(id_, 1), SizeOf#(ReqId)), Add#(c__, addr_, 64));
  let    clk <- exposeCurrentClock;
  let newRst <- mkReset(0, True, clk);
  TagControllerIfc tagCon <- mkTagController(reset_by newRst.new_rst);
  AXI4_Shim#(id_, addr_, 128, 0, CapsPerFlit, 0, 0, CapsPerFlit) shimSlave  <- mkAXI4ShimUGSizedFIFOF4;
  AXI4_Shim#(TAdd#(id_,1), addr_, 128, 0, 0, 0, 0, 0) shimMaster <- mkAXI4ShimUGSizedFIFOF4;
  FIFO#(Bit#(0)) limiter <- mkFIFO1;

  // Rules to feed the tag controller from the slave AXI interface
  // Ready if there is no read request or if the write request id is first.
  (* descending_urgency = "passCacheRead, passCacheWrite" *)
  rule passCacheWrite(!shimSlave.master.ar.canPeek || ((shimSlave.master.ar.peek.arid-shimSlave.master.aw.peek.awid)<4));
    let awreq <- get(shimSlave.master.aw);
    let wreq <- get(shimSlave.master.w);
    tagCon.cache.request.put(
      axi2mem_req(Write(WriteReqFlit{aw: awreq, w: wreq}))
    );
    limiter.enq(?);
    //printDbg(dbg, $format("TagController write request ", fshow(awreq), " - ", fshow(wreq)));
  endrule
  // Ready if there is no write request or if the read request id is first.
  rule passCacheRead(!shimSlave.master.aw.canPeek || ((shimSlave.master.aw.peek.awid-shimSlave.master.ar.peek.arid)<4));
    let ar <- get(shimSlave.master.ar);
    tagCon.cache.request.put(axi2mem_req(Read(ar)));
    limiter.enq(?);
    //printDbg(dbg, $format("TagController read request ", fshow(ar)));
  endrule
  rule passCacheResponse;
    CheriMemResponse mr <- tagCon.cache.response.get();
    if (getLastField(mr)) limiter.deq;
    AXI_Helpers::MemRsp#(id_) ar = mem2axi_rsp(mr);
    case (ar) matches
      tagged Write .w: shimSlave.master.b.put(w);
      tagged Read  .r: shimSlave.master.r.put(r);
    endcase
    //printDbg(dbg, $format("TagController response ", fshow(ar)));
  endrule

  // Rules to forward requests from the tag controller to the master AXI interface.
  rule passMemoryRequest;
    CheriMemRequest mr <- tagCon.memory.request.get();
    DRAMReq#(TAdd#(id_,1), addr_) ar = mem2axi_req(mr);
    case (ar) matches
      tagged Write .w: begin
        shimMaster.slave.aw.put(w.aw);
        shimMaster.slave.w.put(w.w);
      end
      tagged Read .r: shimMaster.slave.ar.put(r);
    endcase
    //printDbg(dbg, $format("Memory request ", fshow(ar)));
  endrule
  (* descending_urgency = "passMemoryResponseRead, passMemoryResponseWrite" *)
  rule passMemoryResponseWrite;
    let rsp <- get(shimMaster.slave.b);
    CheriMemResponse mr = axi2mem_rsp(Write(rsp));
    tagCon.memory.response.put(mr);
    //printDbg(dbg, $format("Memory write response ", fshow(rsp)));
  endrule
  rule passMemoryResponseRead;
    let rsp <- get(shimMaster.slave.r);
    CheriMemResponse mr = axi2mem_rsp(Read(rsp));
    tagCon.memory.response.put(mr);
    //printDbg(dbg, $format("Memory read response ", fshow(rsp)));
  endrule

  method clear = action
    newRst.assertReset;
    shimSlave.clear;
    shimMaster.clear;
    limiter.clear;
  endaction;
  interface slave  = shimSlave.slave;
  interface master = shimMaster.master;
endmodule
