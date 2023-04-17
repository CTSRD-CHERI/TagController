import asyncio
import gzip
import struct

READ = 0
WRITE = 1
END_INIT = 2
TERMINATE = 3

# # Format for struct.unpack to use with gzip traces
# struct trace_entry_t      # 24 bytes per operation
# {
#     uint8_t type;         # 1 byte "b"
#     uint8_t tag;          # 1 byte "b"
#     uint16_t size;        # 2 bytes "h"
#                           # 4 bytes padding "xxxx"
#     uintptr_t vaddr;      # 4 bytes "I" (only want bottom 32 bits)
#                           # 4 bytes padding "xxxx"
#     uintptr_t paddr;      # 4 bytes "I" (only want bottom 32 bits)
#                           # 4 bytes padding "xxxx"
# };
# Files were given to me in little endian format "<"
STRUCT_FORMAT = "<bbhxxxxIxxxxIxxxx"

MAX_PADDR = 16**7 - 1  # Ignore top nibble to prevent clashing with tag table


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


class RequestGenerator:
    """
    Class with ops_iterator() function that yields MemoryOp objects
    """

    def ops_iterator(self):
        yield (MemoryOp(END_INIT))
        yield (MemoryOp(TERMINATE))


class FullRequestSeq(RequestGenerator):
    """
    Full DRAM request trace including initialising writes

    __str__() gives the format expected by benchmarking tool
    """

    def __init__(self):
        self.init_reqs = []
        self.main_reqs = []

        self.switching_op = MemoryOp(
            END_INIT,
            address=0xDEADBEEF,
            data=0x00AAAA0000AAAA0000AAAA00FEEBDAED,
            tags=0x20,
        )

        self.terminate_op = MemoryOp(
            TERMINATE,
            address=0xDEADDEAD,
            data=0x00BBBB0000BBBB0000BBBB00DEADDEADD,
            tags=0x30,
        )

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

    def ops_iterator(self):
        for r in self.init_reqs:
            yield r

        yield self.switching_op

        for r in self.main_reqs:
            yield r

        yield self.terminate_op

    def __repr__(self):
        init_reqs_str = ""
        main_reqs_str = ""
        for i, r in enumerate(self.init_reqs):
            init_reqs_str += f"  {i}: {r.__repr__()}\n"
        for i, r in enumerate(self.main_reqs):
            main_reqs_str += f"  {i}: {r.__repr__()}\n"
        return "" + "Init reqs:\n" + init_reqs_str + "Main reqs:\n" + main_reqs_str

    def __str__(self):
        output_string = ""
        for op in self.ops_iterator():
            output_string += op.__str__()
        return output_string


class GZIPRequestGenerator(RequestGenerator):
    """
    Extracts requests from gzipped trace file
    """

    def __init__(self, input_file):
        self.input_file = input_file

    def __repr__(self):
        return f"GZIPRequestGenerator({self.input_file})"

    def ops_iterator(self):
        yield MemoryOp(END_INIT)

        with gzip.open(self.input_file, "rb") as f:
            for _ in range(1000000):
                op = f.read(24)
                (op_type, tags, size, vaddr, paddr) = struct.unpack(STRUCT_FORMAT, op)
                # print(
                #     (
                #         f"type: {op_type:0>2x}, "
                #         + f"tags: {tags:0>8b}, "
                #         + f"size: {size}, "
                #         + f"vaddr: {vaddr:0>8x}, "
                #         + f"paddr: {paddr:0>8x}"
                #     )
                # )

                ## TRANSLATE op_type to READ or WRITE
                # enum trace_entry_type_t
                # {
                #     TRACE_ENTRY_TYPE_INSTR, //instruction load
                #     TRACE_ENTRY_TYPE_LOAD,
                #     TRACE_ENTRY_TYPE_STORE,
                #     TRACE_ENTRY_TYPE_CLOAD,  //capability load
                #     TRACE_ENTRY_TYPE_CSTORE, //capability store
                # };
                is_store = op_type == 2 or op_type == 4

                trunc_paddr = paddr & MAX_PADDR
                if tags > 1:
                    print("TAGS TOO LARGE")
                    exit(1)
                my_op = MemoryOp(
                    WRITE if is_store else READ,
                    address=trunc_paddr,
                    data=paddr,
                    tags=tags,
                )
                # print(f" -> {my_op.__repr__()}")
                yield my_op

        yield MemoryOp(TERMINATE)
