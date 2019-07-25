/*-
 * Copyright (c) 2013-2018 Jonathan Woodruff
 * Copyright (c) 2013 Philip Withnall
 * Copyright (c) 2013 Robert M. Norton
 * Copyright (c) 2014-2016 Alexandre Joannou
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
import GetPut::*;
import Debug::*;
import Connectable::*;
import FF::*;
import Vector::*;
import TagTableStructure::*;
`ifdef STATCOUNTERS
import StatCounters::*;
`endif
`ifndef NOTAG
//import TagLookup::*;
import MultiLevelTagLookup::*;
`endif

/******************************************************************************
 * mkTagController
 *
 * This module provides a proxy for memory accesses which adds support for
 * tagged memory. It connects to memory on one side and the processor/L2 cache
 * on the other. Tag values are stored in memory (currently at the top of DRAM
 * and there is a cache of 32ki tags (representing 1MB memory) stored in BRAM.
 * Read responses are amended with the correct tag value and write requests update
 * the value in the tag cache (which is later written back to memory).
 *
 *****************************************************************************/

// interface types
///////////////////////////////////////////////////////////////////////////////

interface TagControllerIfc;
  interface Slave#(CheriMemRequest, CheriMemResponse)  cache;
  interface Master#(CheriMemRequest, CheriMemResponse) memory;
  `ifdef STATCOUNTERS
  interface Get#(ModuleEvents) cacheEvents;
  `endif
endinterface

typedef struct {
  Bool tagOnlyRead;
  Bit#(2) bank;
  CheriMasterID masterID;
  CheriTransactionID transactionID;
} AddrFrame deriving(Bits, FShow);

// internal types
///////////////////////////////////////////////////////////////////////////////

typedef enum {TagLookupReq, StdReq} MemReqType deriving (Bits, Eq);

// mkTagController module definition
///////////////////////////////////////////////////////////////////////////////

