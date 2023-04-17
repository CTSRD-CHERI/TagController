## DO NOT RUN THIS FILE!!
## This is used by run_experiments.py to runt he benchmarking tool
## in a subprocess and consume the output as it appears

import sys
import asyncio
import log_consumer as logcon


# Not used at the moment
experiment_name = sys.argv[1]

log_consumer = logcon.LogConsumer()


async def main_loop():
    fromfile_process = await asyncio.create_subprocess_exec(
        f"output/fromfile",
        "+tracing",
        "+pipe",
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

# Seems to be needed!!
exit(0)
