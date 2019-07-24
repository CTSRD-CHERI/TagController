#-
# Copyright (c) 2018 Alexandre Joannou
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

BSC = bsc

BLUEUTILSDIR = ./BlueStuff
BSVPATH = +:BlueStuff:Test:Test/bluecheck:BlueStuff/BlueBasics:BlueStuff/BlueUtils:BlueStuff/AXI:TagController:TagController/CacheCore

BSCFLAGS = -p $(BSVPATH) -D MEM128 -D CAP128 -D BLUESIM
CAPSIZE = 128
TAGS_STRUCT = 0 128
TAGS_ALIGN = 16

# generated files directories
BUILDDIR = build
BDIR = $(BUILDDIR)/bdir
SIMDIR = $(BUILDDIR)/simdir

OUTPUTDIR = output
TOPMODULE = mkTestMemTop

BSCFLAGS += -bdir $(BDIR)
BSCFLAGS += -simdir $(SIMDIR)

BSCFLAGS += -show-schedule
BSCFLAGS += -sched-dot
BSCFLAGS += -show-range-conflict
#BSCFLAGS += -show-rule-rel \* \*
#BSCFLAGS += -steps-warn-interval n

# Bluespec is not compatible with gcc > 4.9
# This is actually problematic when using $test$plusargs
CC = gcc-4.8
CXX = g++-4.8

TESTSDIR = Test
SIMTESTSSRC = $(sort $(wildcard $(TESTSDIR)/*.bsv))
SIMTESTS = $(addprefix sim, $(notdir $(basename $(SIMTESTSSRC))))

all: simTest

simTest: $(TESTSDIR)/TestMemTop.bsv TagController/TagTableStructure.bsv
	mkdir -p $(OUTPUTDIR)/$@-info $(BDIR) $(SIMDIR)
	$(BSC) -info-dir $(OUTPUTDIR)/$@-info -simdir $(SIMDIR) $(BSCFLAGS) -sim -g $(TOPMODULE) -u $<
	CC=$(CC) CXX=$(CXX) $(BSC) -simdir $(SIMDIR) $(BSCFLAGS) -sim -e $(TOPMODULE) -o $(OUTPUTDIR)/$@
	
TagController/TagTableStructure.bsv: tagsparams.py
	python $^ -v -c $(CAPSIZE) -s $(TAGS_STRUCT:"%"=%) -a $(TAGS_ALIGN) -b TagController/TagTableStructure.bsv


.PHONY: clean mrproper all

clean:
	rm -f .simTests
	rm -f -r $(BUILDDIR)
	rm -f TagController/TagTableStructure.bsv

mrproper: clean
	rm -f -r $(OUTPUTDIR)
