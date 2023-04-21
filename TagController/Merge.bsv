/*-
 * Copyright (c) 2011 Jonathan Woodruff
 * Copyright (c) 2014 Alexandre Joannou
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


/*****************************************************************************
  Bluespec interface to merge Memory requests into a single 256-bit Memory interface.
  ==============================================================
  Jonathan Woodruff, July 2011
 *****************************************************************************/
import Debug::*;
import MasterSlaveCHERI::*;
import FIFO::*;
import FIFOF::*;
import SpecialFIFOs::*;
import Vector::*;
import MemTypesCHERI::*;
   
typedef Bit#(1) InterfaceT;

interface MergeIfc#(numeric type numIfc);
  interface Master#(CheriMemRequest, CheriMemResponse) merged;
  interface Vector#(numIfc, Slave#(CheriMemRequest, CheriMemResponse)) slave;
endinterface

// NOTE: this makes use of cachecorder only using transaction ids in the range 0-15
//       by using 5th bit to indicate cache of origin
module mkMerge2CacheCore(MergeIfc#(2)) provisos (Add#(a_,5,CheriTransactionIDWidth));
    Vector#(2,  FIFOF#(CheriMemRequest))    req_fifos   <- replicateM(mkUGFIFOF);
    FIFOF#(CheriMemRequest)                 nextReq     <- mkBypassFIFOF;
    Vector#(2,  FIFOF#(CheriMemResponse))   rsp_fifos   <- replicateM(mkFIFOF);
    FIFOF#(InterfaceT)                      pendingReqs <- mkSizedFIFOF(16);

    rule mergeInputs;
        Bool found = False;
        // ALWAYS prioritise leaf cache to prevent backpressure
        Bit#(1) j = 1;
        for (Integer i=0; i<2; i=i+1) begin
            if (found == False && req_fifos[j].notEmpty) begin
                debug2("merge", $display(
                    "<time %0t Merge> ", $time,
                    "Selecting request from cache: ", fshow(j)
                )); 

                let next_req = req_fifos[j].first;
                next_req.transactionID[4] = j;
                nextReq.enq(next_req);

                // Used to indicate order of responses
                // TODO: allow this to be out of order
                pendingReqs.enq(j);

                req_fifos[j].deq();
                found = True;
            end

            // convert to Bool and back
            j = ~j;
        end
    endrule
    
    Vector#(2, Slave#(CheriMemRequest, CheriMemResponse)) slaves;
    for (Integer i=0; i<valueOf(2); i=i+1) begin
        slaves[i] = interface Slave;
            interface response = toCheckedGet(rsp_fifos[i]);
            interface request  = toCheckedPut(req_fifos[i]);
        endinterface;
    end
    
    interface slave = slaves;
    
    interface Master merged;
        interface CheckedGet request = toCheckedGet(nextReq);
        interface CheckedPut response;
            method Bool canPut = (rsp_fifos[pendingReqs.first].notFull && pendingReqs.notEmpty);
            method Action put(CheriMemResponse resp);
                let j = resp.transactionID[4];
                debug2("merge", $display(
                    "<time %0t Merge> ", $time,
                    "Sending backup cache response to cache: ", fshow(pendingReqs.first),
                    " j: ", fshow(j)
                )); 
                Bit#(4) resp_trans_id = truncate(resp.transactionID);
                resp.transactionID = zeroExtend(resp_trans_id);

                debug2("merge", $display(
                    "<time %0t Merge> ", $time,
                    "Response: ", fshow(resp)
                )); 

                // rsp_fifos[pendingReqs.first].enq(resp);
                rsp_fifos[j].enq(resp);

                // Might get multiple read responses for one request
                if (resp.operation matches tagged Read .rr) begin
                    if (rr.last) begin
                        debug2("merge", $display(
                            "<time %0t Merge> ", $time,
                            "Treating as last response for this request"
                        )); 
                        pendingReqs.deq;
                    end
                end else begin
                    debug2("merge", $display(
                        "<time %0t Merge> ", $time,
                        "Treating as last response for this request"
                    )); 
                    pendingReqs.deq;
                end
            endmethod
        endinterface
    endinterface

endmodule