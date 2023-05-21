## DO NOT RUN THIS FILE!!
## This is used by run_experiments.py to runt he benchmarking tool
## in a subprocess and consume the output as it appears

import sys
import asyncio
import log_consumer as logcon


# SIMULATION = f"output/STARTING/fromfile"
# SIMULATION = f"output/INCREMENTAL/fromfile"
# SIMULATION = f"output/NOT_OOO/fromfile"
# SIMULATION = f"output/FINAL/fromfile"
SIMULATION = f"output/fromfile"

# Not used at the moment
experiment_name = sys.argv[1]

log_consumer = logcon.LogConsumer(pipelined=True)

async def main_loop():
    fromfile_process = await asyncio.create_subprocess_exec(
        SIMULATION,
        "+tracing",
        "+pipe",
        # "+taglookup",
        # "+tagcontroller",
        # "+AXItagcontroller",
        # "+CacheCore",
        # "+corderer",
        # "+cache1",
        # "+cache2",
        # "+cache3",
        # "+benchmark",
        # "+dram",
        # "+AXItagwriter",
        # "+merge",
        stdout=asyncio.subprocess.PIPE,
    )

    while True:
        line = await fromfile_process.stdout.readline()
        if line:
            ## Prints to experiment log file
            # print(line.decode("utf-8"), end="")

            log_consumer.update(line.decode("utf-8"))
        else:
            break

    await fromfile_process.wait()


asyncio.run(main_loop())

# Prints to experiment log file
print(log_consumer.performance_str())
print(log_consumer)
log_consumer.save_end_times(f"Logs/end_times/{experiment_name}")

# Seems to be needed!!
exit(0)
