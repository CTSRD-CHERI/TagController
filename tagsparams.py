#! /usr/bin/env python3
#-
# Copyright (c) 2016 Alexandre Joannou
# Copyright (c) 2019 Jonathan Woodruff
# All rights reserved.
#
# This software was developed by SRI International and the University of
# Cambridge Computer Laboratory under DARPA/AFRL contract FA8750-10-C-0237
# ("CTSRD"), as part of the DARPA CRASH research programme.
#
# @BERI_LICENSE_HEADER_START@
#
# Licensed to BERI Open Systems C.I.C. (BERI) under one or more contributor
# license agreements.  See the NOTICE file distributed with this work for
# additional information regarding copyright ownership.  BERI licenses this
# file to you under the BERI Hardware-Software License, Version 1.0 (the
# "License"); you may not use this file except in compliance with the
# License.  You may obtain a copy of the License at:
#
#   http://www.beri-open-systems.org/legal/license-1-0.txt
#
# Unless required by applicable law or agreed to in writing, Work distributed
# under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations under the License.
#
# @BERI_LICENSE_HEADER_END@
#

import argparse
from datetime import datetime
from math import log
import functools

################################
# Parse command line arguments #
################################

parser = argparse.ArgumentParser(description='script parameterizing the cheri tags controller')

def auto_int (x):
    return int(x,0)

parser.add_argument('-v', '--verbose', action='store_true', default=False,
                    help="turn on output messages")
parser.add_argument('-c','--cap-size', type=auto_int, default=256,
                    help="capability size in bits")
parser.add_argument('-s','--structure', type=auto_int, nargs='+', default=[0],
                    help="list from leaf to root of branching factors describing the tags tree")
parser.add_argument('-t','--top-addr', type=auto_int, default=0x40000000,
                    help="memory address at which the tags table should start growing down from")
parser.add_argument('--covered-start-addr', type=auto_int, default=0x00000000,
                    help="the starting address of the region for which the tag controller should preserve tags")
parser.add_argument('-m','--covered-mem-size', type=auto_int, default=(2**30+2**20),
                    help="size of the memory to be covered by the tags")
parser.add_argument('-a','--addr-align', type=auto_int, default=32,
                    help="alignement requirement (in bytes) for table levels addresses")
parser.add_argument('-b','--bsv-import-output', nargs='?', const="TagTableStructure.bsv", default=None,
                    help="generate Bluespec MultiLevelTagLookup module import configuration file")
parser.add_argument('-l','--linker-inc-output', nargs='?', const="tags-params.ld", default=None,
                    help="generate tags configuration linker include file")

args = parser.parse_args()

if args.verbose:
    def verboseprint(msg):
        print(msg)
else:
    verboseprint = lambda *a: None

####################################
# values the script will work with #
####################################

verboseprint("Deriving tags configuration from parameters:")
verboseprint("covered_mem_size = %d bytes" % args.covered_mem_size)
verboseprint("cap_size = %d bits" % args.cap_size)
verboseprint("top_addr = 0x%x" % args.top_addr)
verboseprint("addr_align = %d bytes (%d addr bottom bits to ignore)" % (args.addr_align, log(args.addr_align,2)))
verboseprint("structure = %s" % args.structure)

######################
# compute parameters #
######################

class TableLvl():
    def __init__ (self, startAddr, size):
        self.startAddr = startAddr
        self.size = size
    def __repr__(self):
        return str(self)
    def __str__(self):
        return "{0x%x, %d bytes}" % (self.startAddr, self.size)

def table_lvl(lvl):
    mask = ~0 << int(log(args.addr_align,2))
    if lvl == 0:
        size = args.covered_mem_size // args.cap_size
        addr = args.top_addr-size
    else:
        t = table_lvl(lvl-1)
        size = t.size // args.structure[lvl]
        addr = t.startAddr-size
    return TableLvl (addr&mask, size)

if args.cap_size > 0:
    lvls = list( map (table_lvl, range(0,len(args.structure))))
else:
    lvls = [TableLvl(args.top_addr,0)]

###############################
# display computed parameters #
###############################

verboseprint("-"*80)
verboseprint("lvls = %s" % lvls)
verboseprint("last_addr = 0x%x" % (lvls[len(lvls)-1].startAddr-1))
verboseprint("tags_size = %d bytes" % (args.top_addr-lvls[len(lvls)-1].startAddr))

######################################################
# generate bluespec table configuration import file #
######################################################

if args.bsv_import_output:
    verboseprint("-"*80)
    verboseprint("generating Bluespec MultiLevelTagLookup module import configuration file %s" % args.bsv_import_output)
    f = open(args.bsv_import_output,'w')
    header = """/*-
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
"""
    header += "\n// This file was generated by the tagsparams.py script"
    header += "\n// %s\n\n" % str(datetime.now())
    decl = "Vector#(%d, Integer) tableStructure = " % len(args.structure)
    foldr = lambda func, acc, xs: functools.reduce(lambda x, y: func(y, x), xs[::-1], acc)
    structArray = foldr (lambda next, rest: "cons({:d}, {:s})".format(next,rest), "nil", args.structure)
    f.write(header)
    f.write("import Vector::*;\n");
    f.write(decl)
    f.write(structArray)
    f.write(";\n")
    f.write("Integer table_end_addr = 'h%x;\n" % args.top_addr)
    f.write("Integer table_start_addr = 'h%x;\n" % lvls[len(lvls)-1].startAddr)
    f.write("Integer covered_start_addr = 'h%x;\n" % args.covered_start_addr);
    f.write("Integer covered_mem_size  = 'h%x;\n" % args.covered_mem_size);
#    map(f.write,fill)

#######################################################
# generate ld script table configuration include file #
#######################################################

if args.linker_inc_output:
    verboseprint("-"*80)
    verboseprint("generating tags configuration linker include file %s" % args.linker_inc_output)
    f = open(args.linker_inc_output,'w')
    header = """/*-
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
"""
    header += "\n/* This file was generated by the tagsparams.py script */"
    header += "\n/* %s */\n\n" % str(datetime.now())
    decl = "__tags_table_size__ = 0x%x;" % (args.top_addr-lvls[len(lvls)-1].startAddr)
    f.write(header)
    f.write(decl)