(*synthesize*)
module mkTagController(TagControllerIfc);

  // constant parameters
  /////////////////////////////////////////////////////////////////////////////

  `ifndef NOTAG
  // masterID used for memory requests from the lookup engine
  CheriMasterID mID = 1;

  // components instanciations
  /////////////////////////////////////////////////////////////////////////////

  `ifndef NOTAG
  // tag lookup module
  //TagLookupIfc tagLookup <- mkTagLookup(mID);
  TagLookupIfc tagLookup <- mkMultiLevelTagLookup(
                                mID,
                                unpack(fromInteger(table_end_addr)),
                                tableStructure,
                                unpack(fromInteger(table_start_addr)),
                                covered_mem_size
                            );
  // lookup responses fifo
  FF#(CheriTagResponse,4) lookupRsp <- mkUGFFDebug("TagController_lookupRsp");
  FF#(AddrFrame,4)          addrFrame <- mkUGFFDebug("TagController_addrFrame");
  // lookup response frame to access (for multi-flit transactions)
  Reg#(Bit#(2)) frame <- mkReg(0);
  `endif
  // memory requests fifo
  FF#(CheriMemRequest, 2)   mReqs <- mkFF();
  // memory responses fifo
  FF#(CheriMemResponse, 32) mRsps <- mkUGFFDebug("TagController_mRsps");

  `ifndef NOTAG
  // module rules
  /////////////////////////////////////////////////////////////////////////////

  // forwards tag lookup requests to the memory interface
  rule forwardLookupReqs(tagLookup.memory.request.canGet() && mReqs.notFull());
    debug2("tagcontroller",
      $display(
        "<time %0t TagController> Injecting request from tag lookup engine: ",
        $time, fshow(tagLookup.memory.request.peek())
    ));
    CheriMemRequest r <- tagLookup.memory.request.get();
    if (r.operation matches tagged Write .wop) begin
      mReqs.enq(r);
    end else mReqs.enq(r);
  endrule
  // drain tag lookup responses out of the tag lookup engine
  mkConnection(tagLookup.cache.response,toCheckedPut(ff2fifof(lookupRsp)));
  `endif

  // helper functions / signals
  /////////////////////////////////////////////////////////////////////////////
  // look at the next memory response
  function CheriMemResponse peekMemResponse();
    CheriMemResponse resp = mRsps.first;
    CheriMemResponse newResp = resp;
    if (addrFrame.first().tagOnlyRead && lookupRsp.notEmpty()) begin
      newResp = CheriMemResponse{
          masterID: addrFrame.first().masterID,
          transactionID: addrFrame.first().transactionID,
          error: NoError,
          operation: tagged Read{last: True, tagOnlyRead: True}
      };
      `ifndef NOTAG
        // look at the tag lookup response
        case (lookupRsp.first()) matches
          tagged Covered .ts : newResp.data.data = zeroExtend(pack(ts));
          tagged Uncovered   : newResp.data.data = 0;
        endcase
      `endif
      newResp.data.cap = unpack(0);
    end else begin
      // initialise new response to response coming from memory
      newResp = resp;
      // in case of read, need to construct the tags
      if (resp.operation matches tagged Read .rop) begin
        Vector#(TDiv#(CheriDataWidth,CapWidth),Bool) tags = replicate(True);
        `ifndef NOTAG
          // look at the tag lookup response
          case (lookupRsp.first()) matches
            tagged Covered .ts : tags = unpack(ts[addrFrame.first().bank + frame]);
            tagged Uncovered   : tags = unpack(0);
          endcase
        `endif
        // update the new response with appropriate tags
        newResp.data.cap = tags;
      end
    end
    return newResp;
  endfunction

  Bool slvCanPut =
    `ifndef NOTAG
    tagLookup.cache.request.canPut() && !tagLookup.memory.request.canGet() &&
    `endif
    mReqs.notFull();
    
  // Comment in when debugging flow control.
  //rule debug;
  //  debug2("tagcontroller", $display("<time %0t TagController> slvCanPut(1):%x tagLookup.cache.request.canPut(1):%x tagLookup.memory.request.canGet(0):%x mReqs.notFull(1):%x", 
  //                                   $time, slvCanPut, tagLookup.cache.request.canPut(), tagLookup.memory.request.canGet(), mReqs.notFull()));
  //endrule

  Bool slvCanGet = mRsps.notEmpty();
  `ifndef NOTAG
  // If the tag is not ready for a read response, we can't get.
  if (mRsps.first.operation matches tagged Read .rop &&& !lookupRsp.notEmpty()) slvCanGet = False;
  if (addrFrame.notEmpty())
    // this bit is the tagOnlyRead bit.
    if (addrFrame.first().tagOnlyRead && lookupRsp.notEmpty()) slvCanGet = True;
  `endif

  // module Slave interface
  /////////////////////////////////////////////////////////////////////////////

  interface Slave cache;
    // request side
    ///////////////////////////////////////////////////////
    interface CheckedPut request;
      method Bool canPut() = slvCanPut;
      method Action put(CheriMemRequest req) if (slvCanPut);
        debug2("tagcontroller", $display("<time %0t TagController> New request: ", $time, fshow(req)));
        // We only enqueue request to DRAM if this is not a tagOnlyRead
        if (req.operation matches tagged Write .wop &&& req.addr >= unpack(fromInteger(table_start_addr)) && req.addr < unpack(fromInteger(table_end_addr))) begin
          req.operation = tagged Write {
              uncached: wop.uncached,
              conditional: wop.conditional,
              byteEnable: replicate(False),
              bitEnable: 0,
              data: wop.data,
              last: wop.last
          };
        end
        Bool canDoEnq = True;
        if (req.operation matches tagged Read .rop &&& rop.tagOnlyRead) canDoEnq=False;
        if (canDoEnq) mReqs.enq(req);
        `ifndef NOTAG
          tagLookup.cache.request.put(req);
          if (req.operation matches tagged Read .rop) begin
            // Stash the frame of the incoming address so that we can select the correct tags for the response.
            addrFrame.enq(AddrFrame{tagOnlyRead: rop.tagOnlyRead, bank: truncateLSB({req.addr.lineNumber[1:0],req.addr.byteOffset}), masterID: req.masterID, transactionID: req.transactionID});
          end
        `endif
      endmethod
    endinterface
    // response side
    ///////////////////////////////////////////////////////
    interface CheckedGet response;
      method Bool canGet() = slvCanGet;
      method CheriMemResponse peek() = peekMemResponse();
      method ActionValue#(CheriMemResponse) get() if (slvCanGet);
        // prepare memory response
        CheriMemResponse resp = peekMemResponse();
        // dequeue memory response fifo only when the response is not tagOnlyRead
        Bool canDoDeq = True;
        if (resp.operation matches tagged Read .rop &&& rop.tagOnlyRead==True) canDoDeq=False;
        if (canDoDeq) mRsps.deq();
        `ifndef NOTAG
        // in case of read response ...
        if (resp.operation matches tagged Read .rop) begin
          // on the last flit,
          if (rop.last || rop.tagOnlyRead) begin
            lookupRsp.deq(); // dequeue the tag lookup response fifo
            addrFrame.deq();
            frame <= 0;  // reset the current frame
          end else frame <= frame + 1; // for non last flits, increment frame
        end else frame <= 0;
        `endif
        debug2("tagcontroller", $display("<time %0t TagController> Returning response: ", $time, fshow(resp)));
        return resp;
      endmethod
    endinterface
  endinterface

  // module Master interface
  /////////////////////////////////////////////////////////////////////////////

  interface Master memory;
    interface request  = toCheckedGet(ff2fifof(mReqs));
    interface CheckedPut response;
      method Bool canPut();
        return (mRsps.notFull() && tagLookup.memory.response.canPut());
      endmethod
      method Action put(CheriMemResponse r) if (mRsps.notFull() && tagLookup.memory.response.canPut());
        `ifdef NOTAG
          mRsps.enq(r);
        `else
          MemReqType reqType = (r.masterID == mID) ? TagLookupReq : StdReq;
          debug2("tagcontroller", $display("<time %0t TagController> response from memory: source=%x ", $time, reqType, fshow(r)));
          if (reqType == TagLookupReq) begin
            tagLookup.memory.response.put(r);
            debug2("tagcontroller", $display("<time %0t TagController> tag response", $time));
          end else begin
            mRsps.enq(r);
            debug2("tagcontroller", $display("<time %0t TagController> memory response", $time));
          end
        `endif
      endmethod
    endinterface
  endinterface

  // module cacheEvents interface
  /////////////////////////////////////////////////////////////////////////////

  `ifdef STATCOUNTERS
  interface Get cacheEvents;
    method ActionValue#(ModuleEvents) get () = tagLookup.cacheEvents.get();
  endinterface
  `endif

endmodule
