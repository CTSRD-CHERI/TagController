from . import trace_manager as tm
import os

REQUEST_FILE = "dramtraces/fromFile_input.dat"


class Experiment:
    def __init__(self, name, request_sequence):
        self.name = name
        self.request_sequence = request_sequence

    def run(self):
        with open(REQUEST_FILE, "w") as f:
            print(self.request_sequence, file=f)
        os.system(f"output/fromfile +benchmark > Logs/experiments/{self.name}.log")
