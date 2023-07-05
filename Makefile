#-
# Copyright (c) 2018-2022 Alexandre Joannou
# Copyright (c) 2018 Matthew Naylor
# Copyright (c) 2018 Jonathan Woodruff
# All rights reserved.
#
# This software was developed by SRI International and the University of
# Cambridge Computer Laboratory (Department of Computer Science and
# Technology) under DARPA contract HR0011-18-C-0016 ("ECATS"), as part of the
# DARPA SSITH research programme.
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

BSC = nice -n 19 bsc
BLUESTUFFDIR ?= $(CURDIR)/BlueStuff
BLUEAXI4DIR = $(BLUESTUFFDIR)/BlueAXI4
BLUEAXI4DIRS = $(BLUEAXI4DIR):$(BLUEAXI4DIR)/AXI4:$(BLUEAXI4DIR)/AXI4Lite:$(BLUEAXI4DIR)/AXI4Stream:$(BLUEAXI4DIR)/BlueUnixBridges
BLUEBASICSDIR = $(BLUESTUFFDIR)/BlueBasics
BLUEUTILSDIR = $(BLUESTUFFDIR)/BlueUtils
BLUESTUFF_DIRS = $(BLUESTUFFDIR):$(BLUEAXI4DIRS):$(BLUEBASICSDIR):$(BLUEUTILSDIR):$(BLUESTUFFDIR)/Stratix10ChipID

BSVPATH = +:$(BLUESTUFF_DIRS):Test:Test/bluecheck:TagController:TagController/CacheCore:Benchmark:$(CURDIR)/../../src_Core/Core/:$(CURDIR)/../../src_Core/ISA/:$(CURDIR)/../cheri-cap-lib/

BSCFLAGS = -p $(BSVPATH) -D MEM512 -D CAP128 -D BLUESIM
CAPSIZE = 128
TAGS_STRUCT = 0 128
TAGS_ALIGN = 16

# generated files directories
BUILDDIR = build
BDIR = $(BUILDDIR)/bdir
SIMDIR = $(BUILDDIR)/simdir

OUTPUTDIR = output

BSCFLAGS += -bdir $(BDIR)
BSCFLAGS += -simdir $(SIMDIR)

BSCFLAGS += -show-schedule
BSCFLAGS += -sched-dot
BSCFLAGS += -show-range-conflict
#BSCFLAGS += -show-rule-rel \* \*
#BSCFLAGS += -steps-warn-interval n
BSCFLAGS += -D CheriMasterIDWidth=3
BSCFLAGS += -D CheriTransactionIDWidth=5
BSCFLAGS += -D BenchmarkIDWidth=4 # Must be less than or equal to CheriTransactionIDWidth
# BSCFLAGS += +RTS -K33554432 -RTS
BSCFLAGS += +RTS -K512M -RTS
BSCFLAGS += -suppress-warnings T0127:S0080 # no orphan typeclass warning
BSCFLAGS += -D TAGCONTROLLER_BENCHMARKING

TESTSDIR = Test
SIMTESTSSRC = $(sort $(wildcard $(TESTSDIR)/*.bsv))
SIMTESTS = $(addprefix sim, $(notdir $(basename $(SIMTESTSSRC))))

BENCHMARKDIR = Benchmark

all: simTest


SIMTEST_TOPMODULE = mkTestMemTop
simTest: $(TESTSDIR)/TestMemTop.bsv TagController/TagTableStructure.bsv
	mkdir -p $(OUTPUTDIR)/$@-info $(BDIR) $(SIMDIR)
	$(BSC) -info-dir $(OUTPUTDIR)/$@-info -simdir $(SIMDIR) $(BSCFLAGS) -sim -g $(SIMTEST_TOPMODULE)  -steps-max-intervals 100000000 -u $<
	CC=$(CC) CXX=$(CXX) $(BSC) -simdir $(SIMDIR) $(BSCFLAGS) -sim -e $(SIMTEST_TOPMODULE) -o $(OUTPUTDIR)/$@

TOFILE_TOPMODULE = mkWriteTest
tofile: $(BENCHMARKDIR)/RunRequestsFromFile.bsv TagController/TagTableStructure.bsv
	mkdir -p $(OUTPUTDIR)/$@-info $(BDIR) $(SIMDIR)
	$(BSC) -info-dir $(OUTPUTDIR)/$@-info -simdir $(SIMDIR) $(BSCFLAGS) -sim -g $(TOFILE_TOPMODULE) -u $<
	CC=$(CC) CXX=$(CXX) $(BSC) -simdir $(SIMDIR) $(BSCFLAGS) -sim -e $(TOFILE_TOPMODULE) -o $(OUTPUTDIR)/$@


FROMFILE_TOPMODULE = mkRequestsFromFile
fromfile: $(BENCHMARKDIR)/RunRequestsFromFile.bsv TagController/TagTableStructure.bsv
	mkdir -p $(OUTPUTDIR)/$@-info $(BDIR) $(SIMDIR)
	$(BSC) -info-dir $(OUTPUTDIR)/$@-info -simdir $(SIMDIR) $(BSCFLAGS) -sim -g $(FROMFILE_TOPMODULE) -u $<
	CC=$(CC) CXX=$(CXX) $(BSC) -simdir $(SIMDIR) $(BSCFLAGS) -sim -e $(FROMFILE_TOPMODULE) -o $(OUTPUTDIR)/$@

fromfilegraphs: $(OUTPUTDIR)/fromfile-info/mkTagController_combined_full.dot  $(OUTPUTDIR)/fromfile-info/mkTagController_combined.dot $(OUTPUTDIR)/fromfile-info/mkTagController_conflict.dot $(OUTPUTDIR)/fromfile-info/mkTagController_exec.dot $(OUTPUTDIR)/fromfile-info/mkTagController_urgency.dot
	dot -Tpdf $(OUTPUTDIR)/fromfile-info/mkTagController_combined_full.dot -o $(OUTPUTDIR)/fromfile-info/mkTagController_combined_full.pdf
	dot -Tpdf $(OUTPUTDIR)/fromfile-info/mkTagController_combined.dot -o $(OUTPUTDIR)/fromfile-info/mkTagController_combined.pdf
	dot -Tpdf $(OUTPUTDIR)/fromfile-info/mkTagController_conflict.dot -o $(OUTPUTDIR)/fromfile-info/mkTagController_conflict.pdf
	dot -Tpdf $(OUTPUTDIR)/fromfile-info/mkTagController_exec.dot -o $(OUTPUTDIR)/fromfile-info/mkTagController_exec.pdf
	dot -Tpdf $(OUTPUTDIR)/fromfile-info/mkTagController_urgency.dot -o $(OUTPUTDIR)/fromfile-info/mkTagController_urgency.pdf


TagController/TagTableStructure.bsv: $(CURDIR)/tagsparams.py
	@echo "INFO: Re-generating CHERI tag controller parameters"
	$^ -v -c $(CAPSIZE) -s $(TAGS_STRUCT:"%"=%) -a $(TAGS_ALIGN) --data-store-base-addr 0x00000000 -b $@ 0xbfff8000 0x17ffff000
	@echo "INFO: Re-generated CHERI tag controller parameters"


.PHONY: clean mrproper all

clean:
	rm -f .simTests
	rm -f -r $(BUILDDIR)
	rm -f TagController/TagTableStructure.bsv

mrproper: clean
	rm -f -r $(OUTPUTDIR)
