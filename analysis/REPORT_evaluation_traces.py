import trace_manager as tm
import run_experiments as ex
import log_consumer as lc
import request_sequences as rs


def run_set(
    experiment_name,
    get_trace_manager,
    simulation_names=["starting", "incremental", "not_ooo", "final"],
):
    for sim in simulation_names:
        s = get_trace_manager()
        e = ex.Experiment(f"{sim}_{experiment_name}", s, sim)
        e.run()


##################
# Sequential reads
##################


def sequential_reads(l_stride=1, r_stride=0, n=100000, leaf_also=False):
    s = tm.FullRequestSeq()

    stride = 16  # bytes per capability
    stride *= l_stride

    stride += 128 * 16 * r_stride  # bytes per leaf line

    a = 0

    for i in range(n):
        s.add_read(a + i * stride)
        if leaf_also:
            s.add_write(a + i * stride, 0, 1, init=True)

    return s


## ALL DONE
# run_set("every_leaf", lambda : sequential_reads(1,0))
# run_set("every_root", lambda : sequential_reads(0,1))
# run_set("every_leaf_line", lambda : sequential_reads(512,0, n=1000))
# run_set("every_root_line", lambda : sequential_reads(0,512, n=1000))

## ALL DONE
# run_set("every_leaf_and_leaf", lambda : sequential_reads(1,0, leaf_also=True))
# run_set("every_root_and_leaf", lambda : sequential_reads(0,1, leaf_also=True))
# run_set("every_leaf_line_and_leaf", lambda : sequential_reads(512,0, n=1000, leaf_also=True))
# run_set("every_root_line_and_leaf", lambda : sequential_reads(0,512, n=1000, leaf_also=True))


##################
# Sequential writes
##################
def sequential_writes(l_stride=1, r_stride=0, n=10000, leaf_also=False):
    s = tm.FullRequestSeq()

    stride = 16  # bytes per capability
    stride *= l_stride

    stride += 128 * 16 * r_stride  # bytes per leaf line

    a = 0

    for i in range(n):
        if leaf_also:
            s.add_write(a + i * stride, 1)
            s.add_write(a + i * stride, 0, 1, init=True)
        else:
            s.add_write(a + i * stride, 0)

    return s


# # DONE
# run_set("write_every_leaf", lambda : sequential_reads(1,0))
# run_set("write_every_root", lambda : sequential_reads(0,1))
# run_set("write_every_leaf_line", lambda : sequential_reads(512,0, n=1000))
# run_set("write_every_root_line", lambda : sequential_reads(0,512, n=1000))

# # DONE
# run_set("write_every_leaf_and_leaf", lambda : sequential_reads(1,0, leaf_also=True))
# run_set("write_every_root_and_leaf", lambda : sequential_reads(0,1, leaf_also=True))
# run_set("write_every_leaf_line_and_leaf", lambda : sequential_reads(512,0, n=1000, leaf_also=True))
# run_set("write_every_root_line_and_leaf", lambda : sequential_reads(0,512, n=1000, leaf_also=True))

#####################
# Skipping leaf cache
#####################
def leaf_skipping(burst_size=1, n=10000):
    s = tm.FullRequestSeq()
    hit_a = 0

    next_miss = 512 * 16
    leaf_stride = 512 * 16

    for i in range(n):
        s.add_read(0)
        if i % 40 == 0:
            for _ in range(burst_size):
                s.add_read(next_miss)
            next_miss += leaf_stride

    return s


# DONE
# run_set("overtaking_leaf_single", lambda : leaf_skipping(1), simulation_names=["not_ooo", "final"])
# run_set("overtaking_leaf_ten", lambda : leaf_skipping(10), simulation_names=["not_ooo", "final"])

#####################
# Non blocking miss
#####################
def non_blocking(burst_size=1, n=1000):
    s = tm.FullRequestSeq()
    hit_a = 0

    next_miss = 512*128*16
    root_stride = 512*128*16

    for i in range(n):
        s.add_read(0)
        if i % 40 == 0:
            for _ in range(burst_size):
                s.add_read(next_miss)
            next_miss += root_stride

    return s


# DONE
# run_set("non_blocking_single", lambda : non_blocking(1), simulation_names=["not_ooo", "final"])
# run_set("non_blocking_four", lambda : non_blocking(4), simulation_names=["not_ooo", "final"])
