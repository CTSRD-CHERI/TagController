import trace_manager as tm
import asyncio

REQUEST_FILE = "dramtraces/fromFile_input.dat"
REQUEST_PIPE = "dramtraces/fromFile_input.pipe"

FLUSH_PERIOD = 1000


class Experiment:
    def __init__(self, name, request_generator, design="default"):
        self.name = name
        self.request_generator = request_generator
        self.design = design

    async def _run_fromfile(self, log_file):
        print("Starting process")
        fromfile_process = await asyncio.create_subprocess_exec(
            "python",
            "analysis/run_and_consume.py",
            f"{self.name}",
            f"{self.design}",
            stdout=log_file,
        )

        print("Starting to print to pipe")
        with open(REQUEST_PIPE, "w") as f:
            for i, op in enumerate(self.request_generator.ops_iterator()):
                # await asyncio.sleep(1)
                # print(f"Sending {op.__repr__()} to pipe")
                print(op, end="", file=f)
                if (i + 1) % FLUSH_PERIOD == 0:
                    f.flush()
                    log_file.flush()
                    print(f"Instructions sent: {i}")

        print("Waiting for process to end")
        await fromfile_process.wait()

    def run(self):
        with open(f"Logs/experiments/{self.name}.log", "w") as log_file:
            asyncio.run(self._run_fromfile(log_file))
