import trace_manager as tm
import run_experiments as ex

import gzip
import struct
import time
import sys


# # Manual Testing
# s = tm.FullRequestSeq()
# for a in range(0, 16 * 128 * 2 + 1, 16):
#     s.add_write(a, a, 1, init=True)
#     s.add_read(a)
# # s.add_write(1234, 1234, 1, init=True)
# # s.add_read(1234)
# # s.add_read(1235)

# # GZIP
filename = "dramtraces/recordings/libquantum/trace_patched.gz"
s = tm.GZIPRequestGenerator(filename)

# # Run experiment
e = ex.Experiment("testing", s)
e.run()
