import re
import numpy as np
import matplotlib.pyplot as plt

sent_to_tag_controller = r"^<time ([0-9]*) Benchmark> Sending Load: AXI4_ARFlit { arid: 'h([0-9a-f]+), araddr: 'h([0-9a-f]+)"
response_from_tag_controller = r"^<time ([0-9]*) Benchmark> Read response received: AXI4_RFlit { rid: 'h([0-9a-f]+), rdata: 'h([0-9a-f]+), rresp: ([A-z0-9]*), rlast: ([A-x]*), ruser: 'h([0-9a-f]+) }"


# filename = "Logs/testing/nullcontroller.txt"
# filename = "Logs/testing/nulllookups.txt"
filename = "Logs/testing/all_1000.txt"

# Create list of  [timestamp, ID, address] for sent loads
# ordered by ID and then timestamp
sending_logs = [re.findall(sent_to_tag_controller, line) for line in open(filename)]
sending_logs = [
    [int(x[0][0], 10), int(x[0][1], 16), int(x[0][2], 16)]
    for x in sending_logs
    if x != []
]
sending_logs = sorted(sending_logs, key=lambda x: (x[1], x[0]))

# Create list of [timestamp, ID, data, rresp, rlast, tags] for read responses
# ordered by ID and then timestamp
response_logs = [
    re.findall(response_from_tag_controller, line) for line in open(filename)
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
print(request_durations)

latency = np.array([x[1] - x[0] for x in request_durations[2:]])

# print([l for l in latency])
sending_times = np.array([x[0] for x in request_durations])
response_times = np.array([x[1] for x in request_durations])

plt.scatter(sending_times, response_times - sending_times)
# plt.hist(latency)
plt.savefig("fig.png")
