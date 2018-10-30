/*-
 * Copyright (c) 2018 Jonathan Woodruff
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
import Debug::*;
import SourceSink::*;
import AXI_Helpers::*;
import AXI4::*;
import TagController::*;
import FIFO::*;

/******************************************************************************
 * mkTagControllerAXI
 *
 * A wrapper around the CHERI tag controller to export an AXI interface.
 *
 *****************************************************************************/

interface TagControllerAXI#(
  numeric type addr_,
  numeric type data_);
  interface AXIMaster#(8, addr_, data_, 0, 0, 0, 0, 0) master;
  interface AXISlave#(4, addr_, TAdd#(data_,TDiv#(data_,128)), 0, 0, 0, 0, 0) slave;
endinterface

module mkTagControllerAXI(TagControllerAXI#(32,128));
  TagControllerIfc tagCon <- mkTagController();
  AXIShim#(4, 32, 129, 0, 0, 0, 0, 0) shimSlave  <- mkAXIShim;
  AXIShim#(8, 32, 128, 0, 0, 0, 0, 0) shimMaster <- mkAXIShim;
  FIFO#(Bit#(0)) limiter <- mkFIFO1;
  
  // Rules to feed the tag controller from the slave AXI interface
  // Ready if there is no read request or if the write request id is first.
  rule passCacheWrite(!shimSlave.master.ar.canGet || ((shimSlave.master.ar.peek.arid-shimSlave.master.aw.peek.awid)<4));
    let awreq <- shimSlave.master.aw.get;
    let wreq <- shimSlave.master.w.get;
    tagCon.cache.request.put(
      axi2mem_req(Write(WriteReqFlit{aw: awreq, w: wreq}))
    );
    limiter.enq(?);
    debug2("axiBridge", $display("TagController write request ", fshow(awreq), fshow(wreq)));
  endrule
  // Ready if there is no write request or if the read request id is first.
  rule passCacheRead(!shimSlave.master.aw.canGet || ((shimSlave.master.aw.peek.awid-shimSlave.master.ar.peek.arid)<4));
    let ar <- shimSlave.master.ar.get;
    tagCon.cache.request.put(axi2mem_req(Read(ar)));
    limiter.enq(?);
    debug2("axiBridge", $display("TagController read request ", fshow(ar)));
  endrule
  rule passCacheResponse;
    CheriMemResponse mr <- tagCon.cache.response.get();
    if (getLastField(mr)) limiter.deq;
    MemRsp ar = mem2axi_rsp(mr);
    case (ar) matches
      tagged Write .w: shimSlave.master.b.put(w);
      tagged Read  .r: shimSlave.master.r.put(r);
    endcase
    debug2("axiBridge", $display("TagController response ", fshow(ar)));
  endrule
  
  // Rules to forward requests from the tag controller to the master AXI interface.
  rule passMemoryRequest;
    CheriMemRequest mr <- tagCon.memory.request.get();
    DRAMReq#(32) ar = mem2axi_req(mr);
    case (ar) matches
      tagged Write .w: begin
        shimMaster.slave.aw.put(w.aw);
        shimMaster.slave.w.put(w.w);
      end
      tagged Read .r: shimMaster.slave.ar.put(r);
    endcase
    debug2("axiBridge", $display("Memory request ", fshow(ar)));
  endrule
  rule passMemoryResponseWrite;
    let rsp <- shimMaster.slave.b.get;
    CheriMemResponse mr = axi2mem_rsp(Write(rsp));
    tagCon.memory.response.put(mr);
    debug2("axiBridge", $display("Memory write response ", fshow(rsp)));
  endrule
  rule passMemoryResponseRead;
    let rsp <- shimMaster.slave.r.get;
    CheriMemResponse mr = axi2mem_rsp(Read(rsp));
    tagCon.memory.response.put(mr);
    debug2("axiBridge", $display("Memory read response ", fshow(rsp)));
  endrule
  
  interface slave  = shimSlave.slave;
  interface master = shimMaster.master;
endmodule
