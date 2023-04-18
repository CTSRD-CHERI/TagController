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
import Connectable::* ;
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
import MultiLevelTagLookup::*;
import Merge::*;
import Bag::*;
import VnD::*;


// How many tag ops per cache can be in flight
typedef 1 TagOpsInFlight;

// Determines size of buffer before leafCache
// Allows cached root only requests to not be held up by leaf misses
typedef 1 CentralBufferSize;

typedef enum {Read, Clear, Set, Fold} TagOpType deriving (Bits, FShow, Eq);

typedef struct {
  TagOpType opType;
  CapNumber capNumber;
  LineTags newTagValues;
  LineTags enabledTags;
  TagRequestID request_id;
  `ifdef TAGCONTROLLER_BENCHMARKING
  Bit#(CheriTransactionIDWidth) bench_id;
  `endif
} RequestInfo deriving (Bits, FShow, Eq);

typedef struct {
  CheriMemRequest req;
  RequestInfo info;
} ProcessedRequest deriving (Bits, FShow);

// mkTagLookup module definition
///////////////////////////////////////////////////////////////////////////////

// Assumes that ALL addresses are covered
module mkPipelinedTagLookup #(
  // master ID to be used for memory requests
  parameter CheriMasterID mID,
  // ending address of the tags table
  parameter CheriPhyAddr tagTabEndAddr,
  // from leaf 0 ---> root 1. telem = Integer
  parameter Vector#(2, Integer) tableStructure,
  parameter CheriPhyAddr tagTabStrtAddr,
  // Size of the memory covered
  parameter Integer memCoveredSize
) (TagLookupIfc);

  // static parameters mostly copied from MulitLevelTagController
  /////////////////////////////////////////////////////////////////////////////

  // covered region include DRAM and BROM
  // starting address of the covered region
  CheriPhyAddr coveredStrtAddr = unpack(fromInteger(covered_start_addr));
  // ending address of the covered region
  CheriPhyAddr coveredEndAddr  = unpack(fromInteger(covered_start_addr + covered_mem_size));

  // root lvl must be 1 (only support 2 levels!)
  TDepth rootLvl = 1;
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
  // table descriptor has leaf lvl 0 ---> root lvl 1
  Vector#(2,TableLvl) tableDesc = genWith (lvlDesc);

  staticAssert(tagTabStrtAddr == tableDesc[1].startAddr,
    sprintf("Python-calculated table base 0x%0x != bluespec-calculated table base 0x%0x",
      pack(tagTabStrtAddr), pack(tableDesc[1].startAddr)));

  // Caches 
  /////////////////////////////////////////////////////////////////////////////

  // ROOT

  // memory requests fifo
  FF#(CheriMemRequest, 8)  rootBackupReqs <-  mkUGFFDebug("TagLookup_rootBackupReqs");
  // memory response fifo
  FF#(CheriMemResponse, 2) rootBackupRsps <- mkUGFFDebug("TagLookup_rootBackupRsps");

  CacheCore#(4, TSub#(Indices,3), TagOpsInFlight)  rootCache <- mkCacheCore(
    0, WriteAllocate, RespondAll, TCache,
    zeroExtend(rootBackupReqs.remaining()), ff2fifof(rootBackupReqs), ff2fifof(rootBackupRsps));
    
  Master#(CheriMemRequest,CheriMemResponse) root_master = interface Master
    interface request = toCheckedGet(ff2fifof(rootBackupReqs));
    interface response = toCheckedPut(ff2fifof(rootBackupRsps));
  endinterface;

  // LEAF
    
  // memory requests fifo
  FF#(CheriMemRequest, 8)  leafBackupReqs <-  mkUGFFDebug("TagLookup_leafBackupReqs");
  // memory response fifo
  FF#(CheriMemResponse, 2) leafBackupRsps <- mkUGFFDebug("TagLookup_leafBackupRsps");

  CacheCore#(4, TSub#(Indices,3), TagOpsInFlight)  leafCache <- mkCacheCore(
    1, WriteAllocate, RespondAll, TCache,
    zeroExtend(leafBackupReqs.remaining()), ff2fifof(leafBackupReqs), ff2fifof(leafBackupRsps));

  Master#(CheriMemRequest,CheriMemResponse) leaf_master = interface Master
    interface request = toCheckedGet(ff2fifof(leafBackupReqs));
    interface response = toCheckedPut(ff2fifof(leafBackupRsps));
  endinterface;

  // BACKUP

  // memory requests fifo
  FF#(CheriMemRequest, 8)  backupMemoryReqs <-  mkUGFFDebug("TagLookup_backupMemoryReqs");
  // memory response fifo
  FF#(CheriMemResponse, 2) backupMemoryRsps <- mkUGFFDebug("TagLookup_backupMemoryRsps");

  CacheCore#(4, TSub#(Indices,2), TagOpsInFlight)  backupCache <- mkCacheCore(
    2, WriteAllocate, RespondAll, TCache,
    zeroExtend(backupMemoryReqs.remaining()), ff2fifof(backupMemoryReqs), ff2fifof(backupMemoryRsps));
  
  Slave#(CheriMemRequest,CheriMemResponse) backup_slave = interface Slave
    interface CheckedPut request;
      method Bool canPut();
        return backupCache.canPut();
      endmethod
      method Action put(CheriMemRequest cmr);
        backupCache.put(cmr);
      endmethod
    endinterface
    interface CheckedGet response = backupCache.response;
  endinterface;


  // Attach caches together

  // Merge root and leaf master interfaces
  MergeIfc#(2) requestMerger <- mkMerge();
  mkConnection(root_master, requestMerger.slave[0]);
  mkConnection(leaf_master, requestMerger.slave[1]);
  // Connect merged master to backup cache
  mkConnection(requestMerger.merged, backup_slave);

  // Simply stuff "True" into commits because we never cancel transactions here
  rule stuffCommits;
    rootCache.nextWillCommit(True);
    leafCache.nextWillCommit(True);
    backupCache.nextWillCommit(True);
  endrule


  // module helper functions (Copied from MultiLevelTagLookup)
  /////////////////////////////////////////////////////////////////////////////

  function CheriPhyBitAddr getTableAddr(TDepth cd, CapNumber cn);
    TableLvl t = tableDesc[cd];
    CheriPhyBitAddr bitAddr = unpack(zeroExtend(cn >> t.shiftAmnt));
    bitAddr.byteAddr = unpack(pack(bitAddr.byteAddr) + pack(t.startAddr));
    return bitAddr;
  endfunction

  function Bool getRootEntry(CapNumber cn, Bit#(CheriDataWidth) tags);
    CheriPhyBitAddr a = getTableAddr(rootLvl,cn);
    CheriPhyBitOffset bitOffset = truncate(pack(a));
    // if node lvl, return a single tag
    return unpack(tags[bitOffset]);
  endfunction

  function LineTags getLeafLine(CapNumber cn, Bit#(CheriDataWidth) tags);
    CheriPhyBitAddr a = getTableAddr(leafLvl,cn);
    CheriPhyBitOffset bitOffset = truncate(pack(a));
    // if leaf lvl, return a LineTags
    Vector#(TDiv#(CheriDataWidth,SizeOf#(LineTags)),LineTags) lines = unpack(tags);
    CheriPhyBitOffset idx = bitOffset >> valueof(TLog#(SizeOf#(LineTags)));
    return unpack(pack(lines[idx]));
  endfunction

  function Bit#(CheriDataWidth) getOldTagsEntry (
    CapNumber cn,
    Bit#(CheriDataWidth) tags,
    TDepth cd
  );
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
    Bit#(CheriDataWidth) old
  );
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

  function CheriMemRequest craftTagReadReq (
    TDepth d, 
    CapNumber cn
  );
    CheriPhyAddr a = getTableAddr(d,cn).byteAddr;
    CheriMemRequest mReq = defaultValue;
    mReq.addr            = a;
    mReq.masterID        = mID;
    mReq.transactionID   = ?; // Must be set later
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
    Maybe#(TableLvl) nz // need zeroing
  ); 
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
    mReq.transactionID   = ?;
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

  // function ProcessedRequest mergeWithFold (
  //   ProcessedRequest fold_request,
  //   ProcessedRequest other_request,
  // );
  //   if (other_request.opType == Read):
  //     if (other_req

  // define a zingle zero or a single one
  Vector#(1,Bool) zero = replicate (False);
  Vector#(1,Bool) one  = replicate (True);

  // Root tags lookup 
  /////////////////////////////////////////////////////////////////////////////

  // Used for requests to rootCache
  Reg#(CheriTransactionID) rootTransNum <- mkConfigReg(0);

  // Used when consuming respones
  Bag#(
    TagOpsInFlight,     // Number of fifos
    CheriTransactionID, // Key type
    RequestInfo        // Data type
  ) inFlightRootReqs <- mkSmallBag();
  
  // If there might be a fold later then stall
  // multiple ports so can unstall and issue req in same cycle
  // can set stalled to false after either root lookup (no bubble)
  // or leaf lookup (1 bubble)
  Reg#(Bool) rootStalled[3] <- mkCReg(3, False);

  // Pending fold requests - if valid has priority over others
  // NOTE no new fold requests will be created until previous one is sent
  // due to stalls. So no need to worry about enq to full fold request
  FF#(ProcessedRequest,1) foldRequests <- mkUGFFBypass();

  // Pending root requests
  FF#(ProcessedRequest, 1) pendingRootReqs <- mkUGFFBypass();

  // Processes request (e.g. from tag controller) and put it into pendingRootReqs 
  function Action handle_new_root_request(CheriTagRequest req);
    return (
      action
        // initialise contents for RequestInfo
        TagOpType opType = Read;
        LineTags newTagValues = unpack(0);
        LineTags enabledTags = unpack(0);
        TagRequestID request_id = req.request_id;
        `ifdef TAGCONTROLLER_BENCHMARKING
        Bit#(CheriTransactionIDWidth) bench_id = req.bench_id;
        `endif

        Bool doTagRequest = False;

        // initialise root table lookup
        CheriCapAddress capAddr = unpack(pack(req.addr) - pack(coveredStrtAddr));
        CheriMemRequest rootReq = ?;

        // work out what to do depending on operation type
        case(req.operation) matches
          tagged Read: begin 
            opType = Read;
            doTagRequest = True;

            rootReq = craftTagReadReq(rootLvl,capAddr.capNumber);

            `ifdef TAGCONTROLLER_BENCHMARKING
            debug2("tracing", $display(
              "<time %0t Tracing> ", $time, fshow(req.bench_id), " ",
              "start ROOT | read"
            )); 
            `endif
          end
          tagged Write .wop: begin 
            // get cap tags
            LineTags capTags = wop.tags;
            LineTags capEnable = wop.writeEnable;

            // and cap tags with cap enable
            LineTags andTags = zipWith(andBool,capTags,capEnable);

            // update new pending tags
            newTagValues = capTags;
            enabledTags = capEnable;

            //check wether to write anything or not
            function Bool isTrue  (Bool x) = x == True;
            function Bool isFalse (Bool x) = x == False;

            // Ignore request if not writing any tags
            // TODO: move this out of pipelinedtaglookup - waste of time!
            if (all(isFalse,capEnable)) begin
              doTagRequest = False;
            end else if (all(isFalse,andTags)) begin
              // when all tags to write are 0
              opType = Clear;
              doTagRequest = True;

              rootReq = craftTagReadReq(rootLvl,capAddr.capNumber);

              `ifdef TAGCONTROLLER_BENCHMARKING
              debug2("tracing", $display(
                "<time %0t Tracing> ", $time, fshow(req.bench_id), " ",
                "start ROOT | read | CLEARING"
              )); 
              `endif
            end else begin
              // when writing at least a 1
              opType = Set;
              doTagRequest = True;
              
              rootReq = craftTagWriteReq(rootLvl,capAddr.capNumber,capTags,capEnable,tagged Invalid);
              
              `ifdef TAGCONTROLLER_BENCHMARKING
              debug2("tracing", $display(
                "<time %0t Tracing> ", $time, fshow(req.bench_id), " ",
                "start ROOT | write"
              )); 
              `endif
            end
          end
        endcase 
      
        if(doTagRequest) begin 
          let request_info = RequestInfo{
            `ifdef TAGCONTROLLER_BENCHMARKING
            bench_id: bench_id,
            `endif 
            opType: opType,
            capNumber: capAddr.capNumber,
            newTagValues: newTagValues,
            enabledTags: enabledTags,
            request_id: request_id
          };

          debug2("taglookup", $display( 
            "<time %0t TagLookup> ", $time,
            "Received new request: ", fshow(request_info)
          ));

          pendingRootReqs.enq(
            ProcessedRequest {
              req: rootReq,
              info: request_info
            }
          );
        end else debug2("tagLookup", $display(
          "<time %0t TagLookup> ", $time,
          "Ignored new request: ", fshow(req)
        ));
      endaction
    );
  endfunction

  // 
  rule issueRootRequest (
    rootCache.canPut && 
    (
      (pendingRootReqs.notEmpty && !rootStalled[1]) 
      || 
      foldRequests.notEmpty
    ) &&
    // Don't let there be two requests in flight with same ID!
    !inFlightRootReqs.isMember(rootTransNum).v
  );
    if (foldRequests.notEmpty) begin 
      let mReq = foldRequests.first.req;
      let req_info = foldRequests.first.info;

      mReq.transactionID = rootTransNum;

      debug2("taglookup", $display( 
        "<time %0t TagLookup> ", $time,
        "Sending FLUSH request: ", fshow(mReq)
      ));
      debug2("taglookup", $display( 
        "<time %0t TagLookup> ", $time,
        "Sent to root with request info: ", fshow(req_info)
      ));

      rootCache.put(mReq);

      inFlightRootReqs.insert(rootTransNum, req_info);
      
      rootTransNum <= rootTransNum + 1;
      foldRequests.deq();
    end else if (pendingRootReqs.notEmpty) begin 
      let mReq = pendingRootReqs.first.req;
      let req_info = pendingRootReqs.first.info;

      mReq.transactionID = rootTransNum;

      debug2("taglookup", $display( 
        "<time %0t TagLookup> ", $time,
        "Sending non-flush request: ", fshow(mReq)
      ));
      debug2("taglookup", $display( 
        "<time %0t TagLookup> ", $time,
        "Sent to root with request info: ", fshow(req_info)
      ));
      rootCache.put(mReq);

      inFlightRootReqs.insert(rootTransNum, req_info);
      
      rootTransNum <= rootTransNum + 1;
      pendingRootReqs.deq();
    end
  endrule

  // Root tag responses
  /////////////////////////////////////////////////////////////////////////////

  // Used for requests to leafCache
  Reg#(CheriTransactionID) leafTransNum <- mkConfigReg(0);

  // Used when consuming respones
  Bag#(
    TagOpsInFlight,     // Number of fifos
    CheriTransactionID, // Key type
    RequestInfo        // Data type
  ) inFlightLeafReqs <- mkSmallBag;
 

  // Tag lookup responses sent before accessing leaves
  // The leaf responses are older so have priority
  // There could be as many as InFlight/2 cycles where an early response is
  // created but a leaf response id dequeued. Add an extra slot so consumeRootResponse
  // can be called even if InFlight/2 requests are in the fifo
  FF#(LookupResponse, TAdd#(TDiv#(InFlight,2),1)) earlyRsps <- mkUGFFDebug("TagLookup_earlyRsps");

  // Pending leaf requests
  // TODO: what size should this be!
  FF#(ProcessedRequest, CentralBufferSize) pendingLeafReqs <- mkUGFFBypass();

  // Get response from rootCache and either respond early or send request to leafCache
  rule consumeRootResponse (rootCache.response.canGet && earlyRsps.notFull);
    CheriMemResponse resp <- rootCache.response.get();
    CheriTransactionID transID = resp.transactionID;

    // Ignore validity - no way for it not to be valid!
    RequestInfo request_info = inFlightRootReqs.isMember(transID).d;
    // ALL lookups are 1 flit so safe to dequeue
    inFlightRootReqs.remove(transID);

    // Tags at START of root request (note may have been overwritten if a write)
    Bit#(CheriDataWidth) rspData = resp.data.data;

    // Returns tagged Node Bool
    Bool rootTag = getRootEntry(
      request_info.capNumber,
      rspData
    );

    Bool doTagRequest = False;
    CheriMemRequest leafReq = ?;

    debug2("taglookup", $display( 
      "<time %0t TagLookup> ", $time,
      "Recieved root response: ", fshow(resp)
    ));

    case (request_info.opType) matches
      Read: begin
        if (!rootTag) begin
          // early 0
          doTagRequest = False;

          debug2("taglookup", $display( 
            "<time %0t TagLookup> ", $time,
            "Root tag was zero, no need to lookup leaf: ", fshow(resp)
          ));

          `ifdef TAGCONTROLLER_BENCHMARKING
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "end ROOT | read | NO LEAF"
          )); 
          `endif

          // enqueue a 0 response
          earlyRsps.enq(
            LookupResponse{
              `ifdef TAGCONTROLLER_BENCHMARKING
              bench_id: request_info.bench_id,
              `endif
              tags: unpack(0),
              request_id: request_info.request_id
            }
          );
        end else begin 
          // tag 1, need leaf lookup
          debug2("taglookup", $display( 
            "<time %0t TagLookup> ", $time,
            "Root tag was one, need to lookup leaf: ", fshow(resp)
          ));

          `ifdef TAGCONTROLLER_BENCHMARKING
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "end ROOT | read"
          )); 
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "start LEAF | read"
          )); 
          `endif

          // request next table entry
          doTagRequest = True;
          leafReq = craftTagReadReq(leafLvl,request_info.capNumber);
        end
      end
      Set: begin 
        // detect 0 -> 1 transition
        CheriPhyBitAddr a = getTableAddr(rootLvl,request_info.capNumber);
        Maybe#(TableLvl) needZeros = (!unpack(rspData[{a.byteAddr.byteOffset,a.bitOffset}])) ?
            tagged Valid tableDesc[rootLvl] : tagged Invalid;
        
        // Do some logging!
        if (needZeros matches tagged Valid .t) begin
          debug2("taglookup", $display(
            "<time %0t TagLookup> ", $time,
            "SetTag 0 -> 1 transition detected at root level"
          ));
          `ifdef TAGCONTROLLER_BENCHMARKING
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "end ROOT | write | ZERO LEAVES"
          )); 
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "start LEAF | write | IGNORED"
          )); 
          `endif
        end else begin 
          `ifdef TAGCONTROLLER_BENCHMARKING
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "end ROOT | write"
          )); 
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "start LEAF | write | IGNORED"
          )); 
          `endif
        end

        doTagRequest = True;
        leafReq = craftTagWriteReq(
          leafLvl,
          request_info.capNumber,
          request_info.newTagValues,
          request_info.enabledTags,
          needZeros
        );        
      end 
      Clear: begin 
        if (!rootTag) begin
          debug2("taglookup",
            $display(
              "<time %0t TagLookup> early 0 clearing tag",
              $time
          ));

          `ifdef TAGCONTROLLER_BENCHMARKING
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "end ROOT | read | NO LEAF"
          )); 
          `endif
          
          doTagRequest = False;
          // No risk of a fold so can unstall the root
          rootStalled[0] <= False;
        end else begin 
          debug2("taglookup",
            $display(
              "<time %0t TagLookup> found 1 at root when clearing tag, keep going down...",
              $time
          ));

          `ifdef TAGCONTROLLER_BENCHMARKING
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "end ROOT | read"
          )); 
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "start LEAF | write"
          )); 
          `endif

          // send next lookup (Note is write! Multilevel sends read first)
          doTagRequest = True;
          leafReq = craftTagWriteReq(
            leafLvl,
            request_info.capNumber,
            request_info.newTagValues,
            request_info.enabledTags,
            tagged Invalid
          );
        end
      end 
      Fold: begin 
        // Do nothing!
        doTagRequest = False;
      end 
    endcase

    if(doTagRequest) begin 

      debug2("taglookup", $display( 
        "<time %0t TagLookup> ", $time,
        "New pending leaf request: ", fshow(request_info)
      ));

      pendingLeafReqs.enq(
        ProcessedRequest {
          req: leafReq,
          info: request_info
        }
      );
    end else debug2("tagLookup", $display(
      "<time %0t TagLookup> ", $time,
      "No need for further leaf request"
    ));
  endrule

  rule issueLeafRequest (
    leafCache.canPut && 
    pendingLeafReqs.notEmpty && 
    // Don't let there be two requests in flight with same ID!
    !inFlightLeafReqs.isMember(leafTransNum).v 
  );
    let mReq = pendingLeafReqs.first.req;
    let req_info = pendingLeafReqs.first.info;

    mReq.transactionID = leafTransNum;

    debug2("taglookup", $display( 
      "<time %0t TagLookup> ", $time,
      "Sent to leaf with request info: ", fshow(req_info)
    ));
    leafCache.put(mReq);

    inFlightLeafReqs.insert(leafTransNum, req_info);
    
    leafTransNum <= leafTransNum + 1;
    pendingLeafReqs.deq();
  endrule

  // Leaf tag responses
  /////////////////////////////////////////////////////////////////////////////
  
  // Responses only produced after reading leaf values - have priority over early
  // responses
  FF#(LookupResponse, 2) lateRsps <- mkUGFFDebug("TagLookup_earlyRsps");

  // Get response from leafCache and either end request or enq to foldRequests
  // NOTE: no risk of foldRequests being full as has priority
  rule consumeLeafResponse (leafCache.response.canGet && earlyRsps.notFull);
    CheriMemResponse resp <- leafCache.response.get();
    CheriTransactionID transID = resp.transactionID;

    // Ignore validity - no way for it not to be valid!
    RequestInfo request_info = inFlightLeafReqs.isMember(transID).d;
    // ALL lookups are 1 flit so safe to dequeue
    inFlightLeafReqs.remove(transID);

    // Tags at START of root request (note may have been overwritten if a write)
    Bit#(CheriDataWidth) rspData = resp.data.data;

    // Returns tagged Node Bool
    LineTags leafLine = getLeafLine(
      request_info.capNumber,
      rspData
    );

    debug2("taglookup", $display( 
      "<time %0t TagLookup> ", $time,
      "Recieved leaf response: ", fshow(resp)
    ));

    case (request_info.opType) matches
      Read: begin
        // Reached a Leaf of the table, return lookup
        debug2("taglookup", $display(
          "<time %0t TagLookup> ", $time,
          "Leaf tags: ", leafLine
        ));

        `ifdef TAGCONTROLLER_BENCHMARKING
        debug2("tracing", $display(
          "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
          "end LEAF | read"
        )); 
        `endif

        // enqueue the lookup response
        lateRsps.enq(
          LookupResponse{  
            `ifdef TAGCONTROLLER_BENCHMARKING
            bench_id: request_info.bench_id,
            `endif
            tags: leafLine,
            request_id: request_info.request_id
          }
        );
      end
      Set: begin 
        `ifdef TAGCONTROLLER_BENCHMARKING
        debug2("tracing", $display(
          "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
          "end LEAF | write"
        ));
        `endif
      end 
      Clear: begin 

        Bit#(CheriDataWidth) preClearedTags = getOldTagsEntry(
          request_info.capNumber,
          rspData,
          leafLvl
        );
        Bit#(CheriDataWidth) afterClearedTags =  getNewTagsEntry(
          leafLvl,
          request_info.capNumber,
          request_info.newTagValues,
          request_info.enabledTags,
          preClearedTags
        );

        // If the leaf tags are now ALL zero
        if (pack(afterClearedTags)==0) begin
          `ifdef TAGCONTROLLER_BENCHMARKING
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "end LEAF | write | FOLDING"
          )); 
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "start root | write | IGNORED"
          )); 
          `endif

          let rootRequest = craftTagWriteReq(
            rootLvl,
            request_info.capNumber,
            zero, // Zero the root tag (length 1)
            one,  // Only clear this one root tag
            tagged Invalid
          );

          request_info.opType = Fold;

          foldRequests.enq(
            ProcessedRequest {
              req: rootRequest,
              info: request_info
            }
          );
        end else begin
          `ifdef TAGCONTROLLER_BENCHMARKING
          debug2("tracing", $display(
            "<time %0t Tracing> ", $time, fshow(request_info.bench_id), " ",
            "end LEAF | read | NO FOLD"
          )); 
          `endif
          rootStalled[1] <= False;
        end
      end 
      // Never send Fold requests to leaf
    endcase
  endrule


  // Sub interfaces
  /////////////////////////////////////////////////////////////////////////////

  // Interface the tag controller uses to send tag requests
  interface Slave cache;
    interface CheckedPut request;
      method Bool canPut() = pendingRootReqs.notFull;
      method Action put(CheriTagRequest req) if (pendingRootReqs.notFull);
        debug2("taglookup", $display(
            "<time %0t TagLookup> ", $time,
            "Processing new tag lookup request: ", fshow(req)
        ));
        handle_new_root_request(req);
      endmethod
    endinterface
    interface CheckedGet response;
      method Bool canGet() = earlyRsps.notEmpty || lateRsps.notEmpty();
      method CheriTagResponse peek();
        if (lateRsps.notEmpty()) begin
          // Use response from leaf cache
          return CheriTagResponse{
            `ifdef TAGCONTROLLER_BENCHMARKING
            bench_id: lateRsps.first().bench_id,
            `endif
            tags: tagged Covered lateRsps.first().tags,
            request_id: lateRsps.first().request_id
          };
        end else begin 
          // Use response from root cache
          return CheriTagResponse{
            `ifdef TAGCONTROLLER_BENCHMARKING
            bench_id: earlyRsps.first().bench_id,
            `endif
            tags: tagged Covered earlyRsps.first().tags,
            request_id: earlyRsps.first().request_id
          };
        end
      endmethod
      method ActionValue#(CheriTagResponse) get() if (earlyRsps.notEmpty || lateRsps.notEmpty());
        CheriTagResponse tr = ?;
      
        if (lateRsps.notEmpty()) begin
          // Use response from leaf cache
          tr = CheriTagResponse{
            `ifdef TAGCONTROLLER_BENCHMARKING
            bench_id: lateRsps.first().bench_id,
            `endif
            tags: tagged Covered lateRsps.first().tags,
            request_id: lateRsps.first().request_id
          };
          lateRsps.deq();

          debug2("taglookup", $display(
            "<time %0t TagLookup> ", $time,
            "got valid lookup response LATE ", fshow(tr)
          ));
        end else begin 
          // Use response from root cache
          tr =  CheriTagResponse{
            `ifdef TAGCONTROLLER_BENCHMARKING
            bench_id: earlyRsps.first().bench_id,
            `endif
            tags: tagged Covered earlyRsps.first().tags,
            request_id: earlyRsps.first().request_id
          };
          earlyRsps.deq();

          debug2("taglookup", $display(
            "<time %0t TagLookup> ", $time,
            "got valid lookup response EARLY ", fshow(tr)
          ));
        end
        // debug msg and return response

        return tr;
      endmethod
    endinterface
  endinterface
        
  // Interface the tag controller uses to connect tag lookup to DRAM
  interface Master memory;
    interface request = toUGCheckedGet(ff2fifof(backupMemoryReqs));
    interface response = toCheckedPut(ff2fifof(backupMemoryRsps));
  endinterface

  `ifdef TAGCONTROLLER_BENCHMARKING
  // Does the tag controller still need access to DRAM?
  method Bool isIdle = (
    !pendingRootReqs.notEmpty &&
    inFlightRootReqs.empty &&
    !pendingLeafReqs.notEmpty &&
    inFlightLeafReqs.empty
  );
  `endif

endmodule
