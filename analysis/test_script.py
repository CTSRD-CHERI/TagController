import trace_manager as tm
import run_experiments as ex
import log_consumer as lc
import request_sequences as rs

import gzip
import struct
import time
import sys


# c = lc.LogConsumer()

# with open("output.txt", "r") as f:
#     for line in f:
#         c.update(line)

# print(c.performance_str())
# exit(1)

##########################
# Manual Testing (OLD)
##########################
# s = tm.FullRequestSeq()
# for a in range(0, 16 * 128 * 2 + 1, 16):
#     s.add_write(a, a, 1, init=True)
#     s.add_read(a)
# s.add_write(1234, 1234, 1, init=True)
# s.add_write(0x4A00, 0x1EBC9, 1)
# s.add_write(0x80A10, 0x1EE0B, 1)
# s.add_write(0x200, 0x179D8, 1)
# s.add_write(0x84000, 0x179D8, 1)
# s.add_write(0x800, 0x179D8, 1)
# s.add_write(0x4800, 0x179D8, 1)
# s.add_read(0x4A00)


# leaf_pace = 1  # How many leaves to progress per op
# num_leaf_lines = 128  # How many entire leaf lines to read

# for a in range(0, 16 * 128 * num_leaf_lines, 16 * leaf_pace):
#     # s.add_write(a, a, 1)
#     s.add_read(a)

# s.add_write(0, 0, 1)
# s.add_write(16 * 128 * 256 + 1, 0, 1)
# s.add_write(16 * 128 * 0 + 12, 0, 1)
# s.add_read(0)
# s.add_read(16 * 128 * 0 + 12)
# s.add_read(16 * 128 * 256 + 1)
# with open("dramtraces/fromFile_input.dat", "w") as f:
#     print(s, file=f)
# exit(1)


##########################
# GZIP
##########################
# filename = "dramtraces/recordings/libquantum/trace_patched.gz"
# s = tm.GZIPRequestGenerator(filename)

# # # Run experiment
# e = ex.Experiment("testing", s)
# e.run()
# exit(1)


##########################
# CacheCore error when too many misses in a row
##########################
# s = tm.FullRequestSeq()
# s.add_read(0)
# s.add_read(128 * 128 * 16 * 4)
# s.add_read(2 * 128 * 128 * 16 * 4)
# print(s.__repr__())
# with open("dramtraces/fromFile_input.dat", "w") as f:
#     print(s, file=f)
# exit(1)


##########################
# Test each op type
##########################
s = tm.FullRequestSeq()
# r_add = rs.ReadAdder(s)
# s_add = rs.SetAdder(s)
# c_add = rs.ClearAdder(s)

## Read root hit
# [r_add.read_root_only(miss=False) for _ in range(100)]
## Read root miss
# [r_add.read_root_only(miss=True) for _ in range(100)]
## Read both hit hit 
# [r_add.read_both(r_miss=False,l_miss=False) for _ in range(100)]
## Read both hit miss
# [r_add.read_both(r_miss=False,l_miss=True) for _ in range(100)]
## Read both miss miss 
# [r_add.read_both(r_miss=True,l_miss=True) for _ in range(100)]

## Set both hit hit 
# [s_add.new_set(r_miss=False,l_miss=False) for _ in range(100)]
## Set both hit miss 
# [s_add.new_set(r_miss=False,l_miss=True) for _ in range(100)]
## Set Both miss miss 
# [s_add.new_set(r_miss=True,l_miss=True) for _ in range(100)]

## Clear root hit 
# [c_add.new_clear_root(miss=False) for _ in range(100)]
## Clear root miss 
# [c_add.new_clear_root(miss=True) for _ in range(100)]
## Clear both hit hit 
# [c_add.new_clear_both(r_miss=False,l_miss=False) for _ in range(100)]
## Clear both hit miss 
# [c_add.new_clear_both(r_miss=False,l_miss=True) for _ in range(100)]
## Clear Both miss miss 
# [c_add.new_clear_both(r_miss=True,l_miss=True) for _ in range(100)]

## Fold hit hit 
# [c_add.new_fold(r_miss=False,l_miss=False) for _ in range(100)]
## Fold hit miss 
# [c_add.new_fold(r_miss=False,l_miss=True) for _ in range(100)]
## Fold miss miss
# [c_add.new_fold(r_miss=True,l_miss=True) for _ in range(100)]


# r_add.read_both() # Try and ensure all the requests finish
s.add_write(0, 0xdead, 1,init=True)
s.add_write(16, 0xbeef, 1,init=True)
s.add_read(0)
print(s.__repr__())
with open("dramtraces/fromFile_input.dat", "w") as f:
    print(s, file=f)
e = ex.Experiment("each_op", s)
e.run()
exit(1)


##########################
# Fold correctness
##########################
# s = tm.FullRequestSeq()
# s.add_write(34, 34, 1,init=True)
# s.add_read(34)
# s.add_read(120)
# s.add_write(34, 43, 0)
# s.add_write(34, 43, 0)
# s.add_write(34, 43, 0)
# s.add_write(34, 43, 0)
# s.add_write(34, 43, 0)
# s.add_write(34, 43, 0)
# s.add_write(120, 34, 1)
# s.add_read(34)
# s.add_read(120)

# e = ex.Experiment("fold_correctness", s)
# e.run()
# exit(1)


##########################
# Miss overtaking
# ##########################
# s = tm.FullRequestSeq()
# r_add = rs.ReadAdder(s)

# [r_add.read_both()  for _ in range(1000)]
# r_add.read_both(r_miss=True)
# [r_add.read_both()  for _ in range(20)]

# print(s.__repr__())
# # e = ex.Experiment("miss_overtaking", s)
# e = ex.Experiment("third_reads", s)
# e.run()