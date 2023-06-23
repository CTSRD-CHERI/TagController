/*-
 * Copyright (c) 2016-2017 Alexandre Joannou
 * All rights reserved.
 *
 * This software was developed by SRI International and the University of
 * Cambridge Computer Laboratory under DARPA/AFRL contract FA8750-10-C-0237
 * ("CTSRD"), as part of the DARPA CRASH research programme.
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

import Assert::*;
import Vector::*;
import MemTypesCHERI::*;
import MasterSlaveCHERI::*;
import GetPut::*;
import FF::*;
import ConfigReg::*;
import CacheCore::*;
import DefaultValue::*;
import Printf::*;
import TagTableStructure::*;
`ifdef STATCOUNTERS
import StatCounters::*;
`endif
import Debug::*;

// interface types
///////////////////////////////////////////////////////////////////////////////

typedef Vector#(TDiv#(CpuLineSize, CapBytes),Bool) LineTags;
typedef struct {
  LineTags tags;
  LineTags writeEnable;
} CheriTagWrite deriving (Bits,Eq,FShow);

typedef struct {
  CheriPhyAddr addr;
  union tagged {
    void Read;
    CheriTagWrite Write;
  } operation;
  TagRequestID request_id;
`ifdef TAGCONTROLLER_BENCHMARKING
  Bit#(MemTypesCHERI::CheriTransactionIDWidth) bench_id;
`endif
} CheriTagRequest deriving (Bits,Eq,FShow);

typedef struct {
  LineTags tags;
  TagRequestID request_id;
  `ifdef TAGCONTROLLER_BENCHMARKING
  Bit#(MemTypesCHERI::CheriTransactionIDWidth) bench_id;
  `endif
} LookupResponse deriving (Bits,FShow);

typedef struct {
  union tagged {
    void Uncovered;
    LineTags Covered;
  } tags;
  TagRequestID request_id;
  `ifdef TAGCONTROLLER_BENCHMARKING
  Bit#(MemTypesCHERI::CheriTransactionIDWidth) bench_id;
  `endif
} CheriTagResponse deriving (Bits,Eq,FShow);

typedef struct {
  Bool covered;
  Bit#(TLog#(InFlight)) request_id;
} ReadReqInfo deriving (Bits,Eq, FShow);


interface TagLookupIfc;
  interface Slave#(CheriTagRequest, CheriTagResponse) cache;
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

// internal types
///////////////////////////////////////////////////////////////////////////////

typedef enum {Init, Idle, ReadTag, SetTag, ClearTag, FoldZeroes} State deriving (Bits, Eq, FShow);
typedef TMul#(CapsPerFlit,4) CapsPerLine;

typedef union tagged {
  Bool Node;
  LineTags Leaf;
} TableEntry deriving (Bits);

typedef struct {
  CheriPhyAddr startAddr;
  Integer size;
  Integer shiftAmnt;
  Integer groupFactor;
  Integer groupFactorLog;
} TableLvl deriving (FShow);

instance FShow#(Integer);
  function Fmt fshow (Integer i) = $format("%d",i);
endinstance

// XXX (maximum table depth of 4)
typedef UInt#(2) TDepth;

function Bool andBool (Bool x, Bool y) = (x && y);

// mkTagLookup module definition
///////////////////////////////////////////////////////////////////////////////

/*
  descending_urgency = "initialise,drainMemRsp,readTagState,setTagState"
*/
//XXX(* synthesize *) can't synthesize with polymorphic interface (=> parameter keyword useless...)


