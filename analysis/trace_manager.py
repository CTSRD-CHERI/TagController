READ = 0
WRITE = 1
END_INIT = 2


class MemoryOp:
    """
    Single memory operation

    __str__() gives the format expected by benchmarking tool
    """

    def __init__(self, op_type, address=0, data=0, tags=0):
        self.op_type = op_type
        self.address = address
        self.data = data
        self.tags = tags

    def __repr__(self):
        return (
            f"MemoryOp("
            + f"op_type: {self.op_type},"
            + f"address: {self.address:0>8x},"
            + f"data: {self.data:0>32x},"
            + f"tags: {self.tags:b}"
            + ")"
        )

    def __str__(self):
        return (
            ""
            + f"{self.op_type:0>2x}"  # 8 bits
            + f"{self.address:0>8x}"  # 32 bits
            + f"{self.data:0>32x}"  # 128 bits
            + f"{self.tags:0>2x}"  # 8 bits
        )


class RequestSeq:
    """
    Full DRAM request trace including initialising writes

    __str__() gives the format expected by benchmarking tool
    """

    def __init__(self):
        self.init_reqs = []
        self.main_reqs = []

    def add_read(self, address, init=False):
        read_op = MemoryOp(READ, address)
        if init:
            self.init_reqs += [read_op]
        else:
            self.main_reqs += [read_op]

    def add_write(self, address, data, tag, init=False):
        write_op = MemoryOp(WRITE, address, data, tag)
        if init:
            self.init_reqs += [write_op]
        else:
            self.main_reqs += [write_op]

    def __repr__(self):
        init_reqs_str = ""
        main_reqs_str = ""
        for i, r in enumerate(self.init_reqs):
            init_reqs_str += f"  {i}: {r.__repr__()}\n"
        for i, r in enumerate(self.main_reqs):
            main_reqs_str += f"  {i}: {r.__repr__()}\n"
        return "" + "Init reqs:\n" + init_reqs_str + "Main reqs:\n" + main_reqs_str

    def __str__(self):
        init_output_string = ""
        for r in self.init_reqs:
            init_output_string += r.__str__()

        # Noticeable string so it stands out as special operation
        switching_op = MemoryOp(
            END_INIT,
            address=0xDEADBEEF,
            data=0x00AAAA0000AAAA0000AAAA00FEEBDAED,
            tags=0x20,
        )
        switching_output_string = f"{switching_op}"

        main_output_string = ""
        for r in self.main_reqs:
            main_output_string += r.__str__()

        return init_output_string + switching_output_string + main_output_string
