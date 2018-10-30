/*-
 * Copyright (c) 2018 Jonathan Woodruff
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

import ConfigReg::*;
import Vector::*;
import FF::*;

// Equal to Bluespec equivelant
module mkUGFFFullOfUniqueInts#(Bit#(16) cacheId)(FF#(data, depth))
provisos(Log#(depth,logDepth),Bits#(data, data_width),Literal#(data),FShow#(data));
  Array#(Reg#(Vector#(depth,data)))    rf  <- mkCReg(2,genWith(fromInteger)); // BRAM
  Reg#(data)                     firstReg  <- mkConfigRegU;
  Reg#(Bit#(TAdd#(logDepth,1)))     lhead  <- mkConfigRegA(16);
  Reg#(Bit#(TAdd#(logDepth,1)))  ltail[2]  <- mkCReg(2,0);
  
  Bit#(TAdd#(logDepth,1)) level = lhead - ltail[0];
  Bool empty = (level==0);
  Bool full  = (level==fromInteger(valueOf(depth)));
  Bit#(logDepth) head = truncate(lhead);
  
  rule readTail;
    Bit#(logDepth) tail = truncate(ltail[1]);
    firstReg <= rf[1][tail];
  endrule
  
  method Action enq(data in);
    rf[0][head] <= in;
    lhead <= lhead + 1;
  endmethod
  method Action deq();
    ltail[0] <= ltail[0]+1;
  endmethod
  method data first() = firstReg;
  method Bool notFull() = !full;
  method Bool notEmpty() = !empty;
  method Action clear() = action ltail[1] <= lhead; endaction;
  method Bit#(TAdd#(TLog#(depth), 1)) remaining() = fromInteger(valueOf(depth)) - level;
endmodule