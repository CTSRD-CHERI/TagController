import re
import numpy as np
import matplotlib.pyplot as plt

sent_to_tag_controller = r"^<time ([0-9]*) Benchmark> Sending Load: AXI4_ARFlit { arid: 'h([0-9a-f]+), araddr: 'h([0-9a-f]+)"
response_from_tag_controller = r"^<time ([0-9]*) Benchmark> Read response received: AXI4_RFlit { rid: 'h([0-9a-f]+), rdata: 'h([0-9a-f]+), rresp: ([A-z0-9]*), rlast: ([A-x]*), ruser: 'h([0-9a-f]+) }"


def get_request_periods(log_file):

    # Create list of  [timestamp, ID, address] for sent loads
    # ordered by ID and then timestamp
    sending_logs = [re.findall(sent_to_tag_controller, line) for line in open(log_file)]
    sending_logs = [
        [int(x[0][0], 10), int(x[0][1], 16), int(x[0][2], 16)]
        for x in sending_logs
        if x != []
    ]
    sending_logs = sorted(sending_logs, key=lambda x: (x[1], x[0]))

    # Create list of [timestamp, ID, data, rresp, rlast, tags] for read responses
    # ordered by ID and then timestamp
    response_logs = [
        re.findall(response_from_tag_controller, line) for line in open(log_file)
    ]
    response_logs = [
        [
            int(x[0][0], 10),
            int(x[0][1], 16),
            int(x[0][2], 16),
            x[0][3],
            bool(x[0][4]),
            x[0][5],
        ]
        for x in response_logs
        if x != []
    ]
    response_logs = sorted(response_logs, key=lambda x: (x[1], x[0]))

    request_durations = []
    for a, b in zip(sending_logs, response_logs):
        request_durations += [[a[0], b[0]]]

    request_durations = sorted(request_durations, key=lambda x: x[0])
    return request_durations


def progress_through_time(request_durations):
    # sending_times = np.array([x[0] for x in request_durations])
    response_times = np.array([x[1] for x in request_durations])
    print(len(response_times))

    time_steps = np.arange(0, response_times[-1] / 10 + 1)

    # sent_at_time = np.count_nonzero(
    # sending_times <= np.expand_dims(time_steps, axis=1), axis=1
    # )
    responded_at_time = np.count_nonzero(
        response_times <= np.expand_dims(10 * time_steps, axis=1), axis=1
    )

    return time_steps, responded_at_time


def plot_progress(request_durations, colour, label):
    times, responded = progress_through_time(request_durations)
    # plt.plot(times, sent, label=f"{label}: sent", color=colour, linestyle="--")
    plt.plot(times, responded, label=f"{label}", color=colour, linestyle="-")


## READ FILES
null_controller = get_request_periods("Logs/testing/nullcontroller.txt")
null_lookups = get_request_periods("Logs/testing/nulllookups.txt")
original_controller = get_request_periods("Logs/testing/all_1000.txt")
bypass_tagcachereq = get_request_periods("Logs/testing/1000_bypass_tagcachereq.txt")
response_and_lookup = get_request_periods("Logs/testing/full_cache_throughput.txt")

## PLOT ON GRAPH
# plot_progress(null_controller, "tab:blue", "Skip tag controller")
plot_progress(null_lookups, "tab:blue", "Skip tag lookups")
plot_progress(original_controller, "tab:orange", "Base controller")
plot_progress(bypass_tagcachereq, "tab:green", "Bypass TagCacheReq")
plot_progress(response_and_lookup, "tab:red", "One cycle tag lookups")

## DECORATE AND SAVE GRAPH
plt.xlabel("Number of clock cycles")
plt.ylabel("Memory reads completed")
plt.legend()
plt.savefig("all_throughputs.png")


# print(response_and_lookup)

# latency = np.array([x[1] - x[0] for x in request_durations[2:]])

# # print([l for l in latency])
# sending_times = np.array([x[0] for x in request_durations])
# response_times = np.array([x[1] for x in request_durations])

# plt.scatter(sending_times, response_times - sending_times)
# # plt.hist(latency)


# plt.savefig("fig.png")
