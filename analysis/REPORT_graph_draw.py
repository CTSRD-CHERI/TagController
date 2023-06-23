import numpy as np
import matplotlib.pyplot as plt


def times_and_counts(end_times):
    # sending_times = np.array([x[0] for x in request_durations])
    num_resps = len(end_times)
    responded_at_time = np.arange(num_resps)
    return (end_times - end_times[0]) / 10, responded_at_time


def plot_progress(ax, filename, colour, label):
    # with np.load(filename) as end_times:
    end_times = np.load(filename)
    times, counts = times_and_counts(end_times)
    ax.plot(times, counts, label=f"{label}", color=colour, linestyle="-")
    return counts[-1]/times[-1]


def plot_all(
    experiment_name,
    simulation_names=["starting", "incremental", "not_ooo", "final"],
    colours=["tab:blue","tab:orange","tab:green","tab:red"],
    limits=100000,
    figsize=(7,7),
):
    throughput_vals =  "------------------\n"
    throughput_vals +=  f"{experiment_name}\n"
    throughput_vals +=  "------------------\n"
    fig, ax = plt.subplots(figsize=figsize)
    for sim, col in zip(simulation_names,colours):
        throughput = plot_progress(ax, f"Logs/end_times/{sim}_{experiment_name}.npy", col, sim)
        throughput_vals += f"{sim}: {throughput}\n"
    ax.set_xlim(0,limits)
    ax.set_ylim(0,limits)
    ax.plot(ax.get_xlim(), ax.get_ylim(), ls="--", c=".3", label="1 request per cycle")
    plt.xlabel("Number of clock cycles")
    plt.ylabel("Memory reads completed")
    plt.legend()
    plt.savefig(f"Logs/figures/{experiment_name}.png")
    with open(f"Logs/throughputs/{experiment_name}.txt", "w") as throughput_file:
        print(throughput_vals, end="", file=throughput_file)
    print(throughput_vals)
    
############
# READS
############
## DONE
# plot_all("every_leaf")
# plot_all("every_root")
# plot_all("every_leaf_line", limits=1000)
# plot_all("every_root_line", limits=1000)

## DONE
# plot_all("every_leaf_and_leaf")
# plot_all("every_root_and_leaf")
# plot_all("every_leaf_line_and_leaf", limits=1000)
# plot_all("every_root_line_and_leaf", limits=1000)

############
# Writes
############
# # DONE
# plot_all("write_every_leaf")
# plot_all("write_every_root")
# plot_all("write_every_leaf_line", limits=1000)
# plot_all("write_every_root_line", limits=1000)

# # DONE
# plot_all("write_every_leaf_and_leaf")
# plot_all("write_every_root_and_leaf")
# plot_all("write_every_leaf_line_and_leaf", limits=1000)
# plot_all("write_every_root_line_and_leaf", limits=1000)

############
# Skipping leaf cache
############
## DONE 
# plot_all("overtaking_leaf_single", limits=10000, simulation_names=["not_ooo", "final"])
# plot_all("overtaking_leaf_ten", limits=10000, simulation_names=["not_ooo", "final"])

############
# Non blocking miss
############
## DONE 
# plot_all("non_blocking_single", limits=1000, simulation_names=["not_ooo", "final"])
# plot_all("non_blocking_four", limits=1000, simulation_names=["not_ooo", "final"])



# fig, ax = plt.subplots(figsize=(7, 7))
# ## PLOT ON GRAPH
# # plot_progress(null_controller, "tab:blue", "Skip tag controller")
# # plot_progress(null_lookups, "tab:blue", "Skip tag lookups")
# # plot_progress(original_controller, "tab:orange", "Base controller")
# # plot_progress(bypass_tagcachereq, "tab:green", "Bypass TagCacheReq")
# # plot_progress(response_and_lookup, "tab:red", "One cycle tag lookups")
# plot_progress(ax, "Logs/end_times/final_gzip.npy", "tab:blue", "Not ooo gzip")
# plot_progress(ax, "Logs/end_times/starting_gzip.npy", "tab:orange", "Not ooo gzip")

# ax.set_ylim(0, 100000)
# ax.set_xlim(0, 100000)

# ax.plot(ax.get_xlim(), ax.get_ylim(), ls="--", c=".3", label="1 request per cycle")
# ## DECORATE AND SAVE GRAPH
# plt.xlabel("Number of clock cycles")
# plt.ylabel("Memory reads completed")
# plt.legend()

# plt.savefig("Logs/figures/Gzip.png")
