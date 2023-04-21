import numpy as np
import re

# Regex used to search line for information

re_timestamp = "^<time ([0-9]*)"
re_id = "> ('h[0-9a-f]*)"
re_starting = "> Switching to main tag controller!"

re_new_read = "sent to tag controller \| read"
re_new_clear = "sent to tag controller \| write \| 'h0"
re_new_set = "sent to tag controller \| write \| 'h1"

re_tc_return = "return from tag controller"

re_tl_sent = "sent to tag lookup"
re_tl_return = "return from tag lookup"

re_start_leaf = "start LEAF"
re_no_leaf = "NO LEAF"

re_is_folding = "FOLDING"
re_not_folding = "NO FOLD"

re_sent_ignored = "IGNORED"


class Record:
    def __init__(self, req_dur, look_dur, num_tag_ops, need_leaf, folding=False):
        self.req_dur = req_dur // 10
        self.look_dur = look_dur // 10

        self.num_tag_ops = num_tag_ops

        self.need_leaf = need_leaf
        self.folding = folding

    def __repr__(self):
        return (
            f"request: {self.req_dur: >4} | "
            + f"lookup: {self.look_dur: >4} | "
            + f"tag ops: {self.num_tag_ops} | "
            + f"used leaf: {self.need_leaf:1} | "
            + f"did folding: {self.folding:1}"
        )

    def __str__(self):
        return self.__repr__()


class LogConsumer:
    def __init__(self, pipelined=False):
        # Arrays of Record objects
        self.reads = []
        self.sets = []
        self.clears = []

        # id -> (type, objects)
        self.active_ids = {}

        # Request end times (for throughput)
        self.start_time = 0
        self.end_times = []
        self.total_tag_lookups = 0

        self.pipelined = pipelined

    # Update records as instructed by new log line
    def update(self, line):
        time = int(re.findall(re_timestamp, line)[0])
        id_found = re.findall(re_id, line)
        if id_found:
            id = id_found[0]
        else:
            if re.search(re_starting, line):
                self.start_time = time
            return

        # Is this a new requests
        if id not in self.active_ids.keys():
            if re.search(re_new_read, line):
                # print(f"New read: {id}")
                record = type("", (), {})()

                record.tc_start = time
                record.type = "READ"
                record.need_leaf = True

                self.active_ids[id] = record
                return
            if re.search(re_new_set, line):
                # print(f"New set {id}")
                record = type("", (), {})()

                record.tc_start = time
                record.type = "SET"
                record.seen_leaf = False
                record.returned = False

                self.active_ids[id] = record
                return
            if re.search(re_new_clear, line):
                # print(f"New clear {id}")
                record = type("", (), {})()

                record.tc_start = time
                record.type = "CLEAR"
                record.seen_leaf = False
                record.returned = False
                record.seen_folding = False

                self.active_ids[id] = record
                return
            else:
                # id no longer active (e.g. pending writes)
                return

        record = self.active_ids[id]

        # Is this the request returning
        if re.search(re_tc_return, line):
            # print(f"{id} RETURNED")
            record.tc_end = time
            record.tc_dur = record.tc_end - record.tc_start
            record.returned = True

            self.end_times.append(time)

            if record.type == "READ":
                # print(f"Read done: {id}")

                num_tag_ops = 2 if record.need_leaf else 1
                self.reads.append(
                    Record(
                        req_dur=record.tc_dur,
                        look_dur=record.tl_dur,
                        num_tag_ops=num_tag_ops,
                        need_leaf=record.need_leaf,
                    )
                )
                self.total_tag_lookups += num_tag_ops
                self.active_ids.pop(id)
                return

        # Should we set need_leaf to False
        if re.search(re_no_leaf, line):
            record.need_leaf = False
            record.seen_leaf = True
            record.folding = False
            record.seen_folding = True

        # Should we set need_leaf to True
        if re.search(re_start_leaf, line):
            record.need_leaf = True
            record.seen_leaf = True

        # Should we set folding to False
        if re.search(re_not_folding, line):
            record.folding = False
            record.seen_folding = True

        # Should we set folding to True
        if re.search(re_is_folding, line):
            record.folding = True
            record.seen_folding = True

        # If tag controller has returned and we know value of need_leaf then
        # can stop tracking this id
        if record.type == "SET":
            if record.returned and record.seen_leaf:
                # print(f"Set done: {id}")

                num_tag_ops = 2 if record.need_leaf else 1
                self.sets.append(
                    Record(
                        req_dur=record.tc_dur,
                        look_dur=0,
                        num_tag_ops=num_tag_ops,
                        need_leaf=record.need_leaf,
                    )
                )
                self.total_tag_lookups += num_tag_ops
                self.active_ids.pop(id)
                return

        # For clear operations also need to know whether they trigger a fold
        if record.type == "CLEAR":
            if record.returned and record.seen_leaf and record.seen_folding:
                # print(f"Clear done: {id}")

                if self.pipelined:
                    if record.folding:
                        num_tag_ops = 3
                    else:
                        num_tag_ops = 2 if record.need_leaf else 1
                else:
                    if record.folding:
                        num_tag_ops = 4
                    else:
                        num_tag_ops = 3 if record.need_leaf else 1

                self.clears.append(
                    Record(
                        req_dur=record.tc_dur,
                        look_dur=0,
                        num_tag_ops=num_tag_ops,
                        need_leaf=record.need_leaf,
                        folding=record.folding,
                    )
                )
                self.total_tag_lookups += num_tag_ops
                self.active_ids.pop(id)
                return

        # When did the request get sent to the tag lookup
        if re.search(re_tl_sent, line):
            record.tl_sent = time

        # When did the request return from the tag lookup
        if re.search(re_tl_return, line):
            record.tl_return = time
            record.tl_dur = record.tl_return - record.tl_sent

    def performance_str(self):
        start = self.start_time
        end = self.end_times[-1]
        duration = (end - start) // 10
        requests = len(self.end_times)

        num_tag_ops = self.total_tag_lookups
        ops_per_request = num_tag_ops / requests
        tag_op_throughput = num_tag_ops / duration

        cycles_per_req = duration / requests
        throughput = requests / duration
        return (
            f"Performance:\n"
            # + f" Start time: {start}\n"
            # + f" End time:   {end}\n"
            + f" Duration:   {duration}\n"
            + f" \n"
            + f" Requests:   {requests}\n"
            + f" Cycles per request: {cycles_per_req}\n"
            + f" Requests per cycle: {throughput}\n"
            + f" \n"
            + f" Cache ops:  {num_tag_ops}\n"
            + f" Cache ops per request: {ops_per_request}\n"
            + f" Cache ops per cycle:   {tag_op_throughput}\n"
        )

    def __repr__(self):
        repr_string = "Reading tag:\n"
        for r in self.reads:
            repr_string += f"  {r}\n"

        repr_string += "Setting tag:\n"
        for r in self.sets:
            repr_string += f"  {r}\n"

        repr_string += "Clearing tag:\n"
        for r in self.clears:
            repr_string += f"  {r}\n"

        repr_string += "Never finished:\n"
        for (id, obj) in self.active_ids.items():
            repr_string += f"  {id}: {obj.__dict__}\n"

        repr_string += self.performance_str()

        return repr_string

    def __str__(self):
        return self.__repr__()
