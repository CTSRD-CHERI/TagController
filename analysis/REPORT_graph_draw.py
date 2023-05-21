import numpy as np 
import matplotlib.pyplot as plt

def times_and_counts(end_times):
    # sending_times = np.array([x[0] for x in request_durations])
    num_resps = len(end_times)
    print(num_resps)

    responded_at_time = np.arange(num_resps)

    return (end_times-end_times[0])/10, responded_at_time


def plot_progress(ax, filename, colour, label):
    # with np.load(filename) as end_times:
    end_times = np.load(filename)
    print(end_times[-10:])
    times, counts = times_and_counts(end_times)
    print((times,counts))
    ax.plot(times, counts, label=f"{label}", color=colour, linestyle="-")

fig,ax = plt.subplots(figsize=(8,8))
## PLOT ON GRAPH
# plot_progress(null_controller, "tab:blue", "Skip tag controller")
# plot_progress(null_lookups, "tab:blue", "Skip tag lookups")
# plot_progress(original_controller, "tab:orange", "Base controller")
# plot_progress(bypass_tagcachereq, "tab:green", "Bypass TagCacheReq")
# plot_progress(response_and_lookup, "tab:red", "One cycle tag lookups")
plot_progress(ax, "Logs/end_times/experiment_name.npy", "tab:red", "Not ooo gzip")

ax.plot(ax.get_xlim(),ax.get_ylim(), ls="--",c=".3", label="1 request per cycle")
## DECORATE AND SAVE GRAPH
plt.xlabel("Number of clock cycles")
plt.ylabel("Memory reads completed")
plt.legend()

plt.savefig("Logs/figures/Gzip.png")