// RUNTYPE: Buffer pending tag requests
// Compiler thinks these comflict as both trigger doTransition
// BUT process_pending_tag_requests only triggered in cycles where they do not conflict
(* conflict_free = "doLookup, process_pending_tag_requests" *)
module mkMultiLevelTagLookup #(
  // master ID to be used for memory requests
  parameter CheriMasterID mID,
  // ending address of the tags table
  parameter CheriPhyAddr tagTabEndAddr,
  // from leaf 0 ---> root n. telem = Integer
  parameter Vector#(tdepth, Integer) tableStructure,
  parameter CheriPhyAddr tagTabStrtAddr,
  // Size of the memory covered
  parameter Integer memCoveredSize
) (TagLookupIfc);

  // static parameters
  /////////////////////////////////////////////////////////////////////////////

  // covered region include DRAM and BROM
  // starting address of the covered region
  CheriPhyAddr coveredStrtAddr = unpack(fromInteger(covered_start_addr));
  // ending address of the covered region
  CheriPhyAddr coveredEndAddr  = unpack(fromInteger(covered_start_addr + covered_mem_size));

  // root lvl
  TDepth rootLvl = fromInteger(valueof(tdepth)-1);
  TDepth leafLvl = 0;

  // table descriptor
  function TableLvl lvlDesc (Integer d);
    Integer sz;
    // leaf lvl
    sz = div(memCoveredSize,8*valueof(CapBytes));
    TableLvl tlvl = TableLvl {
          startAddr: unpack(pack(tagTabEndAddr)-fromInteger(sz)),
          size: sz,
          shiftAmnt: 0,
          groupFactor: 0,
          groupFactorLog: 0
      };
    // intermediate node lvl
    if (d > 0) begin
      TableLvl t = lvlDesc(d-1);
      if (tableStructure[d] > valueof(CheriDataWidth) || tableStructure[d] < 2)
        tlvl = error("grouping factor " + integerToString(tableStructure[d]) +
          " must be between 2 and CheriDataWidth ("+ integerToString(valueof(CheriDataWidth)) +
          ") (for clearing tags algorithm)");
      else if (mod(t.size,tableStructure[d]) != 0)
        tlvl = error("table level " + integerToString(d) +
          ", invalid grouping factor " + integerToString(tableStructure[d]) +
          " ("+integerToString(t.size) +
          " (bit size of the level) not divisible by "+integerToString(tableStructure[d])+")");
      else begin
        sz = div(t.size, tableStructure[d]);
        tlvl = TableLvl {
            startAddr: unpack(pack(t.startAddr)-fromInteger(sz)),
            size: sz,
            shiftAmnt: t.shiftAmnt + log2(tableStructure[d]),
            groupFactor: tableStructure[d],
            groupFactorLog: log2(tableStructure[d])
        };
      end
    end else
      if (d < 0) tlvl = error("MultiLevelTagLookup: negative table level " + integerToString(d));
    // force the table start address to be "flit" alligned
    // XXX necessary for the tag clear algorithm to work
    // XXX (it relies on all tags of a node being returned in a single mem rsp)
    tlvl.startAddr.byteOffset = 0;
    return tlvl;
  endfunction
  //endfunction
  // table descriptor has leaf lvl 0 ---> root lvl n
  Vector#(tdepth,TableLvl) tableDesc = genWith (lvlDesc);

  staticAssert(tagTabStrtAddr == tableDesc[valueof(tdepth)-1].startAddr,
    sprintf("Python-calculated table base 0x%0x != bluespec-calculated table base 0x%0x",
      pack(tagTabStrtAddr), pack(tableDesc[valueof(tdepth)-1].startAddr)));

  // components instanciations
  /////////////////////////////////////////////////////////////////////////////

  // state register
  Reg#(State) state <- mkConfigReg(Init);
  // address to zero when in Init state
  Reg#(CheriPhyAddr) zeroAddr <- mkReg(tagTabStrtAddr);
  // transaction number for memory requests

  //RUNTYPE: Buffer pending tag requests
  // Reg#(CheriTransactionID) transNum <- mkReg(0);
  Reg#(CheriTransactionID) transNum <- mkConfigReg(0);

  //RUNTYPE: Buffer pending tag requests
  PulseWire aboutToIdle <- mkPulseWire();
  FF#(CheriTagRequest, 1) pendingTagReqs <- mkFFBypass();

  // RUNTYPE: Buffer pending tag requests
  // Note: lookupRsp now a LookupResponse fifo for benchmark tracing
  //
  // ## Original: Only size 1
  //
  // pending read requests fifo covered or not
  // FF#(Bool,1) readReqs <- mkLFF1();
  // lookup response fifo
  // FF#(LineTags,1) lookupRsp      <- mkUGFFDebug("TagLookup_lookupRsp");
  // // Compatible version
  // // FF#(LookupResponse,1) lookupRsp <- mkUGFFDebug("TagLookup_lookupRsp");
  //
  // ## BUT size of 1 blocks new requests from being enqueued until tag controller 
  // ## calls cache.response.get() so make these larger (size InFlight)
  //
  // pending read requests fifo covered or not
  // FF#(Bool,2) readReqs <- mkLFF();
  FF#(ReadReqInfo,2) readReqs <- mkLFF();
  // lookup response fifo
  FF#(LookupResponse,2) lookupRsp      <- mkUGFFDebug("TagLookup_lookupRsp");

  // memory requests fifo
  FF#(CheriMemRequest, 8)  mReqs <-  mkUGFFDebug("TagLookup_mReqs");
  // memory response fifo
  FF#(CheriMemResponse, 2) mRsps <- mkUGFFDebug("TagLookup_mRsps");
  // Ensure only one outstanding request at a time.
  // As we enq and deq in the same rule, more than one would wedge the state machine.
  //FF#(CheriMemResponse, 2) tagCacheRsps <- mkUGFF();
  FF#(Bool, 4)             useNextRsp <- mkUGFFDebug("TagLookup_useNextRsp");

  // RUNTYPE: bypass tagcachereq
  // Original version
  // FF#(CheriMemRequest, 1) tagCacheReq <- mkFF();
  // Make bypass (allow feedtagcache in same cycle as doTransition enqs to it)
  FF#(CheriMemRequest, 1) tagCacheReq <- mkFFBypass();
  
  
  PulseWire                    getReq <- mkPulseWire();

  // tag cache CacheCore module
  // NOTE: cache id must be same as mID - as this is used for writeback requests
  //       currently just set by hand
  WriteMissBehaviour writeBehaviour = WriteAllocate;
  CacheCore#(4, TSub#(Indices,2), 1)  tagCache <- mkCacheCore(
    1, writeBehaviour, RespondAll, TCache,
    zeroExtend(mReqs.remaining()), ff2fifof(mReqs), ff2fifof(mRsps));

  // current lookup's depth
  // RUNTYPE: Buffer pending tag requests
  //
  // Normal registers
  // Reg#(TDepth)    currentDepth     <- mkReg(unpack(0));
  // Reg#(CapNumber) pendingCapNumber <- mkReg(unpack(0));
  // Reg#(LineTags) pendingTags <- mkReg(unpack(0));
  // Reg#(LineTags) pendingCapEnable <- mkReg(unpack(0));
  //
  // Control registers
  Reg#(TDepth)    currentDepth     <- mkConfigReg(unpack(0));
  Reg#(CapNumber) pendingCapNumber <- mkConfigReg(unpack(0));
  Reg#(LineTags) pendingTags <- mkConfigReg(unpack(0));
  Reg#(LineTags) pendingCapEnable <- mkConfigReg(unpack(0));

  Reg#(TagRequestID) pendingRequestID <- mkConfigReg(?);
  `ifdef TAGCONTROLLER_BENCHMARKING
  Reg#(Bit#(CheriTransactionIDWidth)) pendingBenchID <- mkConfigReg(?);
  `endif

  Vector#(tdepth,Reg#(Bit#(CheriDataWidth))) oldTags <- replicateM(mkReg(unpack(0)));

  // module helper functions
  /////////////////////////////////////////////////////////////////////////////

  function Bool isCovered (CheriPhyAddr addr);
    Bool r = True;
    if (addr < coveredStrtAddr || addr >= coveredEndAddr) r = False;
    if (addr >= tagTabStrtAddr && addr < tagTabEndAddr) r = False;
    return r;
  endfunction

  function CheriPhyBitAddr getTableAddr(TDepth cd, CapNumber cn);
    TableLvl t = tableDesc[cd];
    CheriPhyBitAddr bitAddr = unpack(zeroExtend(cn >> t.shiftAmnt));
    bitAddr.byteAddr = unpack(pack(bitAddr.byteAddr) + pack(t.startAddr));
    return bitAddr;
  endfunction

  function TableEntry getTableEntry(TDepth cd, CapNumber cn, Bit#(CheriDataWidth) tags);
    CheriPhyBitAddr a = getTableAddr(cd,cn);
    CheriPhyBitOffset bitOffset = truncate(pack(a));
    if (cd == leafLvl) begin
      // if leaf lvl, return a LineTags
      Vector#(TDiv#(CheriDataWidth,SizeOf#(LineTags)),LineTags) lines = unpack(tags);
      CheriPhyBitOffset idx = bitOffset >> valueof(TLog#(SizeOf#(LineTags)));
      return tagged Leaf unpack(pack(lines[idx]));
    end else begin
      // if node lvl, return a single tag
      return tagged Node unpack(tags[bitOffset]);
    end
  endfunction

  function Bit#(CheriDataWidth) getOldTagsEntry (
      CapNumber cn,
      Bit#(CheriDataWidth) tags,
      TDepth cd);
    TableLvl t = (cd==rootLvl) ? tableDesc[leafLvl]:tableDesc[cd+1];
    CheriPhyBitAddr a = getTableAddr(cd,cn);
    CheriPhyBitOffset shft = truncate(pack(a));
    CheriPhyBitOffset shftMask = ~0<<t.groupFactorLog;
    Bit#(CheriDataWidth) tagsMask = ~(~0<<t.groupFactor);
    return ((tags>>(shft&shftMask))&tagsMask);
  endfunction

  function Bit#(CheriDataWidth) getNewTagsEntry (
      TDepth cd,
      CapNumber cn,
      Vector#(howmanybits,Bool) ts,
      Vector#(howmanybits,Bool) ce,
      Bit#(CheriDataWidth) old);
    TableLvl t = tableDesc[cd+1]; // XXX TODO add dynamic assertion on level XXX
    CheriPhyBitAddr a = getTableAddr(cd,cn);
    CheriPhyBitOffset shft = truncate(pack(a));
    CheriPhyBitOffset shftMask = ~(~0<<t.groupFactorLog);
    CheriPhyBitOffset bitOffset = shft&shftMask;
    Bit#(CheriDataWidth) newTags = old;
    Integer i = 0;
    for (i = 0; i < valueOf(howmanybits); i = i + 1) begin
      if (ce[i]) newTags[bitOffset+fromInteger(i)] = pack(ts[i]);
    end
    return newTags;
  endfunction

  function CheriMemRequest craftTagReadReq (TDepth d, CapNumber cn);
    CheriPhyAddr a = getTableAddr(d,cn).byteAddr;
    CheriMemRequest mReq = defaultValue;
    mReq.addr            = a;
    mReq.masterID        = mID;
    mReq.transactionID   = transNum;
    mReq.operation       = tagged Read {
                              tagOnlyRead: False, // Fix when we support CLoadTags!
                              uncached: False,
                              linked: False,
                              noOfFlits: 0,
                              bytesPerFlit: cheriBusBytes
                            };
    return mReq;
  endfunction

  function CheriMemRequest craftTagWriteReq (
    TDepth d, // depth in the table
    CapNumber cn, // capability number targetted
    Vector#(howmanybits,Bool) ts, // tags
    Vector#(howmanybits,Bool) ce, // "cap enable"
    Maybe#(TableLvl) nz); // need zeroing
    // prepare address
    CheriPhyBitAddr a = getTableAddr(d,cn);
    CheriPhyByteOffset byteOffset = a.byteAddr.byteOffset;
    Bit#(3) bitOffset = a.bitOffset;

    Bool z = False; // no zeroing detected yet...

    // prepare byte enable
    Vector#(CheriBusBytes, Bool) wbyteE = replicate(False);
    if (nz matches tagged Valid .t) begin
      z = True; // we need zeroing
      Integer i = 0;
      CheriPhyByteOffset nodeOffset = byteOffset&(~0 << (t.groupFactorLog - 3));
      for (i = 0; i < (div(t.groupFactor,8)); i = i + 1) begin
        wbyteE[nodeOffset+fromInteger(i)] = True;
      end
    end
    wbyteE[byteOffset] = True;
    // prepare bit enable and new data
    Bit#(8) wbitE   = z ? ~0 : 0;
    Bit#(8) newData = 0;
    Vector#(howmanybits,Bool) leafData = zipWith(andBool,ts,ce);
    if (d == leafLvl) begin
      Integer i = 0;
      for (i = 0; i < valueOf(howmanybits); i = i + 1) begin
        wbitE[bitOffset+fromInteger(i)] = z ? 1 : pack(ce[i]);
        newData[bitOffset+fromInteger(i)] = pack(leafData[i]);
      end
    end else begin
      wbitE[bitOffset] = 1;
      newData[bitOffset] = pack(any(id,leafData));
    end

    CheriMemRequest mReq = defaultValue;
    mReq.addr            = a.byteAddr;
    mReq.masterID        = mID;
    mReq.transactionID   = transNum;
    CheriData wdata = Data {
                cap: unpack(0),
                data: zeroExtend(newData) << {byteOffset,3'b0}
              };
    mReq.operation = tagged Write {
                          uncached: False,
                          conditional: False,
                          byteEnable: wbyteE,
                          bitEnable: wbitE,
                          data: wdata,
                          last: True,
                          length: 0
                        };
    return mReq;
  endfunction

  function Action doTransition (
    Maybe#(CheriMemRequest) mmr,
    TDepth newDepth,
    State newState,
    Bool useRsp
    ) = action
    // debug2("taglookup",
    //   $display("<time %0t TagLookup> table structure -", $time, fshow(tableDesc)
    // ));
    case (mmr) matches
      tagged Valid .mr: begin
        // send the tag cache request and increment the transaction number
        debug2("taglookup",
          $display("<time %0t TagLookup> sending lookup: ",
          $time, fshow(mr)
        ));
        tagCacheReq.enq(mr);
        useNextRsp.enq(useRsp);
        transNum <= transNum + 1;
      end
    endcase
    // update lookup depth
    currentDepth <= newDepth;
    // do state transistion
    state <= newState;

    // RUNTYPE: Buffer pending tag requests:
    // I moved this to where doLookup called (so can call dolookup twice in same clock cycle)
    // debug2("taglookup",
    //   $display("<time %0t TagLookup> pendingCapNumber %x, currentDepth %d -> %d, state ",
    //   $time, pendingCapNumber, currentDepth, newDepth, fshow(state), " -> ", fshow(newState)
    // ));
  endaction;

  rule feedTagCache (tagCache.canPut);
    debug2("taglookup",
      $display("<time %0t TagLookup> Sending request to cache:  ",
      $time, fshow(tagCacheReq.first())
    ));
    tagCache.put(tagCacheReq.first());
    tagCacheReq.deq();
  endrule

  // module rules
  /////////////////////////////////////////////////////////////////////////////

  // initialisation rule
  /////////////////////////////////////////////////////////////////////////////

`ifdef BLUESIM
  `define NO_TAGTABLE_ZEROING
`endif 
`ifdef RVFI_DII
`define NO_TAGTABLE_ZEROING
`endif
`ifndef NO_TAGTABLE_ZEROING
  rule initialise (state == Init); 
    TableLvl t = tableDesc[rootLvl];
    // zero toplevel of tag table in memory
    `ifdef TAGCONTROLLER_BENCHMARKING      
    if (writeBehaviour == WriteThrough) begin
    `endif
      if (zeroAddr < unpack(pack(t.startAddr) + fromInteger(t.size))) begin
        // prepare memory request
        CheriMemRequest mReq = defaultValue;
        mReq.addr            = zeroAddr;
        mReq.masterID        = mID;
        mReq.transactionID   = transNum;
        mReq.operation       = tagged Write {
                                        uncached: False,
                                        conditional: False,
                                        byteEnable: unpack(-1),
                                        bitEnable: -1,
                                        data: unpack(0),
                                        length: 0,
                                        last: True
                                      };
        // send memory request
        tagCacheReq.enq(mReq);
        useNextRsp.enq(False);
        debug2("taglookup",
          $display(
          "<time %0t TagLookup> zeroing tag table toplevel: ",
          $time, fshow(mReq)
        ));
        // increment transaction number and address
        transNum <= transNum + 1;
        zeroAddr.lineNumber <= zeroAddr.lineNumber + 1;
      end
`ifdef TAGCONTROLLER_BENCHMARKING
      else if (!useNextRsp.notEmpty) begin
        //Wait for all outstaning responses to be processed
        debug2("taglookup",
          $display(
          "<time %0t TagLookup> Finished zeroing tag cache. Init->Idle",
          $time
        ));
        state <= Idle;
      end
    end else begin // don't zero if writeThroughOnly=False
      state <= Idle;
    end
`endif 
  endrule
`else // NO_TAGTABLE_ZEROING
  rule initialise (state == Init);
      // If not zeroing, go straight to Serving state
      state <= Idle;
  endrule
`endif

  // Simply stuff "True" into commits because we never cancel transactions here
  /////////////////////////////////////////////////////////////////////////////
  rule stuffCommits;
    tagCache.nextWillCommit(True);
  endrule

  // drain unused tag response when in Idle state (useful for unused write responses)
  rule drainMemRsp (tagCache.response.canGet() && (getReq || !useNextRsp.first()));
    let resp <- tagCache.response.get();
    useNextRsp.deq();
    debug2("taglookup",
      $display(
        "<time %0t TagLookup> Dequed tag response, getReq: %x, useNextRsp: %x, ",
        $time, getReq, useNextRsp.first(),
        "state: ", fshow(state), " | ",
        "response: ", fshow(resp)
    ));
  endrule

  rule debug;
    // debug2("taglookup",
    //   $display(
    //   "<time %0t TagLookup> DEBUG ", $time, 
    //   "state: ", fshow(state), " | ",
    //   "useNextRsp.notFull:", fshow(useNextRsp.notFull), " | ",
    //   "tagCacheReq.remaining: ", fshow(tagCacheReq.remaining), " | ",
    //   ""
    // ));
  endrule

  // Main lookup rule
  /////////////////////////////////////////////////////////////////////////////
  // As this calls doTransition, it requires that tagCacheReq is not full!
  // Fixable by simply making tagCacheReq >= 2
  
  rule doLookup (state != Idle && state != Init && useNextRsp.notFull);
    // Common signals
    ///////////////////////////////////////////////////////////////////////////
    // current memory response
    //CheriMemResponse memRsp = tagCacheRsps.first();
    Bool memRspReady = False;
    if (tagCache.response.canGet())
      memRspReady = useNextRsp.first;
    CheriMemResponse memRsp = tagCache.response.peek();
    //CheriMemResponse memRsp <- tagCache.response.get();
    debug2("taglookup",
      $display(
      "<time %0t TagLookup> memRsp valid: %x, current memRsp ",
      $time, tagCache.response.canGet(), fshow(memRsp)
    ));
    // current tag table entry
    Bit#(CheriDataWidth) rspData = memRsp.data.data;
    TableEntry tagTableEntry = getTableEntry(currentDepth, pendingCapNumber, rspData);
    // state transition signals (with default values)
    Maybe#(CheriMemRequest) newCacheReq = tagged Invalid;
    TDepth newDepth                     = currentDepth - 1;
    State newState                      = state;
    Bool  useRsp                        = False;
    Bool  doATransition                 = False;
    // define a zingle zero or a single one
    Vector#(1,Bool) zero = replicate (False);
    Vector#(1,Bool) one  = replicate (True);

    debug2("taglookup", $display("<time %0t TagLookup> Received a response.", $time,
      " valid: ", fshow(tagCache.response.canGet()),
      " | state: ", fshow(state),
      " | memRspReady: ", fshow(memRspReady),
      " | lookupsRsp.notFull: ", fshow(lookupRsp.notFull),
      ""
    ));
    
    case (state) matches
      // ReadTag state
      /////////////////////////////////////////////////////////////////////////
      ReadTag &&& (memRspReady && lookupRsp.notFull()): begin
        // check transition behaviour
        case (tagTableEntry) matches
          tagged Node .t: begin
            if (!t) begin
              // early 0
              debug2("taglookup",
                $display(
                "<time %0t TagLookup> ReadTag 0 early response (currentDepth %d)",
                $time, currentDepth
              ));

              `ifdef TAGCONTROLLER_BENCHMARKING
              debug2("tracing", $display(
                "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
                "end ROOT | read | NO LEAF"
              )); 
              `endif
              // enqueue a 0 response
              lookupRsp.enq(
                LookupResponse{
                  `ifdef TAGCONTROLLER_BENCHMARKING
                  bench_id: pendingBenchID,
                  `endif
                  tags: unpack(0),
                  request_id: pendingRequestID
                }
              );
              // prepare jump back to Idle state
              newState = Idle;
            end else begin
              // tag 1, need new lookup ("recursive state")
              debug2("taglookup",
                $display(
                "<time %0t TagLookup> ReadTag 1 (currentDepth %d)",
                $time, currentDepth
              ));
              `ifdef TAGCONTROLLER_BENCHMARKING
              debug2("tracing", $display(
                "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
                "end ROOT | read"
              )); 
              debug2("tracing", $display(
                "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
                "start LEAF | read"
              )); 
              `endif
              // request next table entry
              newCacheReq = tagged Valid craftTagReadReq(newDepth,pendingCapNumber);
              useRsp = True;
            end
          end
          tagged Leaf .ts: begin
            // Reached a Leaf of the table, return lookup
            debug2("taglookup",
              $display(
              "<time %0t TagLookup> ReadTag leaf node reached (currentDepth %d) : %b",
              $time, currentDepth, ts
            ));

            `ifdef TAGCONTROLLER_BENCHMARKING
            debug2("tracing", $display(
              "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
              "end LEAF | read"
            )); 
            `endif

            // enqueue the lookup response
            lookupRsp.enq(
              LookupResponse{  
                `ifdef TAGCONTROLLER_BENCHMARKING
                bench_id: pendingBenchID,
                `endif
                tags: ts,
                request_id: pendingRequestID
              }
            );
            // prepare jump back to Idle state
            newState = Idle;
          end
        endcase
        getReq.send();
        doATransition = True;
      end
      // SetTag state
      /////////////////////////////////////////////////////////////////////////
      SetTag &&& memRspReady: begin
        // detect 0 -> 1 transition
        CheriPhyBitAddr a = getTableAddr(currentDepth,pendingCapNumber);
        Maybe#(TableLvl) needZeros = (!unpack(rspData[{a.byteAddr.byteOffset,a.bitOffset}])) ?
            tagged Valid tableDesc[currentDepth] : tagged Invalid;
        if (needZeros matches tagged Valid .t) debug2("taglookup",
          $display(
          "<time %0t TagLookup> SetTag 0 -> 1 transition detected at depth %d",
          $time, currentDepth
        ));
        // transition behaviour
        case (tagTableEntry) matches
          tagged Node .t: begin
            if (currentDepth == leafLvl+1) begin
              newCacheReq = tagged Valid craftTagWriteReq(leafLvl,pendingCapNumber,pendingTags,pendingCapEnable,needZeros);
              newState = Idle;

              `ifdef TAGCONTROLLER_BENCHMARKING
              if (needZeros matches tagged Valid .t) begin
                debug2("tracing", $display(
                  "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
                  "end ROOT | write | ZERO LEAVES"
                )); 
                debug2("tracing", $display(
                  "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
                  "start LEAF | write | IGNORED"
                )); 
              end else begin 
                debug2("tracing", $display(
                  "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
                  "end ROOT | write"
                )); 
                debug2("tracing", $display(
                  "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
                  "start LEAF | write | IGNORED"
                )); 
              end
              `endif
            end else begin
              newCacheReq = tagged Valid craftTagWriteReq(newDepth,pendingCapNumber,one,one,needZeros);
              useRsp = True;
            end
          end
          tagged Leaf .ts: begin
            newState = Idle;

            `ifdef TAGCONTROLLER_BENCHMARKING
            debug2("tracing", $display(
              "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
              "end LEAF | write"
            )); 
            `endif
          end
        endcase
        getReq.send();
        doATransition = True;
      end

      // ClearTag state
      /////////////////////////////////////////////////////////////////////////////
      ClearTag &&& memRspReady: begin
        // get all the tags for the current entry
        Vector#(tdepth,Bit#(CheriDataWidth)) currentTags =
          genWith(compose(getOldTagsEntry(pendingCapNumber,rspData),fromInteger));
        // transition behaviour
        case (tagTableEntry) matches
          // On a non leaf node with a zero, finish early
          tagged Node .t &&& (t == False): begin
            debug2("taglookup",
              $display(
                "<time %0t TagLookup> early 0 clearing tag",
                $time
            ));

            `ifdef TAGCONTROLLER_BENCHMARKING
            debug2("tracing", $display(
              "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
              "end ROOT | read | NO LEAF"
            )); 
            `endif
            newState = Idle;
          end
          // On a non leaf node with a one, recurse further
          tagged Node .t &&& (t == True): begin
            debug2("taglookup",
              $display(
                "<time %0t TagLookup> found 1 when clearing tag, keep going down...",
                $time
            ));

            `ifdef TAGCONTROLLER_BENCHMARKING
            debug2("tracing", $display(
              "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
              "end ROOT | read"
            )); 
            debug2("tracing", $display(
              "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
              "start LEAF | read"
            )); 
            `endif

            // update the already looked up tags
            oldTags[currentDepth] <= currentTags[currentDepth];
            // send next lookup
            newCacheReq = tagged Valid craftTagReadReq(newDepth,pendingCapNumber);
            useRsp = True;
          end
          // On a leaf node...
          tagged Leaf .ts: begin
            // unconditionally write a zero at the current level
            newCacheReq = tagged Valid craftTagWriteReq(leafLvl,pendingCapNumber,pendingTags,pendingCapEnable,tagged Invalid);
          
            // if not a flat table...
            if (leafLvl != rootLvl) begin
              // If our old tags were zero and the new ones were writing are zero, fold zeroes up.
              // note that this neglects to consider that currentTags is being
              // overwritten by potential zeroes, but helps timing

              // REQUIRES was zero before the write!
              if (pack(currentTags[leafLvl])==0 && pack(pendingTags)==0) begin
                newDepth = leafLvl + 1;
                newState = FoldZeroes;

                `ifdef TAGCONTROLLER_BENCHMARKING
                debug2("tracing", $display(
                  "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
                  "end LEAF | read | FOLDING"
                )); 
                debug2("tracing", $display(
                  "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
                  "start LEAF | write | IGNORED"
                )); 
                `endif
              end else begin
                newState = Idle;

                `ifdef TAGCONTROLLER_BENCHMARKING
                debug2("tracing", $display(
                  "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
                  "end LEAF | read | NO FOLD"
                )); 
                `endif
              end
            end
            // otherwise jump back to Idle State
            else newState = Idle;
          end
        endcase
        getReq.send();
        doATransition = True;
      end
      // FoldZeroes state
      /////////////////////////////////////////////////////////////////////////////
      FoldZeroes: begin
        // unconditionally fold a zero at the current level
        newCacheReq = tagged Valid craftTagWriteReq(currentDepth,pendingCapNumber,zero,one,tagged Invalid);


        `ifdef TAGCONTROLLER_BENCHMARKING
        debug2("tracing", $display(
          "<time %0t Tracing> ", $time, fshow(pendingBenchID), " ",
          "start ROOT | write | FOLDING | IGNORED" // Note useRSp = False
        )); 
        `endif

        // check on previous level (if we were not already at the root level)
        // note that this neglects to consider that currentTags is being
        // overwritten by potential zeroes, but helps timing

        // REQUIRES was zero before the write!
        if (pack(oldTags[currentDepth]) == 0 && currentDepth < rootLvl) begin
          newDepth = currentDepth + 1;
          newState = FoldZeroes;
        end
        // otherwise jump back to Idle State
        else newState = Idle;
        doATransition = True;
      end
      default: begin
        // Handle the case where there is a pending response that the state machine doesn't want.
        if (tagCache.response.canGet() && !useNextRsp.first()) getReq.send();
      end
    endcase
    // do the transition
    if (doATransition) begin
      doTransition(newCacheReq, newDepth, newState, useRsp);
      debug2("taglookup",
        $display("<time %0t TagLookup> Transitioning: pendingCapNumber %x, currentDepth %d -> %d, state ",
        $time, pendingCapNumber, currentDepth, newDepth, fshow(state), " -> ", fshow(newState)
      ));
      // RUNTYPE: Buffer pending tag requests
      case (newCacheReq) matches
        // No new request sent to the cache
        // Therefore can send a pending request after this rule ends
        tagged Invalid: begin
          if (newState==Idle) begin
            aboutToIdle.send();
            debug2("taglookup", $display("<time %0t TagLookup> Sent a pulse down aboutToIdle", $time ));
          end
        end
      endcase
    end
  endrule 

  /*
  (* conflict_free = "doLookup, process_pending_tag_requests, could_process" *)
  rule could_process (aboutToIdle || state==Idle);
    debug2("taglookup", $display("<time %0t TagLookup> Could process a request.", $time,
      " aboutToIdle: ", fshow(aboutToIdle),
      " | state: ", fshow(state),
      " | pendingTagReqs.notEmpty: ", fshow(pendingTagReqs.notEmpty),
      " | tagCacheReq.notFull: ", fshow(tagCacheReq.notFull),
      " | readReqs.notFull: ", fshow(readReqs.notFull),
      ""
    ));
  endrule
  */


  function Action handle_new_request (CheriTagRequest req);
    return (
      action
        // next state to go to
        State nextState  = Idle;
        // check whether we are in the covered region
        Bool doTagLookup = isCovered(req.addr);
        // initialise future pending tags
        LineTags newPendingTags = unpack(0);
        LineTags newPendingCapEnable = unpack(0);
        // initialise a toplevel table lookup
        CheriCapAddress capAddr = unpack(pack(req.addr) - pack(coveredStrtAddr));
        CheriMemRequest mReq = craftTagReadReq (rootLvl,capAddr.capNumber);
        case (req.operation) matches
          // when it's a read
          //////////////////////////////
          tagged Read: begin
            readReqs.enq(
              ReadReqInfo{
                covered: doTagLookup,
                request_id: req.request_id
              }
            );
            nextState = ReadTag;

            `ifdef TAGCONTROLLER_BENCHMARKING
            debug2("tracing", $display(
              "<time %0t Tracing> ", $time, fshow(req.bench_id), " ",
              "start ROOT | read"
            )); 
            `endif
          end
          // when it's a write
          //////////////////////////////
          tagged Write .wop: begin
            // get cap tags
            LineTags capTags = wop.tags;
            LineTags capEnable = wop.writeEnable;
            // and cap tags with cap enable
            LineTags andTags = zipWith(andBool,capTags,capEnable);
            // update new pending tags
            newPendingTags = capTags;
            newPendingCapEnable = capEnable;
            //check wether to write anything or not
            function Bool isTrue  (Bool x) = x == True;
            function Bool isFalse (Bool x) = x == False;
            if (all(isFalse,capEnable)) begin
              nextState = Idle;
              doTagLookup = False;
            end else if (all(isFalse,andTags)) begin
              // when all tags to write are 0
              nextState = ClearTag;

              `ifdef TAGCONTROLLER_BENCHMARKING
              debug2("tracing", $display(
                "<time %0t Tracing> ", $time, fshow(req.bench_id), " ",
                "start ROOT | read | CLEARING"
              )); 
              `endif
            end else begin
              // when writing at least a 1
              mReq = craftTagWriteReq(rootLvl,capAddr.capNumber,capTags,capEnable,tagged Invalid);
              nextState = SetTag;

              `ifdef TAGCONTROLLER_BENCHMARKING
              debug2("tracing", $display(
                "<time %0t Tracing> ", $time, fshow(req.bench_id), " ",
                "start ROOT | write"
              )); 
              `endif
            end


          end
          // ignore other types of requests
          default: begin
            doTagLookup = False;
            nextState = Idle;
          end
        endcase
        // when a lookup is required
        if (doTagLookup) begin
          pendingCapNumber <= capAddr.capNumber;
          pendingTags      <= newPendingTags;
          pendingCapEnable <= newPendingCapEnable;
          pendingRequestID <= req.request_id;
          `ifdef TAGCONTROLLER_BENCHMARKING
          pendingBenchID <= req.bench_id;
          `endif

          debug2("taglookup",
            $display(
              "<time %0t TagLookup> Starting lookup with capNum = ",
              $time, fshow(capAddr.capNumber),
              " ( pending tags = ", fshow(newPendingTags),
              ", pending cap enable = ",fshow(newPendingCapEnable)," )"
          ));

          doTransition(tagged Valid mReq,rootLvl,nextState,True);
          debug2("taglookup",
            $display("<time %0t TagLookup> Transitioning: pendingCapNumber %x, currentDepth %d -> %d, state ",
            $time, capAddr.capNumber, currentDepth, rootLvl, fshow(Idle), " -> ", fshow(nextState)
          ));

        end else debug2("taglookup",
          $display(
            "<time %0t TagLookup> memory not covered",
            $time
        ));
      endaction
    );
  endfunction

  // State==Idle if started current clock cycle with State==Idle
  // aboutToIdle has pulse if doLookup transitioned to Idle
  rule process_pending_tag_requests ((aboutToIdle || state==Idle) && pendingTagReqs.notEmpty && tagCacheReq.notFull);
    let req = pendingTagReqs.first();
    pendingTagReqs.deq();
 
    debug2("taglookup",
      $display(
        "<time %0t TagLookup> Processing pending tag lookup request: ",
        $time, fshow(req)
    ));

    handle_new_request(req)();
  endrule

  // module Slave interface
  /////////////////////////////////////////////////////////////////////////////

  interface Slave cache;

    // lookup Slave request interface
    //////////////////////////////////////////////////////
    interface CheckedPut request;
      // RUNTYPE: Buffer pending tag requests
      // method Bool canPut() = (state == Idle) && tagCacheReq.notFull;
      method Bool canPut() = pendingTagReqs.notFull;
      // tag request
      //////////////////////////////
      // RUNTYPE: Buffer pending tag requests
      //
      // OLD VERSION
      // NOTE: To remove buffering ONLY can just call handle_new_request():
      //
      // method Action put(CheriTagRequest req) if (state == Idle);
      //   debug2("taglookup",
      //   $display(
      //       "<time %0t TagLookup> received request ",
      //       $time, fshow(req)
      //   ));
      //   handle_new_request(req)();
      // endmethod
      /*
      method Action put(CheriTagRequest req) if (state == Idle);
        debug2("taglookup",
          $display(
            "<time %0t TagLookup> received request ",
            $time, fshow(req)
        ));
        // next state to go to
        State nextState  = Idle;
        // check whether we are in the covered region
        Bool doTagLookup = isCovered(req.addr);
        // initialise future pending tags
        LineTags newPendingTags = unpack(0);
        LineTags newPendingCapEnable = unpack(0);
        // initialise a toplevel table lookup
        CheriCapAddress capAddr = unpack(pack(req.addr) - pack(coveredStrtAddr));
        CheriMemRequest mReq = craftTagReadReq (rootLvl,capAddr.capNumber);
        case (req.operation) matches
          // when it's a read
          //////////////////////////////
          tagged Read: begin
            readReqs.enq(doTagLookup);
            nextState = ReadTag;
          end
          // when it's a write
          //////////////////////////////
          tagged Write .wop: begin
            // get cap tags
            LineTags capTags = wop.tags;
            LineTags capEnable = wop.writeEnable;
            // and cap tags with cap enable
            LineTags andTags = zipWith(andBool,capTags,capEnable);
            // update new pending tags
            newPendingTags = capTags;
            newPendingCapEnable = capEnable;
            //check wether to write anything or not
            function Bool isTrue  (Bool x) = x == True;
            function Bool isFalse (Bool x) = x == False;
            if (all(isFalse,capEnable)) begin
              nextState = Idle;
              doTagLookup = False;
            end else if (all(isFalse,andTags)) begin
              // when all tags to write are 0
              nextState = ClearTag;
            end else begin
              // when writing at least a 1
              mReq = craftTagWriteReq(rootLvl,capAddr.capNumber,capTags,capEnable,tagged Invalid);
              nextState = SetTag;
            end
          end
          // ignore other types of requests
          default: begin
            doTagLookup = False;
            nextState = Idle;
          end
        endcase
        // when a lookup is required
        if (doTagLookup) begin
          pendingCapNumber <= capAddr.capNumber;
          pendingTags      <= newPendingTags;
          pendingCapEnable <= newPendingCapEnable;
          debug2("taglookup",
            $display(
              "<time %0t TagLookup> Starting lookup with capNum = ",
              $time, fshow(capAddr.capNumber),
              " ( pending tags = ", fshow(newPendingTags),
              ", pending cap enable = ",fshow(newPendingCapEnable)," )"
          ));
          doTransition(tagged Valid mReq,rootLvl,nextState,True);
        end else debug2("taglookup",
          $display(
            "<time %0t TagLookup> memory not covered",
            $time
        ));
      endmethod
      */
      // NEW version
      method Action put(CheriTagRequest req) if (pendingTagReqs.notFull);
        debug2("taglookup",
          $display(
            "<time %0t TagLookup> Enqueueing pending tag lookup request: ",
            $time, fshow(req)
        ));
        pendingTagReqs.enq(req);
      endmethod
    endinterface

    // lookup Slave response interface
    //////////////////////////////////////////////////////
    interface CheckedGet response;
      method Bool canGet() = !readReqs.first().covered || lookupRsp.notEmpty();
      method CheriTagResponse peek() = CheriTagResponse{
        `ifdef TAGCONTROLLER_BENCHMARKING
        // ignore uncovered case as assume all locations covered
        bench_id: lookupRsp.first().bench_id,
        `endif
        tags: (readReqs.first().covered) ?
          tagged Covered lookupRsp.first().tags :
          tagged Uncovered,
        request_id: (readReqs.first().covered) ?
          lookupRsp.first().request_id :
          readReqs.first().request_id
      };
      method ActionValue#(CheriTagResponse) get() if (!readReqs.first().covered || lookupRsp.notEmpty());
        // put response together
        CheriTagResponse tr = ?;
        
        // in case of covered request, dequeue the lookup response
        if (readReqs.first().covered) begin
          tr = CheriTagResponse{
            `ifdef TAGCONTROLLER_BENCHMARKING
            bench_id: lookupRsp.first().bench_id,
            `endif
            tags: tagged Covered lookupRsp.first().tags,
            request_id: lookupRsp.first().request_id
          };
          lookupRsp.deq();
        end else begin 
          // Uncovered request
          tr = CheriTagResponse{
            // ignore uncovered case as assume all locations covered
            `ifdef TAGCONTROLLER_BENCHMARKING
            bench_id: ?, // Benchmarking only looks at covered regions
            `endif
            tags: tagged Uncovered,
            request_id: readReqs.first().request_id
          };
        end
        // dequeue the pending request
        readReqs.deq();
        // debug msg and return response
        debug2("taglookup",
          $display(
            "<time %0t TagLookup> got valid lookup response ",
            $time, fshow(tr)
        ));
        return tr;
      endmethod
    endinterface

  endinterface

  // module Master interface
  /////////////////////////////////////////////////////////////////////////////

  interface Master memory;
    interface request  = toUGCheckedGet(ff2fifof(mReqs));
    interface response = toCheckedPut(ff2fifof(mRsps));
  endinterface

  // module cacheEvents interface
  /////////////////////////////////////////////////////////////////////////////

  `ifdef STATCOUNTERS
  interface Get cacheEvents;
    method ActionValue#(ModuleEvents) get () = tagCache.cacheEvents.get();
  endinterface
  `elsif PERFORMANCE_MONITORING
  method events = tagCache.events;
  `endif

  `ifdef TAGCONTROLLER_BENCHMARKING
  // Idle iff:
  // - Not reading any tags
  // - Not expecting any responses from tag cache
  // - Not got any requests queued up to send to tag cache
  method Bool isIdle = (state == Idle && !useNextRsp.notEmpty && !pendingTagReqs.notEmpty);
  `endif

endmodule




// NULL tag lookup
///////////////////////////////////////////////////////////////////////////////

/*
  descending_urgency = "initialise,drainMemRsp,readTagState,setTagState"
*/
//XXX(* synthesize *) can't synthesize with polymorphic interface (=> parameter keyword useless...)
module mkNullMultiLevelTagLookup (TagLookupIfc);

  
  // components instanciations
  /////////////////////////////////////////////////////////////////////////////

  // pending read requests fifo covered or not
  // FF#(Bool,1) readReqs <- mkLFF1();
  // FF#(Bool,2) readReqs <- mkUGFFDebug("TagLookup_readReqs");
  FF#(ReadReqInfo,2) readReqs <- mkUGFFDebug("TagLookup_readReqs");
  // lookup response fifo
  // FF#(LineTags,1) lookupRsp      <- mkUGFFDebug("TagLookup_lookupRsp");
  FF#(LookupResponse,2) lookupRsp      <- mkUGFFDebug("TagLookup_lookupRsp");

  // memory requests fifo
  FF#(CheriMemRequest, 8)  mReqs <-  mkUGFFDebug("TagLookup_mReqs");
  // memory response fifo
  FF#(CheriMemResponse, 2) mRsps <- mkUGFFDebug("TagLookup_mRsps");
 
  // module Slave interface
  /////////////////////////////////////////////////////////////////////////////

  interface Slave cache;

    // lookup Slave request interface
    //////////////////////////////////////////////////////
    interface CheckedPut request;
      method Bool canPut() = readReqs.notFull() && lookupRsp.notFull();
      // tag request
      //////////////////////////////
      method Action put(CheriTagRequest req) if (readReqs.notFull() && lookupRsp.notFull());
        debug2("taglookup",
          $display(
            "<time %0t TagLookup> received request ",
            $time, fshow(req)
        ));
        case (req.operation) matches
          // when it's a read
          //////////////////////////////
          tagged Read: begin
            readReqs.enq(
              ReadReqInfo {
                covered: True,
                request_id: req.request_id
              }
            );
            lookupRsp.enq(
              LookupResponse{
                `ifdef TAGCONTROLLER_BENCHMARKING
                bench_id: req.bench_id,
                `endif
                tags: unpack(0),
                request_id: req.request_id
              }
            );
          // ignore other types of requests
          end
          default: begin
          end
        endcase
      endmethod
    endinterface

    // lookup Slave response interface
    //////////////////////////////////////////////////////
    interface CheckedGet response;
      method Bool canGet() = !readReqs.first().covered || lookupRsp.notEmpty();
      method CheriTagResponse peek() = CheriTagResponse{
        `ifdef TAGCONTROLLER_BENCHMARKING
        // ignore uncovered case as assume all locations covered
        bench_id: lookupRsp.first().bench_id,
        `endif
        tags: (readReqs.first().covered) ?
          tagged Covered lookupRsp.first().tags:
          tagged Uncovered,
        request_id: (readReqs.first().covered) ?
          lookupRsp.first().request_id :
          readReqs.first().request_id
      };
      method ActionValue#(CheriTagResponse) get() if (!readReqs.first().covered || lookupRsp.notEmpty());
        // put response together
        CheriTagResponse tr = ?;
        // in case of covered request, dequeue the lookup response
        if (readReqs.first().covered) begin
          tr = CheriTagResponse{
            `ifdef TAGCONTROLLER_BENCHMARKING
            bench_id: lookupRsp.first().bench_id,
            `endif
            tags: tagged Covered lookupRsp.first().tags,
            request_id: lookupRsp.first().request_id
          };
          lookupRsp.deq();
        end else begin 
          tr = CheriTagResponse{
            `ifdef TAGCONTROLLER_BENCHMARKING
            bench_id: ?, // Benchmarking only tests covered regions
            `endif
            tags: tagged Uncovered,
            request_id: readReqs.first().request_id
          };
        end
        // dequeue the pending request
        readReqs.deq();
        // debug msg and return response
        debug2("taglookup",
          $display(
            "<time %0t TagLookup> got valid lookup response ",
            $time, fshow(tr)
        ));
        return tr;
      endmethod
    endinterface

  endinterface

  // module Master interface
  /////////////////////////////////////////////////////////////////////////////

  interface Master memory;
    interface request  = toUGCheckedGet(ff2fifof(mReqs));
    interface response = toCheckedPut(ff2fifof(mRsps));
  endinterface


  `ifdef TAGCONTROLLER_BENCHMARKING
  method Bool isIdle = !readReqs.notEmpty;
  `endif

  `ifdef STATCOUNTERS
  interface Get cacheEvents;
    method ActionValue#(ModuleEvents) get () = tagCache.cacheEvents.get();
  endinterface
  `elsif PERFORMANCE_MONITORING
  method events = ?;
  `endif
endmodule
