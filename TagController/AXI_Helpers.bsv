/*-
 * Copyright (c) 2018 Jonathan Woodruff
 * Copyright (c) 2018 Alexandre Joannou
 * All rights reserved.
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

import DefaultValue::*;
import AXI4_Types::*;
import AXI4_AXI4Lite_Types :: *;
import MemTypesCHERI::*;

typedef struct {
  AWFlit#(id_, addr_, 0) aw;
  WFlit#(data_, tag_) w;
} WriteReqFlit#(numeric type id_, numeric type addr_, numeric type data_, numeric type tag_)
deriving (Bits, FShow);

typedef union tagged {
  WriteReqFlit#(id_, addr_, data_, tag_) Write;
  ARFlit#(id_, addr_, 0) Read;
} ReqFlit#(numeric type id_, numeric type addr_, numeric type data_, numeric type tag_)
deriving (Bits, FShow);
instance DefaultValue#(ReqFlit#(id_, addr_, data_, tag_));
  function defaultValue = tagged Read defaultValue;
endinstance

typedef union tagged {
  BFlit#(id_, 0) Write;
  RFlit#(id_, data_, tag_) Read;
} RspFlit#(numeric type id_, numeric type data_, numeric type tag_)
deriving (Bits, FShow);
instance DefaultValue#(RspFlit#(id_, data_, tag_));
  function defaultValue = tagged Write defaultValue;
endinstance

typedef ReqFlit#(4, addr_, 128, 1) MemReq#(numeric type addr_);
typedef RspFlit#(4, 128, 1)        MemRsp;

typedef ReqFlit#(8, addr_, 128, 0) DRAMReq#(numeric type addr_);
typedef RspFlit#(8, 128, 0)        DRAMRsp;

// Request ranslators between AXI and CHERI Memory

function CheriMemRequest axi2mem_req(MemReq#(32) mr);
  CheriMemRequest req = ?;
  case (mr) matches
    tagged Write .w: begin
      req = CheriMemRequest{
        addr: unpack(zeroExtend(w.aw.awaddr)),
        masterID: 0,
        transactionID: zeroExtend(w.aw.awid),
        operation: tagged Write {
                        uncached: (w.aw.awcache < 4), // All options less than 4 look like uncached.
                        conditional: False, // For now?
                        byteEnable: unpack(truncate(w.w.wstrb)),
                        bitEnable: -1,
                        data: Data{cap: unpack(w.w.wuser), data: truncate(w.w.wdata)},
                        last: w.w.wlast
                    }
      };
    end
    tagged Read .r:
      req = CheriMemRequest{
        addr: unpack(zeroExtend(r.araddr)),
        masterID: 0,
        transactionID: zeroExtend(r.arid),
        operation: tagged Read {
                        uncached: (r.arcache < 4), // All options less than 4 look like uncached.
                        linked: False, // For now?
                        noOfFlits: unpack(truncate(r.arlen)),
                        bytesPerFlit: unpack(r.arsize)
                    }
      };
  endcase
  return req;
endfunction

function DRAMReq#(32) mem2axi_req(CheriMemRequest mr);
  DRAMReq#(32) req = defaultValue;
  case (mr.operation) matches
    tagged Write .w: begin
      req = tagged Write WriteReqFlit{
        aw: AWFlit{
          awid: pack(getReqId(mr)),
          awaddr: truncate(pack(mr.addr)),
          awlen: 0,
          awsize: 4, // 16 bytes
          awburst: INCR,
          awlock: False,
          awcache: ((w.uncached) ? 0:15), // unached or fully cached
          awprot: 0,
          awqos: 0,
          awregion: 0,
          awuser: ?
        },
        w: WFlit{
          wdata: w.data.data,
          wstrb: zeroExtend(pack(w.byteEnable)),
          wlast: w.last,
          wuser: ?
        }
      };
    end
    tagged Read .r:
      req = tagged Read ARFlit{
        arid: pack(getReqId(mr)),
        araddr: truncate(pack(mr.addr)),
        arlen: zeroExtend(pack(r.noOfFlits)),
        arsize: pack(r.bytesPerFlit),
        arburst: INCR,
        arlock: False,
        arcache: ((r.uncached) ? 0:15), // unached or fully cached
        arprot: 0,
        arqos: 0,
        arregion: 0,
        aruser: ?
      };
  endcase
  return req;
endfunction

// Response ranslators between AXI and CHERI Memory

function CheriMemResponse axi2mem_rsp(DRAMRsp mr);
  CheriMemResponse rsp = defaultValue;
  case (mr) matches
    tagged Write .w: begin
      rsp = CheriMemResponse{
        masterID: truncateLSB(w.bid),
        transactionID: truncate(w.bid),
        error: NoError,
        data: ?,
        operation: tagged Write
      };
    end
    tagged Read .r: begin
      rsp = CheriMemResponse{
        masterID: truncateLSB(r.rid),
        transactionID: truncate(r.rid),
        error: NoError,
        data: Data{cap: ?, data: r.rdata},
        operation: tagged Read {last: r.rlast}
      };
    end
  endcase
  return rsp;
endfunction

function MemRsp mem2axi_rsp(CheriMemResponse mr);
  MemRsp rsp = defaultValue;
  case (mr.operation) matches
    tagged Write .w: begin
      rsp = tagged Write BFlit{
        bid: truncate(mr.transactionID),
        bresp: OKAY,
        buser: ?
      };
    end
    tagged Read .r:
      rsp = tagged Read RFlit{
        rid: truncate(mr.transactionID),
        rdata: mr.data.data,
        rresp: OKAY,
        rlast: r.last,
        ruser: pack(mr.data.cap)
      };
  endcase
  return rsp;
endfunction
