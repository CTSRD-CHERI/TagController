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
import RoutableCHERI::*;
import GetPut::*;
import Debug::*;
import Connectable::*;
import FF::*;
import Vector::*;
import Bag::*;
import VnD::*;
import TagTableStructure::*;
`ifdef STATCOUNTERS
import StatCounters::*;
`elsif PERFORMANCE_MONITORING
import PerformanceMonitor::*;
import CacheCore::*;
`endif
//import TagLookup::*;
import MultiLevelTagLookup::*;
import PipelinedTagLookup::*;
import ConfigReg::*;

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
  `elsif PERFORMANCE_MONITORING
  method EventsCacheCore events;
  `endif
  `ifdef TAGCONTROLLER_BENCHMARKING
  method Bool isIdle;
  `endif
endinterface

typedef struct {
  Bool tagOnlyRead;
  CapOffsetInLine bank;
  CheriMasterID masterID;
  CheriTransactionID transactionID;
} AddrFrame deriving(Bits, Eq, FShow);

// internal types
///////////////////////////////////////////////////////////////////////////////

typedef TLog#(TDiv#(CapWidth, CheriDataWidth)) LogFlitsPerCap;
typedef TMax#(TDiv#(CheriDataWidth,CapWidth), 1) CapsPerFlit;
typedef enum {TagLookupReq, StdReq} MemReqType deriving (FShow, Bits, Eq);

// Moved to MemTypesCHERI
// // RUNTYPE: in flight operations
// // NOTE: must be a power of 2
// // typedef 4 InFlight;
// typedef 16 InFlight;

typedef 8 MaxBurstLength;
typedef Bit#(TLog#(MaxBurstLength)) Frame;
typedef Bit#(8) ReqIdCount;

// // Seems to not be used by anything any more!
// // There now exist a TagRequestID (used to associate LookupReqInfo with tag responses)
// typedef struct {
//   ReqId reqId;
//   ReqIdCount count; // Less than 256 outstanding transactions for one ID?  Surely?
// } TagReqId deriving(Bits, Eq, FShow);

typedef struct {
  ReqId id;
  Bool tagOnlyRead;
  // RUNTYPE: No lookup write responses
  // Bool useResponse;
} LookupReqInfo deriving(Bits, Eq, FShow);

typedef struct {
  // RUNTYPE: out of order
  ReqId id;
  CheriTagResponse rsp;
  Bool tagOnlyRead;
} LookupRspInfo deriving(Bits, Eq, FShow);

// mkTagController module definition
///////////////////////////////////////////////////////////////////////////////

(*synthesize*)
module mkTagController(TagControllerIfc);
  // constant parameters
  /////////////////////////////////////////////////////////////////////////////

  // masterID used for memory requests from the lookup engine
  CheriMasterID mID = 1;

  // components instanciations
  /////////////////////////////////////////////////////////////////////////////

  // tag lookup module
  //TagLookupIfc tagLookup <- mkTagLookup(mID);

  // RUNTYPE: Null lookups
  // TagLookupIfc tagLookup <- mkMultiLevelTagLookup(
  //                               mID,
  //                               unpack(fromInteger(table_end_addr)),
  //                               tableStructure,
  //                               unpack(fromInteger(table_start_addr)),
  //                               covered_mem_size
  //                           );
  // TagLookupIfc tagLookup <- mkNullMultiLevelTagLookup();
  // RUNTYPE: Pipelined lookups
  TagLookupIfc tagLookup <- mkPipelinedTagLookup(
                                mID,
                                unpack(fromInteger(table_end_addr)),
                                tableStructure,
                                unpack(fromInteger(table_start_addr)),
                                covered_mem_size
                            );

  // lookup responses fifo
  // Size of these structures must be >= number of outstandring requests from the L2.
  // RUNTYPE: out of order
  // FFBag#(InFlight, ReqId, LookupRspInfo, InFlight) lookupRsp <- mkFFBag;
  FF#(LookupRspInfo, InFlight) lookupRsp <- mkUGFF;
  FFBag#(InFlight, ReqId, AddrFrame, InFlight)     addrFrame <- mkFFBag;
  // RUNTYPE: Buffer pending tag requests
  // Old version was size 2
  // FF#(LookupReqInfo, 2)                            pendingLookups <- mkFF;
  // Now keep track of InFlight pending lookups
  // FF#(LookupReqInfo, InFlight)                     pendingLookups <- mkFF;

  // TagLookup cannot handle multiple requests with same id so limit depth to 1
  // This means a request can only be over taken by a maximum of InFlight others
  // RUNTYPE: no lookup write responses
  Bag#(InFlight, TagRequestID, LookupReqInfo) pendingLookups <- mkSmallBag;
  // Reg#(Vector#(InFlight, VnD#(LookupReqInfo))) pendingLookups <- mkReg(replicate(VnD{v: False, d: ?}));

  Reg#(TagRequestID) currentRequestID <- mkConfigReg(0);
  
  // RUNTYPE: no lookup write responses
  // Wire#(VnD#(LookupReqInfo)) newTagRequest <- mkDWire(VnD{v: False, d: ?});
  // Wire#(VnD#(TagRequestID)) newTagResponse <- mkDWire(VnD{v: False, d: ?});

  // function Bool valid(VnD#(LookupReqInfo) val) = val.v;

  // rule updatePendingLookups;
  //   let newPendingLookups = pendingLookups;
  //   if (newTagRequest.v) begin 
  //     newPendingLookups[currentRequestID] = newTagRequest;
  //   end
  //   if (newTagResponse.v) begin 
  //     newPendingLookups[newTagResponse.d].v = False;
  //   end
  //   pendingLookups <= newPendingLookups;

  //   TagRequestID nextId = 0;
  //   for (Integer i = 0; i < valueOf(InFlight); i=i+1) begin
  //     if (!newPendingLookups[i].v) nextId = fromInteger(i);
  //   end
  //   currentRequestID <= nextId;
  // endrule

  // As well as buffering up requests to taglookup (which can vary in response time)
  // FF#(CheriTagRequest, InFlight)                   pendingLookupRequests <- mkLFF();
  FF#(CheriTagRequest, InFlight)                   pendingLookupRequests <- mkFFBypass();
  // FF#(CheriTagRequest, 1)                   pendingLookupRequests <- mkUGLFF1();


  // lookup response frame to access (for multi-flit transactions)
  Reg#(Frame) memoryResponseFrame <- mkReg(0);
  Reg#(CheriTagWrite) tagWrite <- mkReg(unpack(0));
  // memory requests fifo
  
  // For sims with latency
  // FF#(CheriMemRequest, TMul#(MaxBurstLength, 2)) mReqs <- mkUGFF();
  FF#(CheriMemRequest, TMul#(MaxBurstLength, InFlight)) mReqs <- mkUGFF();

  FF#(Bit#(0),InFlight) mReqBurst <- mkUGFF;
  // memory responses fifo
  // RUNTYPE: out of order
  // FF#(CheriMemResponse, TMul#(MaxBurstLength, InFlight)) mRsps <- mkUGFFDebug("TagController_mRsps");
  FFBag#(
      InFlight
    , ReqId
    , CheriMemResponse
    , TMul#(MaxBurstLength, InFlight)
  ) mRsps <- mkFFBag;
  
  // Forwarding requests from the tag cache takes priority unless we have an ongoing burst request being forwarded,
  // or if there is not enough space for a full burst.
  Bool slvCanPut =
    // Can send a request to the tag cache
    // RUNTYPE: Buffer pending tag requests
    // tagLookup.cache.request.canPut() &&
    pendingLookupRequests.notFull() &&
    // Can forward the data request to memory
    mReqs.notFull() && mReqBurst.notFull() && 
    // Can stash info about which tags we want
    !addrFrame.full() &&
    // RUNTYPE: No lookup write responses
    // We are not at risk of having two in flight read requests with the same request ID
    // !all(valid, pendingLookups);
    !pendingLookups.isMember(currentRequestID).v;

  // module rules
  /////////////////////////////////////////////////////////////////////////////

  // drain tag lookup responses out of the tag lookup engine
  rule getTagLookupResponse;
    CheriTagResponse tags <- tagLookup.cache.response.get();

    // Ignore validity - can only get responses for IDs that are inflight
    // LookupReqInfo lookup = pendingLookups.isMember(tags.request_id).d;

    // RUNTYPE: No lookup write responses
    // Validity encodes whether read or write response
    // LookupReqInfo matching_lookup = pendingLookups[tags.request_id].d;
    LookupReqInfo matching_lookup = pendingLookups.isMember(tags.request_id).d;

    // if (matching_lookup.useResponse) begin
    
      debug2("tagcontroller", $display(
        "<time %0t TagController> Completed lookup response: ", $time, 
        fshow(matching_lookup.id), " - ", 

        // RUNTYPE: out of order
        // RUNTYPE: no lookup write responses
        // fshow(LookupRspInfo{rsp: tags, tagOnlyRead: matching_lookup.tagOnlyRead})
        // fshow(LookupRspInfo{id: matching_lookup.id, rsp: tags, tagOnlyRead: matching_lookup.tagOnlyRead})
        fshow(LookupRspInfo{rsp: tags, tagOnlyRead: matching_lookup.tagOnlyRead})
      ));
    
      `ifdef TAGCONTROLLER_BENCHMARKING
      debug2("tracing", $display(
        "<time %0t Tracing> ", $time, fshow(tags.bench_id), " ",
        "return from tag lookup"
      ));
      `endif

      // RUNTYPE: out of order
      // lookupRsp.enq(matching_lookup.id, LookupRspInfo{rsp: tags, tagOnlyRead: matching_lookup.tagOnlyRead});
      lookupRsp.enq(LookupRspInfo{id: matching_lookup.id, rsp: tags, tagOnlyRead: matching_lookup.tagOnlyRead});
      // pendingLookups.remove(tags.request_id);

    // RUNTYPE: no lookup write responsese
    // end else begin
    //   debug2("tagcontroller", $display("<time %0t TagController> Ignored lookup response with id: ", $time, fshow(tags.request_id))); 
    // end
    // newTagResponse <= VnD{v: True, d: tags.request_id};
    pendingLookups.remove(tags.request_id);

  endrule

  // RUNTYPE: Buffer pending tag requests
  // TODO: ensure that tag reqeusts that had same memory request ID do not overtake one another
  //       MAY CAUSE BIG ISSUES IF NOT FIXED!! (AXI spec allows multiple reqs in flight with same ID)
  //       Unlikely that this will happen... but would be best if bug not present!
  rule putTagLookupRequest (tagLookup.cache.request.canPut() && pendingLookupRequests.notEmpty());
    let tagReq = pendingLookupRequests.first();
    pendingLookupRequests.deq();

    debug2("tagcontroller", $display("<time %0t TagController> Sending request to tagLookup: ", $time, " ", fshow(tagReq))); 

    `ifdef TAGCONTROLLER_BENCHMARKING
    debug2("tracing", $display(
      "<time %0t Tracing> ", $time, fshow(tagReq.bench_id), " ",
      "sent to tag lookup"
    )); 
    `endif      

    tagLookup.cache.request.put(tagReq);
  endrule

  // helper functions / signals
  /////////////////////////////////////////////////////////////////////////////
  // generate the next memory response
  // RUNTYPE: out of order
  
  // OLD version: 
  /*
  ReqId respID = ?;
  VnD#(LookupRspInfo) tagRsp = VnD{v: False, d: ?};
  CheriMemResponse newResp = mRsps.first;
  Bool tagsOnlyResponse = False;
  Bool untrackedResponse = False;
  function Bool isTagOnlyRead (LookupRspInfo x) = x.tagOnlyRead;
  let tagOnlyRsp = lookupRsp.searchFirsts(isTagOnlyRead);
  if (tagOnlyRsp.v && memoryResponseFrame==0) begin
    respID = tagOnlyRsp.d.key;
    tagsOnlyResponse = True;
    tagRsp.d = tagOnlyRsp.d.dat;
    tagRsp.v = True;
    newResp = CheriMemResponse{
        masterID: respID.masterID,
        transactionID: respID.transactionID,
        error: NoError,
        operation: tagged Read{last: True, tagOnlyRead: True},
        data: unpack(0)
    };
    case (tagOnlyRsp.d.dat.rsp.tags) matches
      tagged Covered .ts : newResp.data.data = zeroExtend(pack(ts));
      tagged Uncovered   : newResp.data.data = 0;
    endcase
  end
  if (!tagsOnlyResponse && mRsps.notEmpty) begin
    if (mRsps.first().operation matches tagged Read .rop) begin
      respID = getRespId(mRsps.first);
      tagRsp = lookupRsp.first(respID);
      Vector#(CapsPerFlit,Bool) tags = replicate(True);
      VnD#(AddrFrame) thisAddrFrame = addrFrame.first(respID);
      // look at the tag lookup response
      case (tagRsp.d.rsp.tags) matches
        tagged Covered .ts : begin
          CapOffsetInLine base = thisAddrFrame.d.bank + truncate(memoryResponseFrame >> valueOf(LogFlitsPerCap));
          for (Integer i = 0; i < valueOf(CapsPerFlit); i = i + 1)
            tags[i] = ts[base + fromInteger(i)];
        end
        tagged Uncovered   : tags = unpack(0);
      endcase
      // update the new response with appropriate tags
      newResp.data.cap = tags;
    end else untrackedResponse = True;
  end
  */

  // NEW Version
  // nextKey returns same value unless all items with key get removed
  LookupRspInfo firstLookupResp = lookupRsp.first;
  ReqId firstLookupRespID = firstLookupResp.id;

  // VnD#(ReqId) firstMemRespID = mRsps.nextKey;
  // CheriMemResponse firstMemResp = mRsps.first(firstMemRespID.d).d;
  
  ReqId respID = ?;
  VnD#(LookupRspInfo) tagRsp = VnD{v: False, d: ?};
  CheriMemResponse newResp = ?;

  Bool tagsOnlyResponse = False;
  Bool untrackedResponse = False;
  
  // If not in middle of memory response
  // and first lookup response is tag only then respond with that
  let tagOnlyRsp = firstLookupResp.tagOnlyRead == True;
  if (memoryResponseFrame==0 && lookupRsp.notEmpty && tagOnlyRsp) begin
    respID = firstLookupRespID;
    tagsOnlyResponse = True;
    tagRsp.d = firstLookupResp;
    tagRsp.v = True;
    newResp = CheriMemResponse{
        masterID: respID.masterID,
        transactionID: respID.transactionID,
        error: NoError,
        operation: tagged Read{last: True, tagOnlyRead: True},
        data: unpack(0)
    };
    case (firstLookupResp.rsp.tags) matches
      tagged Covered .ts : newResp.data.data = zeroExtend(pack(ts));
      tagged Uncovered   : newResp.data.data = 0;
    endcase
  end

  function Bool isWriteResp (CheriMemResponse x) = x.operation matches tagged Write ? True : False;
  let writeResp = mRsps.searchFirsts(isWriteResp);

  if (!tagsOnlyResponse) begin
    // If not found a write/SC response OR should not interrupt burst of read responses
    if (!writeResp.v || memoryResponseFrame > 0) begin
      // Return according to lookup responses
      respID = firstLookupRespID;
      let vndNewRsp = mRsps.first(respID);

      // Have both a lookup and mem resp for this ID
      if (vndNewRsp.v && lookupRsp.notEmpty) begin
        newResp = vndNewRsp.d;
        tagRsp.d = firstLookupResp;
        tagRsp.v = True;

        Vector#(CapsPerFlit,Bool) tags = replicate(True);
        VnD#(AddrFrame) thisAddrFrame = addrFrame.first(respID);
        // look at the tag lookup response
        case (tagRsp.d.rsp.tags) matches
          tagged Covered .ts : begin
            CapOffsetInLine base = thisAddrFrame.d.bank + truncate(memoryResponseFrame >> valueOf(LogFlitsPerCap));
            for (Integer i = 0; i < valueOf(CapsPerFlit); i = i + 1)
              tags[i] = ts[base + fromInteger(i)];
          end
          tagged Uncovered   : tags = unpack(0);
        endcase
        // update the new response with appropriate tags
        newResp.data.cap = tags;
      end
    // If a non-read memory response found AND not in middle of response burst
    end else if (writeResp.v) begin 
      newResp = writeResp.d.dat;
      untrackedResponse = True;
    end
  end

  Bool slvCanGet = tagRsp.v || untrackedResponse;

  // Calculate peek of memory request interface.
  // RUNTYPE: tag cache gets dram priority
  // CheriMemRequest memoryGetPeek = (mReqBurst.notEmpty) ? mReqs.first:tagLookup.memory.request.peek();
  CheriMemRequest memoryGetPeek = (!tagLookup.memory.request.canGet) ? mReqs.first:tagLookup.memory.request.peek();
  Bool memoryCanGet = mReqBurst.notEmpty || tagLookup.memory.request.canGet;

  // Comment in when debugging flow control.
  rule debug;
    // debug2("tagcontroller", $display("<time %0t TagController> slvCanPut:%x tagLookup.cache.request.canPut(1):%x tagLookup.memory.request.canGet(0):%x mReqs.notFull(1):%x",
    //                                  $time, slvCanPut, tagLookup.cache.request.canPut(), tagLookup.memory.request.canGet(), mReqs.notFull()));
    // // debug2("tagcontroller", $display("<time %0t TagController> slvCanGet:%x tagRsp.v(1):%x untrackedResponse(1):%x",
    // //                                  $time, slvCanGet, tagRsp.v, untrackedResponse));
    debug2("tagcontroller", $display("<time %0t TagController> DEBUG: ", $time, 
      // "memoryCanGet: ", fshow(memoryCanGet), " | ",
      // "memoryGetPeek: ", fshow(mReqs.first), " | ",
      // "taglookup cache request canput: ", fshow(tagLookup.cache.request.canPut()), " | ",
      // "taglookup cache response canget: ", fshow(tagLookup.cache.response.canGet()), " | ",
      // "pendingLookupRequests.first: ", fshow(pendingLookupRequests.first), " | ",
      "lookupRsp.remaining: ", fshow(lookupRsp.remaining), " | ",
      // "lookupRsp.first: ", fshow(lookupRsp.first), " | ",
      // "lookupRsp.notEmpty: ", fshow(lookupRsp.notEmpty), " | ",
      // "respID: ", fshow(respID), " | ",
      // "tagRsp: ", fshow(tagRsp), " | ",
      // "mRsps.full: ", fshow(mRsps.full), " | ",
      // "newResp: ", fshow(newResp), " | ",
      "pendingLookupRequests.remaining: ", fshow(pendingLookupRequests.remaining), " | ",
      ""
    ));
  endrule

  // module Slave interface
  /////////////////////////////////////////////////////////////////////////////

  interface Slave cache;
    // request side
    ///////////////////////////////////////////////////////
    interface CheckedPut request;
      method Bool canPut() = slvCanPut;
      method Action put(CheriMemRequest req) if (slvCanPut);
        ReqId id = getReqId(req);

        let lineAlignedAddr = pack(req.addr);
        Bit#(TLog#(CpuLineSize)) zero = 0;
        lineAlignedAddr = {truncateLSB(lineAlignedAddr),zero};
        CheriTagRequest tagReq = CheriTagRequest {
          `ifdef TAGCONTROLLER_BENCHMARKING
          bench_id: id.transactionID,
          `endif
          addr: unpack(lineAlignedAddr), 
          operation: tagged Read,
          request_id: currentRequestID
        };

        debug2("tagcontroller", $display("<time %0t TagController> New request: ", $time, fshow(req)));
        if (req.operation matches tagged Write .wop &&& req.addr >= unpack(fromInteger(table_start_addr)) && req.addr < unpack(fromInteger(table_end_addr))) begin
          req.operation = tagged Write {
              uncached: wop.uncached,
              conditional: wop.conditional,
              byteEnable: replicate(False),
              bitEnable: 0,
              data: wop.data,
              last: wop.last,
              length: wop.length
          };
          debug2("tagcontroller", $display("<time %0t TagController> Nullified request as it was for the tag table: ", $time, fshow(req)));
        end
        Bool tagOnlyRead = False;
        if (req.operation matches tagged Read .rop &&& rop.tagOnlyRead) begin
            tagOnlyRead = True;
        end
        // We only enqueue request to DRAM if this is not a tagOnlyRead
        Bool canDoEnq = !tagOnlyRead;
        if (canDoEnq) begin
            debug2("tagcontroller", $display("<time %0t TagController> Enqueuing request to mReqs: ", $time, fshow(req)));
            debug2("tagcontroller", $display("<time %0t TagController> mReqs remaining slots: ", $time, fshow(mReqs.remaining())));
            mReqs.enq(req);
            // Signal that the next burst in mReqs can be forwarded downstream.
            // FIXME: If we receive a read request in the middle of a write
            // burst this will erroneously forward the first part of the burst,
            // followed by the read, early, and risk a tag lookup write request
            // being interleaved with it. Currently TagControllerAXI will avoid
            // interleaving the two to work around this limitation.
            if (getLastField(req)) begin
              debug2("tagcontroller", $display("<time %0t TagController> This is the last in the burst, enqueueing ? to mReqBurst: ", $time));
              mReqBurst.enq(?);
            end
        end
        if (req.operation matches tagged Read .rop) begin
          // Stash the frame of the incoming address so that we can select the correct tags for the response.
          CheriCapAddress capAddr = unpack(pack(req.addr));
          AddrFrame thisAddrFrame = AddrFrame{tagOnlyRead: rop.tagOnlyRead, bank: truncate(capAddr.capNumber), masterID: req.masterID, transactionID: req.transactionID};
          debug2("tagcontroller", $display("<time %0t TagController> Stashing frame into addrFrame: ", $time, " ", fshow(id), ": ", fshow(thisAddrFrame)));
          addrFrame.enq(id, thisAddrFrame);
        end
        if (req.operation matches tagged Write .wop) begin
            CheriTagWrite newTagWrite = tagWrite;
            CheriCapAddress capAddr = unpack(pack(req.addr));
            Bit#(TLog#(SizeOf#(LineTags))) tagOffsetInLine = truncate(capAddr.capNumber);
            Integer i = 0;
            Integer bot = 0;
            for (i = 0; i < valueOf(CapsPerFlit); i = i + 1) begin
              CapOffsetInLine ibit = fromInteger(i);
              newTagWrite.tags[tagOffsetInLine + ibit] = wop.data.cap[i];
              Bit#(TMin#(CheriBusBytes, CapBytes)) capBEs = pack(wop.byteEnable)[bot+valueOf(TMin#(CheriBusBytes, CapBytes))-1:bot];
              newTagWrite.writeEnable[tagOffsetInLine + ibit] = (capBEs == 0) ? False:True;
              bot = bot + valueOf(CapBytes);
            end
            if (getLastField(req)) begin
              tagReq.operation = tagged Write newTagWrite;

              // RUNTYPE: Buffer pending tag requests
              // debug2("tagcontroller", $display("<time %0t TagController> Injecting Write Lookup: ", $time, fshow(tagReq)));
              // tagLookup.cache.request.put(tagReq);
              debug2("tagcontroller", $display("<time %0t TagController> Enqueuing Write lookup to pendingLookupRequests: ", $time, " ", fshow(tagReq)));    
              debug2("tagcontroller", $display("<time %0t TagController> Space left in pendingLookupRequests: ", $time, " ", fshow(pendingLookupRequests.remaining())));    
              pendingLookupRequests.enq(tagReq);

              // RUNTYPE: no lookup write responses
              // debug2("tagcontroller", $display("<time %0t TagController> Enqueueing lookup request info into pendingLookups: ", $time, " ", fshow(LookupReqInfo{id: id, tagOnlyRead: tagOnlyRead, useResponse: True})));    
              // newTagRequest <= VnD{v: True, d: LookupReqInfo{id: ?, tagOnlyRead: ?, useResponse: False}};
              currentRequestID <= currentRequestID + 1;

              newTagWrite = unpack(0);
            end
            tagWrite <= newTagWrite;
        end else begin
          // RUNTYPE: Buffer pending tag requests
          // debug2("tagcontroller", $display("<time %0t TagController> Sending read request to tagLookup: ", $time, " ", fshow(tagReq)));    
          // tagLookup.cache.request.put(tagReq);
          debug2("tagcontroller", $display("<time %0t TagController> Enqueuing read request to pendingLookupRequests: ", $time, " ", fshow(tagReq)));    
          debug2("tagcontroller", $display("<time %0t TagController> Space left in pendingLookupRequests: ", $time, " ", fshow(pendingLookupRequests.remaining())));    
          pendingLookupRequests.enq(tagReq);

          //RUNTYPE: no lookup write response
          // debug2("tagcontroller", $display("<time %0t TagController> Enqueueing lookup request info into pendingLookups: ", $time, " ", fshow(LookupReqInfo{id: id, tagOnlyRead: tagOnlyRead, useResponse: True})));    
          // newTagRequest <= VnD{v: True, d: LookupReqInfo{id: id, tagOnlyRead: tagOnlyRead, useResponse: True}};
          debug2("tagcontroller", $display("<time %0t TagController> Enqueueing lookup request info into pendingLookups: ", $time, " ", fshow(LookupReqInfo{id: id, tagOnlyRead: tagOnlyRead})));    
          pendingLookups.insert(currentRequestID, LookupReqInfo{id: id, tagOnlyRead: tagOnlyRead});
          currentRequestID <= currentRequestID + 1;
        end
      endmethod
    endinterface
    // response side
    ///////////////////////////////////////////////////////
    interface CheckedGet response;
      method Bool canGet() = slvCanGet;
      method CheriMemResponse peek() = newResp;
      method ActionValue#(CheriMemResponse) get() if (slvCanGet);
        // prepare memory response
        CheriMemResponse resp = newResp;
        ReqId id = getRespId(resp);
        // dequeue memory response fifo only when the response is not tagOnlyRead
        // RUNTYPE: out of order
        // if (!tagsOnlyResponse) mRsps.deq();
        if (!tagsOnlyResponse) mRsps.deq(id);
        // in case of read response ...
        if (resp.operation matches tagged Read .rop) begin
          // on the last flit,
          if (rop.last || rop.tagOnlyRead) begin
            // RUNTYPE: out of order
            // lookupRsp.deq(id); // dequeue the tag lookup response fifo
            lookupRsp.deq(); // dequeue the tag lookup response fifo
            addrFrame.deq(id);
            memoryResponseFrame <= 0;  // reset the current frame
          end else memoryResponseFrame <= memoryResponseFrame + 1; // for non last flits, increment frame
        end else memoryResponseFrame <= 0;
        debug2("tagcontroller", $display("<time %0t TagController> Returning response: ", $time, fshow(resp)));
        return resp;
      endmethod
    endinterface
  endinterface

  // module Master interface
  /////////////////////////////////////////////////////////////////////////////

  interface Master memory;
    interface CheckedGet request;
      method Bool canGet() = memoryCanGet;
      method CheriMemRequest peek() = memoryGetPeek;
      method ActionValue#(CheriMemRequest) get() if (memoryCanGet);
        // RUNTYPE: tag cache gets dram priority
        // if (mReqBurst.notEmpty) begin
        if (!tagLookup.memory.request.canGet) begin
          if (getLastField(mReqs.first)) mReqBurst.deq();
          mReqs.deq();
        end
        else let unused <- tagLookup.memory.request.get();
        debug2("tagcontroller", $display("<time %0t TagController> Sending request to memory (ForwardingMemoryRequest:%d): ", $time, mReqBurst.notEmpty, " ", fshow(memoryGetPeek)));
        return memoryGetPeek;
      endmethod
    endinterface
    interface CheckedPut response;
      method Bool canPut();
        // RUNTYPE: out of order
        // return (mRsps.notFull() && tagLookup.memory.response.canPut());
        return (!mRsps.full() && tagLookup.memory.response.canPut());
      endmethod
      method Action put(CheriMemResponse r);
        // >= instead of = because pipelined cache has multiple IDs!
        MemReqType reqType = (r.masterID >= mID) ? TagLookupReq : StdReq;
        debug2("tagcontroller", $display("<time %0t TagController> response from memory: ", $time, fshow(reqType), " ", fshow(r)));
        if (reqType == TagLookupReq) begin
          debug2("tagcontroller", $display("<time %0t TagController> tag response", $time));
          tagLookup.memory.response.put(r);
        end else begin
          debug2("tagcontroller", $display("<time %0t TagController> memory response", $time));
          // RUNTYPE: out of order
          // mRsps.enq(r);
          let id = getRespId(r);
          mRsps.enq(id,r);
        end
      endmethod
    endinterface
  endinterface

  // module cacheEvents interface
  /////////////////////////////////////////////////////////////////////////////

  `ifdef STATCOUNTERS
  interface Get cacheEvents;
    method ActionValue#(ModuleEvents) get () = tagLookup.cacheEvents.get();
  endinterface
  `elsif PERFORMANCE_MONITORING
  method events = tagLookup.events;
  `endif

  `ifdef TAGCONTROLLER_BENCHMARKING
  method isIdle = tagLookup.isIdle;
  `endif

endmodule
